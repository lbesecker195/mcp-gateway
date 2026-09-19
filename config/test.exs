import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mcp_gateway, McpGateway.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "mcp_gateway_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mcp_gateway, McpGatewayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "WBK/UJofQ4/4Xl51k3hbOBzc1VLLGCMu4DjTeXNPRZMEXyawoOFoFOUqnvm89Jh6",
  server: false

# Tests spawn a fixture upstream with `elixir`, and use short upstream timeouts.
config :mcp_gateway,
  allowed_upstream_commands: ["npx", "uvx", "elixir"],
  upstream_call_timeout_ms: 5_000,
  upstream_probe_timeout_ms: 3_000,
  upstream_startup_timeout_ms: 20_000,
  upstream_idle_timeout_ms: 60_000,
  compliance_max_age_days: 180

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
