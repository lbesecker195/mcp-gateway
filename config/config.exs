# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mcp_gateway,
  ecto_repos: [McpGateway.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Billing: one successful tool call costs 100 micro-USD ($0.0001). Money is always integer micro-USD.
  price_micro_usd: 100,
  # Reverse-DNS prefixes: server names in the registry API and `_meta` keys.
  # `dev.mcpharbor.gateway` reverses to gateway.mcpharbor.dev, the domain whose ownership the
  # official registry makes us prove by DNS before it will accept a publish under this namespace.
  registry_namespace: "dev.mcpharbor.gateway",
  meta_namespace: "dev.mcpharbor.gateway",
  # The public home of this gateway. Anything we hand to a third party — a document published to
  # the official registry, a link in agent-facing docs — must point here, never at whatever host
  # happened to render it, or we publish a localhost URL to a public registry.
  canonical_base_url: "https://gateway.mcpharbor.dev",
  # Catalog compliance: a verdict older than this is treated as unverified and delisted.
  compliance_max_age_days: 180,
  catalog_dir: "catalog/servers",
  # Rate limit applied to every account, as {requests, window_ms}.
  account_rate_limit: {600, 60_000},
  # Browser Origins allowed to call /mcp (the endpoint's own origin is always allowed).
  allowed_origins: [],
  # Upstream MCP servers: only these launchers may be spawned for stdio upstreams.
  allowed_upstream_commands: ["npx", "uvx"],
  upstream_call_timeout_ms: 30_000,
  upstream_probe_timeout_ms: 20_000,
  upstream_startup_timeout_ms: 90_000,
  upstream_idle_timeout_ms: 600_000,
  # HOME for spawned upstream servers, isolated from the operator's real home directory.
  upstream_home: nil

# Configure the endpoint
config :mcp_gateway, McpGatewayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: McpGatewayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: McpGateway.PubSub,
  live_view: [signing_salt: "bpC/71U+"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
