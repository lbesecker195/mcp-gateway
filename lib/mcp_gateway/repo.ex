defmodule McpGateway.Repo do
  use Ecto.Repo,
    otp_app: :mcp_gateway,
    adapter: Ecto.Adapters.Postgres
end
