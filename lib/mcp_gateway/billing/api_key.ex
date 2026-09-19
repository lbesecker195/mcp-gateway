defmodule McpGateway.Billing.ApiKey do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "api_keys" do
    field :key_prefix, :string
    field :key_hash, :string
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :account, McpGateway.Billing.Account

    timestamps()
  end
end
