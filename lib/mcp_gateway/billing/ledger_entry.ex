defmodule McpGateway.Billing.LedgerEntry do
  @moduledoc """
  One immutable row per balance change. Charges are negative, top-ups and refunds positive.
  The database rejects UPDATE and DELETE on this table.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "ledger_entries" do
    field :kind, :string
    field :amount_micro_usd, :integer
    field :balance_after_micro_usd, :integer
    field :idempotency_key, :string
    field :metadata, :map, default: %{}

    belongs_to :account, McpGateway.Billing.Account

    timestamps(updated_at: false)
  end
end
