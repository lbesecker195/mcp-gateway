defmodule McpGateway.TrialTest do
  @moduledoc """
  The free trial mints real spendable credit, so "once per account" has to be a property of the
  ledger rather than of the code that happens to call it.
  """
  use McpGateway.DataCase, async: true

  alias McpGateway.{Billing, Settings}

  defp account! do
    {:ok, a} = Billing.create_account("trial test")
    a
  end

  test "grants the configured amount and records why" do
    a = account!()
    assert {:ok, entry} = Billing.grant_trial(a.id)

    assert entry.amount_micro_usd == Settings.trial_credit_micro_usd()
    assert entry.kind == "topup"
    assert entry.metadata["reason"] == "free_trial"
    assert Billing.balance(a.id) == Settings.trial_credit_micro_usd()
  end

  test "a second grant is refused and adds no credit" do
    a = account!()
    assert {:ok, _} = Billing.grant_trial(a.id)
    before = Billing.balance(a.id)

    assert {:error, :already_granted} = Billing.grant_trial(a.id)
    assert Billing.balance(a.id) == before
    assert length(Billing.list_entries(a.id)) == 1
  end

  test "concurrent grants for one account produce exactly one credit" do
    a = account!()

    results =
      1..10
      |> Task.async_stream(fn _ -> Billing.grant_trial(a.id) end, max_concurrency: 10)
      |> Enum.map(fn {:ok, r} -> r end)

    granted = Enum.count(results, &match?({:ok, _}, &1))

    assert granted == 1, "expected exactly one grant, got #{granted}"
    assert Billing.balance(a.id) == Settings.trial_credit_micro_usd()
    assert length(Billing.list_entries(a.id)) == 1
  end

  test "trial credit is ordinary spendable balance, not a separate pot" do
    a = account!()
    {:ok, _} = Billing.grant_trial(a.id)

    assert {:ok, _} = Billing.charge(a.id, Ecto.UUID.generate(), Settings.price_micro_usd())
    assert Billing.balance(a.id) == Settings.trial_credit_micro_usd() - Settings.price_micro_usd()
  end

  test "the configured trial buys the number of calls it claims to" do
    calls = div(Settings.trial_credit_micro_usd(), Settings.price_micro_usd())
    assert calls == 100_000, "the landing page and docs quote this number; keep them in step"
  end

  test "a zero trial setting disables the grant rather than crediting nothing" do
    original = Application.get_env(:mcp_gateway, :trial_credit_micro_usd)
    Application.put_env(:mcp_gateway, :trial_credit_micro_usd, 0)
    on_exit(fn -> Application.put_env(:mcp_gateway, :trial_credit_micro_usd, original) end)

    a = account!()
    assert {:error, :trial_disabled} = Billing.grant_trial(a.id)
    assert Billing.balance(a.id) == 0
  end
end
