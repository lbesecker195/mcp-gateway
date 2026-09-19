defmodule McpGatewayWeb.DocsControllerTest do
  use McpGatewayWeb.ConnCase, async: true

  alias McpGateway.Billing
  alias McpGateway.Fixtures
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.RateLimiter
  alias McpGateway.Settings

  setup do
    servable =
      Fixtures.insert_server(%{
        slug: "weatherly",
        title: "Weatherly",
        description: "Forecasts and severe-weather alerts for any city.",
        rate_limit: %{"requests" => 20, "window_ms" => 60_000},
        compliance: %{
          "verdict" => "allowed",
          "terms_url" => "https://weatherly.example.com/terms",
          "checked_on" => Date.to_iso8601(Date.utc_today()),
          "attribution" => "Weather data by Weatherly."
        }
      })

    Fixtures.insert_tool(servable, "forecast", %{
      description: "Return a three-day forecast for a city."
    })

    denied =
      Fixtures.insert_fake_server(%{
        slug: "notallowed",
        title: "NEVERLISTED Forbidden",
        description: "NEVERLISTED: the provider's terms forbid proxying.",
        compliance_verdict: "not_allowed"
      })

    %{servable: servable, denied: denied}
  end

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first()

  describe "plain-text documents" do
    test "GET /llms.txt", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")

      assert content_type(conn) == "text/plain; charset=utf-8"
      body = response(conn, 200)
      assert String.starts_with?(body, "# ")
      assert body =~ "/docs/servers/weatherly"
      refute body =~ "NEVERLISTED"
    end

    test "GET /llms-full.txt", %{conn: conn} do
      conn = get(conn, ~p"/llms-full.txt")

      assert content_type(conn) == "text/plain; charset=utf-8"
      body = response(conn, 200)
      assert body =~ "### `weatherly__forecast`"
      assert body =~ "Return a three-day forecast for a city."
      refute body =~ "NEVERLISTED"
    end

    test "GET /agent.txt", %{conn: conn} do
      conn = get(conn, ~p"/agent.txt")

      assert content_type(conn) == "text/plain; charset=utf-8"
      body = response(conn, 200)
      assert body =~ "Authorization: Bearer <your gateway API key>"
      assert body =~ "$" <> Billing.format_usd(Settings.price_micro_usd())
    end

    test "GET /skill.txt", %{conn: conn} do
      conn = get(conn, ~p"/skill.txt")

      assert content_type(conn) == "text/plain; charset=utf-8"
      body = response(conn, 200)
      assert body =~ "tools/call weatherly__forecast"
      refute body =~ "notallowed__"
    end
  end

  describe "server.json" do
    test "GET /server.json serves the gateway's registry entry", %{conn: conn} do
      conn = get(conn, ~p"/server.json")

      assert content_type(conn) =~ "application/json"
      json = Jason.decode!(response(conn, 200))

      assert String.ends_with?(json["name"], "/gateway")
      assert json["_meta"][Settings.meta_key("gateway")]["toolCount"] == 1

      assert json["_meta"][Settings.meta_key("pricing")]["pricePerCallMicroUsd"] ==
               Settings.price_micro_usd()
    end

    test "GET /.well-known/mcp/server.json serves the same document", %{conn: conn} do
      well_known = get(conn, ~p"/.well-known/mcp/server.json")
      root = get(build_conn(), ~p"/server.json")

      assert content_type(well_known) =~ "application/json"
      assert response(well_known, 200) == response(root, 200)
    end
  end

  describe "markdown documents" do
    test "GET /docs/servers/:slug", %{conn: conn} do
      conn = get(conn, ~p"/docs/servers/weatherly")

      assert content_type(conn) == "text/markdown; charset=utf-8"
      body = response(conn, 200)
      assert body =~ "# Weatherly"
      assert body =~ "| `weatherly__forecast` |"
      assert body =~ "Weather data by Weatherly."
      assert body =~ "$" <> Billing.format_usd(Settings.price_micro_usd())
    end

    test "GET /docs/tools/:name", %{conn: conn} do
      conn = get(conn, ~p"/docs/tools/weatherly__forecast")

      assert content_type(conn) == "text/markdown; charset=utf-8"
      body = response(conn, 200)
      assert body =~ "# `weatherly__forecast`"
      assert body =~ "Mcp-Name: weatherly__forecast"
      assert body =~ "$" <> Billing.format_usd(Settings.price_micro_usd())
    end
  end

  describe "not found" do
    test "an unknown server slug is a 404 in plain text", %{conn: conn} do
      conn = get(conn, ~p"/docs/servers/does_not_exist")

      assert content_type(conn) == "text/plain; charset=utf-8"
      body = response(conn, 404)
      assert body =~ "404 Not Found"
      assert body =~ "does_not_exist"
    end

    test "an unknown tool name is a 404", %{conn: conn} do
      conn = get(conn, ~p"/docs/tools/no_such_tool")

      assert content_type(conn) == "text/plain; charset=utf-8"
      assert response(conn, 404) =~ "404 Not Found"
    end

    test "a server that is not compliance-servable is a 404, not a page", %{conn: conn} do
      conn = get(conn, ~p"/docs/servers/notallowed")

      assert response(conn, 404) =~ "404 Not Found"
      refute response(conn, 404) =~ "NEVERLISTED"
    end

    test "a tool of a non-servable server is a 404", %{conn: conn} do
      conn = get(conn, ~p"/docs/tools/notallowed__echo")

      assert response(conn, 404) =~ "404 Not Found"
    end
  end

  # agent.txt tells an agent how to react to a 429 and to a 402. Those instructions are only
  # worth anything if they match what the MCP endpoint actually sends, so they are checked
  # against it rather than against themselves.
  describe "agent.txt against the live endpoint" do
    test "Retry-After is the unit agent.txt documents, and the body carries the milliseconds",
         %{conn: conn} do
      agent = response(get(conn, ~p"/agent.txt"), 200)

      assert agent =~ "The response carries a Retry-After header"
      assert agent =~ "delta-seconds (RFC 9110)"
      assert agent =~ ~s("retryAfterMs", in milliseconds)

      slug = Fixtures.unique_slug()
      window_ms = 3_600_000

      server =
        Fixtures.insert_server(%{
          slug: slug,
          rate_limit: %{"requests" => 1, "window_ms" => window_ms}
        })

      Fixtures.insert_tool(server, "forecast")
      %{key: key} = Fixtures.insert_account(1_000_000)

      # Spend this upstream's only slot for the window without calling it, so the request below
      # is refused by the limiter before any upstream is contacted.
      assert :ok = RateLimiter.check({:upstream, slug}, 1, window_ms)

      rpc = post_rpc(key, slug <> "__forecast")

      assert %{"error" => error} = json_response(rpc, 429)
      assert error["code"] == P.rate_limited()

      assert [retry_after] = get_resp_header(rpc, "retry-after")
      seconds = String.to_integer(retry_after)
      retry_ms = error["data"]["retryAfterMs"]

      assert seconds >= 1
      # Whole seconds, rounded up -- not the millisecond figure, which would be ~3_600_000 here.
      assert seconds * 1000 >= retry_ms
      assert (seconds - 1) * 1000 < retry_ms
    end

    test "402 carries the JSON-RPC code and the price agent.txt quotes", %{conn: conn} do
      agent = response(get(conn, ~p"/agent.txt"), 200)
      price = Settings.price_micro_usd()

      assert agent =~ "The JSON-RPC error carries code #{P.payment_required()}"

      server = Fixtures.insert_server(%{slug: Fixtures.unique_slug()})
      Fixtures.insert_tool(server, "forecast")
      # No credit at all: the call is refused before the upstream is contacted.
      %{account: account, key: key} = Fixtures.insert_account(0)

      rpc = post_rpc(key, server.slug <> "__forecast")

      assert %{"error" => error} = json_response(rpc, 402)
      assert error["code"] == P.payment_required()
      assert error["data"]["priceMicroUsd"] == price
      assert error["data"]["priceUsd"] == Billing.format_usd(price)

      # agent.txt promises a 402 leaves the balance untouched, so an identical retry after a
      # top-up is the documented recovery and costs nothing extra.
      assert Billing.balance(account.id) == 0
    end
  end

  # A legacy-era tools/call: no `_meta`, no MCP-Protocol-Version header. Enough to reach the
  # billing pipeline, which is all these cross-checks need.
  defp post_rpc(key, tool_name) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => %{}}
    }

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> key)
    |> post(~p"/mcp", Jason.encode!(body))
  end
end
