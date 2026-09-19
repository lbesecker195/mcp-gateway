defmodule McpGateway.Billing.Account do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "accounts" do
    field :name, :string
    field :balance_micro_usd, :integer, default: 0

    has_many :api_keys, McpGateway.Billing.ApiKey

    timestamps()
  end
end
