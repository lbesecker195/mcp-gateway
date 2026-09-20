defmodule McpGateway.Billing do
  @moduledoc """
  Prepaid credits. Every balance change is one row in an append-only ledger, keyed by an
  idempotency key so a retried charge or refund can never apply twice.

  All amounts are integer micro-USD (1 = $0.000001). One tool call costs
  `McpGateway.Settings.price_micro_usd/0` (100 = $0.0001). Never use floats for money.
  """

  import Ecto.Query

  alias McpGateway.Billing.{Account, ApiKey, LedgerEntry}
  alias McpGateway.Repo

  @key_marker "mcpg_"
  @micro_per_usd 1_000_000

  ## Accounts and keys

  def create_account(name) when is_binary(name) do
    Repo.insert(%Account{name: name})
  end

  def get_account(id), do: Repo.get(Account, id)

  @doc "Finds an account by its name. Names are not unique in general; this takes the oldest."
  def get_account_by_name(name) when is_binary(name) do
    Repo.one(from a in Account, where: a.name == ^name, order_by: [asc: a.inserted_at], limit: 1)
  end

  @doc """
  Creates an API key for the account. The plaintext key is returned once and never stored;
  only its SHA-256 hash is kept.
  """
  def create_api_key(%Account{id: account_id}) do
    key = @key_marker <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    {:ok, api_key} =
      Repo.insert(%ApiKey{
        account_id: account_id,
        key_prefix: String.slice(key, 0, 11),
        key_hash: hash_key(key)
      })

    {:ok, key, api_key}
  end

  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Resolves a presented API key to its account, or `{:error, :unauthorized}`."
  def authenticate(key) when is_binary(key) and byte_size(key) > 0 and byte_size(key) < 200 do
    query =
      from k in ApiKey,
        join: a in assoc(k, :account),
        where: k.key_hash == ^hash_key(key) and is_nil(k.revoked_at),
        select: {a, k}

    case Repo.one(query) do
      {account, api_key} ->
        touch_last_used(api_key)
        {:ok, account}

      nil ->
        {:error, :unauthorized}
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  defp hash_key(key), do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

  # Avoid a write on every call: refresh at most once a minute.
  defp touch_last_used(%ApiKey{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -60)

    from(k in ApiKey,
      where: k.id == ^id and (is_nil(k.last_used_at) or k.last_used_at < ^stale_before)
    )
    |> Repo.update_all(set: [last_used_at: now])
  end

  ## Ledger

  def balance(account_id) do
    Repo.one(from a in Account, where: a.id == ^account_id, select: a.balance_micro_usd)
  end

  def list_entries(account_id, limit \\ 50) do
    Repo.all(
      from e in LedgerEntry,
        where: e.account_id == ^account_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  @doc """
  Grants the one-off free trial credit, and returns `{:error, :already_granted}` on a second
  attempt for the same account.

  The idempotency key is the account id rather than a payment reference, which is what makes
  "once per account" a property of the ledger rather than of the code that calls this. A retried
  signup, a double-clicked button or a replayed request all land on the same row.
  """
  def grant_trial(account_id) do
    amount = McpGateway.Settings.trial_credit_micro_usd()

    if amount > 0 do
      case apply_entry_with_status(account_id, "topup", amount, "trial:" <> account_id, %{
             "reason" => "free_trial"
           }) do
        {:ok, :created, entry} -> {:ok, entry}
        {:ok, :existing, _entry} -> {:error, :already_granted}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :trial_disabled}
    end
  end

  @doc """
  Adds credit. `ref` identifies the payment (e.g. a checkout session id); crediting the same
  `ref` twice is a no-op that returns the original entry.
  """
  def top_up(account_id, amount_micro_usd, ref, metadata \\ %{})
      when is_integer(amount_micro_usd) and amount_micro_usd > 0 and is_binary(ref) do
    apply_entry(account_id, "topup", amount_micro_usd, "topup:" <> ref, metadata)
  end

  @doc """
  Debits `amount_micro_usd` for a call. Fails with `{:error, :insufficient_funds}` and changes
  nothing when the balance can't cover it. Idempotent on `call_id`.
  """
  def charge(account_id, call_id, amount_micro_usd, metadata \\ %{})
      when is_binary(call_id) and is_integer(amount_micro_usd) and amount_micro_usd > 0 do
    apply_entry(account_id, "charge", -amount_micro_usd, "charge:" <> call_id, metadata)
  end

  @doc """
  Reverses the charge made for `call_id` (used when the upstream failed). Idempotent, and
  `{:error, :no_charge}` if that call was never charged.
  """
  def refund(account_id, call_id, metadata \\ %{}) when is_binary(call_id) do
    case Repo.get_by(LedgerEntry, idempotency_key: "charge:" <> call_id, account_id: account_id) do
      nil ->
        {:error, :no_charge}

      %LedgerEntry{amount_micro_usd: amount} ->
        apply_entry(account_id, "refund", -amount, "refund:" <> call_id, metadata)
    end
  end

  # The account row lock serializes concurrent changes to one account, so the balance check and
  # the ledger insert see a consistent balance. The unique index on idempotency_key is the
  # backstop; the lookup below makes replays return the original entry instead of failing.
  defp apply_entry(account_id, kind, delta, idempotency_key, metadata) do
    result =
      Repo.transaction(fn ->
        apply_entry_txn(account_id, kind, delta, idempotency_key, metadata)
      end)

    case result do
      {:ok, {_status, entry}} -> {:ok, entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_entry_txn(account_id, kind, delta, idempotency_key, metadata) do
    account = Repo.one!(from a in Account, where: a.id == ^account_id, lock: "FOR UPDATE")

    case Repo.get_by(LedgerEntry, idempotency_key: idempotency_key) do
      %LedgerEntry{} = existing ->
        {:existing, existing}

      nil ->
        new_balance = account.balance_micro_usd + delta
        if new_balance < 0, do: Repo.rollback(:insufficient_funds)

        entry =
          Repo.insert!(%LedgerEntry{
            account_id: account_id,
            kind: kind,
            amount_micro_usd: delta,
            balance_after_micro_usd: new_balance,
            idempotency_key: idempotency_key,
            metadata: metadata
          })

        from(a in Account, where: a.id == ^account_id)
        |> Repo.update_all(
          set: [
            balance_micro_usd: new_balance,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        {:created, entry}
    end
  end

  # Same transaction, but the caller is told whether the row was created now or already existed.
  # `grant_trial/1` needs that distinction and must not infer it from a timestamp.
  defp apply_entry_with_status(account_id, kind, delta, idempotency_key, metadata) do
    case Repo.transaction(fn ->
           apply_entry_txn(account_id, kind, delta, idempotency_key, metadata)
         end) do
      {:ok, {status, entry}} -> {:ok, status, entry}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Money formatting

  @doc "Formats micro-USD as a dollar string: `100` -> `\"0.0001\"`, `5_000_000` -> `\"5.00\"`."
  def format_usd(micro) when is_integer(micro) do
    sign = if micro < 0, do: "-", else: ""
    abs_micro = abs(micro)
    whole = div(abs_micro, @micro_per_usd)

    frac =
      abs_micro
      |> rem(@micro_per_usd)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")
      |> String.pad_trailing(2, "0")

    "#{sign}#{whole}.#{frac}"
  end

  @doc "Parses a dollar string to micro-USD, rejecting anything finer than one micro-dollar."
  def parse_usd(string) when is_binary(string) do
    with {decimal, ""} <- Decimal.parse(string),
         micro = Decimal.mult(decimal, @micro_per_usd),
         true <- Decimal.integer?(micro) do
      {:ok, Decimal.to_integer(micro)}
    else
      _ -> :error
    end
  end
end
