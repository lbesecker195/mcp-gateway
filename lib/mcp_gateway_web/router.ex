defmodule McpGatewayWeb.Router do
  use McpGatewayWeb, :router

  # The MCP endpoint does its own content negotiation: clients send
  # `Accept: application/json, text/event-stream` and the server picks per request.
  pipeline :mcp do
    plug :put_format, :json
  end

  pipeline :registry do
    plug :accepts, ["json"]
  end

  # Discovery documents are free and unauthenticated: agents read them before they have a key.
  pipeline :public_docs do
    plug :put_format, :text
  end

  # The gateway's own MCP endpoint. `/mcp` exposes every servable tool; `/mcp/:slug` narrows to
  # one upstream, which is what each catalog entry's `remotes` URL points at.
  scope "/", McpGatewayWeb do
    pipe_through :mcp

    post "/mcp", MCPController, :handle
    post "/mcp/:slug", MCPController, :handle

    # This revision removed the GET stream and DELETE session endpoints.
    match :*, "/mcp", MCPController, :not_allowed
    match :*, "/mcp/:slug", MCPController, :not_allowed
  end

  # Read-only MCP Registry API. Publishing is deliberately not exposed: entries enter the
  # catalog only through the compliance gate.
  # Free trial and the public demo. Both spend real credit and are rate limited per address.
  scope "/", McpGatewayWeb do
    pipe_through :registry

    post "/v1/signup", TrialController, :signup
    post "/try/call", TrialController, :try_call
  end

  scope "/v0.1", McpGatewayWeb do
    pipe_through :registry

    get "/servers", RegistryController, :index
    get "/servers/:name/versions", RegistryController, :versions
    get "/servers/:name/versions/:version", RegistryController, :show
  end

  scope "/", McpGatewayWeb do
    pipe_through :public_docs

    # The landing page: what an MCP gateway is, what this one costs, and what is in it.
    get "/", DocsController, :index
    get "/try", DocsController, :try_page
    get "/sitemap.xml", DocsController, :sitemap
    get "/robots.txt", DocsController, :robots
    get "/llms.txt", DocsController, :llms
    get "/llms-full.txt", DocsController, :llms_full
    get "/agent.txt", DocsController, :agent
    get "/skill.txt", DocsController, :skill
    get "/server.json", DocsController, :server_json
    get "/.well-known/mcp/server.json", DocsController, :server_json
    get "/docs/servers/:slug", DocsController, :server_doc
    get "/docs/tools/:name", DocsController, :tool_doc
    get "/health", HealthController, :show
  end
end
