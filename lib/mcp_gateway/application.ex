defmodule McpGateway.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      McpGatewayWeb.Telemetry,
      McpGateway.Repo,
      {DNSCluster, query: Application.get_env(:mcp_gateway, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: McpGateway.PubSub},
      McpGateway.RateLimiter,
      McpGateway.Upstream.EraCache,
      {Registry, keys: :unique, name: McpGateway.Upstream.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: McpGateway.Upstream.Supervisor},
      # Start to serve requests, typically the last entry
      McpGatewayWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: McpGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    McpGatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
