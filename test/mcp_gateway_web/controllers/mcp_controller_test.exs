defmodule McpGatewayWeb.MCPControllerTest do
  @moduledoc """
  The wire protocol, both eras. Tests that call a tool spawn a real subprocess upstream.
  """
  use McpGatewayWeb.ConnCase, async: true

  alias McpGateway.Billing
  alias McpGateway.Fixtures
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Settings

  @version "2026-07-28"
  @seed 1_000_000

  setup do
    %{account: account, key: key} = Fixtures.insert_account(@seed)
    {:ok, account: account, key: key}
  end

  describe "modern era" do
    test "tools/call is billed and returns a complete result with serverInfo", %{
      key: key,
      account: account
    } do
      server = fake_server()
      name = tool(server, "echo")
      body = modern_body(1, "tools/call", %{"name" => name, "arguments" => %{"text" => "hi"}})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => result} = json_response(conn, 200)
      assert result["resultType"] == "complete"
      assert result["content"] == [%{"type" => "text", "text" => "echo: hi"}]
      assert result["isError"] == false

      assert result["_meta"][P.meta_server_info_key()] == %{
               "name" => "mcp-gateway",
               "version" => Settings.server_version()
             }

      call_meta = result["_meta"][Settings.meta_key("call")]
      assert call_meta["chargedMicroUsd"] == Settings.price_micro_usd()
      assert is_binary(call_meta["id"])

      assert Billing.balance(account.id) == @seed - Settings.price_micro_usd()
    end

    test "an Mcp-Name header that disagrees with the body is a header mismatch", %{key: key} do
      server = fake_server()
      name = tool(server, "echo")
      body = modern_body(2, "tools/call", %{"name" => name, "arguments" => %{"text" => "hi"}})
      headers = modern_headers(body, %{"mcp-name" => name <> "_other"})

      conn = post_rpc("/mcp", key, body, headers)

      assert %{"id" => 2, "error" => error} = json_response(conn, 400)
      assert error["code"] == P.header_mismatch()
      assert error["message"] =~ "Mcp-Name"
    end

    test "a modern request without the MCP-Protocol-Version header is a header mismatch", %{
      key: key
    } do
      body = modern_body(3, "tools/list", %{})
      headers = modern_headers(body, %{"mcp-protocol-version" => nil})

      conn = post_rpc("/mcp", key, body, headers)

      assert %{"id" => 3, "error" => error} = json_response(conn, 400)
      assert error["code"] == P.header_mismatch()
      assert error["message"] =~ "MCP-Protocol-Version"
    end

    test "an Mcp-Method header that disagrees with the body is a header mismatch", %{key: key} do
      body = modern_body(4, "tools/list", %{})
      headers = modern_headers(body, %{"mcp-method" => "tools/call"})

      conn = post_rpc("/mcp", key, body, headers)

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == P.header_mismatch()
    end

    test "a protocol version we do not implement lists the ones we do", %{key: key} do
      body = modern_body(5, "tools/list", %{}, "1900-01-01")

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"id" => 5, "error" => error} = json_response(conn, 400)
      assert error["code"] == P.unsupported_version()
      assert error["data"]["requested"] == "1900-01-01"
      assert error["data"]["supported"] == P.supported_versions()
    end

    test "clientCapabilities is required on every request", %{key: key} do
      body = modern_body(6, "tools/list", %{})
      meta = Map.delete(body["params"]["_meta"], P.meta_client_caps_key())
      body = put_in(body, ["params", "_meta"], meta)

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == P.invalid_params()
      assert error["message"] =~ "clientCapabilities"
    end

    test "server/discover reports versions, capabilities, instructions and serverInfo", %{
      key: key
    } do
      body = modern_body(7, "server/discover", %{})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"result" => result} = json_response(conn, 200)
      assert result["resultType"] == "complete"
      assert "2026-07-28" in result["supportedVersions"]
      assert result["capabilities"]["tools"] == %{}
      assert is_binary(result["instructions"])
      assert result["_meta"][P.meta_server_info_key()]["name"] == "mcp-gateway"
    end

    test "tools/list is free and lists only tools we may serve", %{key: key, account: account} do
      listed = Fixtures.insert_fake_server()
      hidden = Fixtures.insert_fake_server(%{compliance_verdict: "not_allowed"})
      body = modern_body(8, "tools/list", %{})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"result" => result} = json_response(conn, 200)
      assert result["resultType"] == "complete"
      refute Map.has_key?(result, "nextCursor")

      names = Enum.map(result["tools"], & &1["name"])
      assert tool(listed, "echo") in names
      refute Enum.any?(names, &String.starts_with?(&1, hidden.slug <> "__"))

      assert Billing.balance(account.id) == @seed
    end

    test "POST /mcp/:slug scopes tools/list to that server", %{key: key} do
      a = Fixtures.insert_fake_server()
      _b = Fixtures.insert_fake_server()
      body = modern_body(9, "tools/list", %{})

      conn = post_rpc("/mcp/#{a.slug}", key, body, modern_headers(body))

      assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])

      assert Enum.sort(names) == Enum.sort(Enum.map(~w(echo fail sleep crash env), &tool(a, &1)))
    end

    test "a tool that is not in the catalog is an invalid-params error", %{
      key: key,
      account: account
    } do
      body =
        modern_body(10, "tools/call", %{"name" => "nope__nothing", "arguments" => %{}})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"error" => error} = json_response(conn, 200)
      assert error["code"] == P.invalid_params()
      assert error["message"] =~ "Unknown tool: nope__nothing"
      assert Billing.balance(account.id) == @seed
    end

    test "an empty balance is HTTP 402 and says what a call costs" do
      server = fake_server()
      %{key: key} = Fixtures.insert_account(0)
      body = modern_body(11, "tools/call", %{"name" => tool(server, "echo"), "arguments" => %{}})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"error" => error} = json_response(conn, 402)
      assert error["code"] == P.payment_required()
      assert error["data"]["balanceMicroUsd"] == 0
      assert error["data"]["priceMicroUsd"] == Settings.price_micro_usd()
      assert error["data"]["priceUsd"] == "0.0001"
    end

    test "an upstream that dies is a tool execution error, and is not charged", %{
      key: key,
      account: account
    } do
      server = fake_server()
      body = modern_body(12, "tools/call", %{"name" => tool(server, "crash"), "arguments" => %{}})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text =~ "not charged"
      assert Billing.balance(account.id) == @seed
    end

    test "an exhausted upstream quota is HTTP 429 with Retry-After", %{
      key: key,
      account: account
    } do
      server = fake_server(%{rate_limit: %{"requests" => 1, "window_ms" => 3_600_000}})
      name = tool(server, "echo")

      first = modern_body(19, "tools/call", %{"name" => name, "arguments" => %{"text" => "1"}})

      assert %{"result" => _} =
               json_response(post_rpc("/mcp", key, first, modern_headers(first)), 200)

      second = modern_body(20, "tools/call", %{"name" => name, "arguments" => %{"text" => "2"}})
      conn = post_rpc("/mcp", key, second, modern_headers(second))

      assert %{"error" => error} = json_response(conn, 429)
      assert error["code"] == P.rate_limited()
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0

      assert Billing.balance(account.id) == @seed - Settings.price_micro_usd()
    end

    test "an upstream JSON-RPC error is passed through unchanged", %{key: key, account: account} do
      server = fake_server()
      # The fixture's `echo` requires `text`, and answers a missing one with -32602.
      body = modern_body(13, "tools/call", %{"name" => tool(server, "echo"), "arguments" => %{}})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"error" => error} = json_response(conn, 200)
      assert error["code"] == -32602
      assert error["message"] == "text is required"
      assert Billing.balance(account.id) == @seed
    end
  end

  describe "legacy era" do
    test "initialize, then tools/call, with none of the modern headers", %{
      key: key,
      account: account
    } do
      server = fake_server()

      init = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "legacy-client", "version" => "1.0.0"}
        }
      }

      conn = post_rpc("/mcp", key, init, %{})
      assert %{"result" => result} = json_response(conn, 200)
      assert result["protocolVersion"] == "2025-11-25"
      assert result["capabilities"]["tools"] == %{}
      assert result["serverInfo"]["name"] == "mcp-gateway"
      refute Map.has_key?(result, "resultType")

      # notifications/initialized carries no id, so it gets 202 and no body.
      notice = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      conn = post_rpc("/mcp", key, notice, %{})
      assert conn.status == 202
      assert conn.resp_body == ""

      call = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => tool(server, "echo"), "arguments" => %{"text" => "legacy"}}
      }

      conn = post_rpc("/mcp", key, call, %{})
      assert %{"result" => result} = json_response(conn, 200)
      assert result["content"] == [%{"type" => "text", "text" => "echo: legacy"}]

      # The legacy path adds nothing of ours to the upstream's result except the call id, so a
      # handshake-era client never sees modern per-response fields the gateway invented.
      refute Map.has_key?(result["_meta"], P.meta_server_info_key())
      assert is_binary(result["_meta"][Settings.meta_key("call")]["id"])

      assert Billing.balance(account.id) == @seed - Settings.price_micro_usd()
    end

    test "a legacy MCP-Protocol-Version header does not force the modern rules", %{key: key} do
      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => %{}}

      conn = post_rpc("/mcp", key, body, %{"mcp-protocol-version" => "2025-11-25"})

      assert %{"result" => result} = json_response(conn, 200)
      assert is_list(result["tools"])
      refute Map.has_key?(result, "resultType")
    end
  end

  describe "transport rules" do
    test "a notification gets 202 and an empty body", %{key: key} do
      body = %{"jsonrpc" => "2.0", "method" => "notifications/something"}

      conn = post_rpc("/mcp", key, body, %{})

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "GET /mcp is 405" do
      conn = get(build_conn(), "/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE /mcp is 405 too" do
      assert delete(build_conn(), "/mcp").status == 405
    end

    test "an unknown method is HTTP 404 with a -32601 body", %{key: key} do
      body = modern_body(14, "tools/nope", %{})

      conn = post_rpc("/mcp", key, body, modern_headers(body))

      assert %{"id" => 14, "error" => error} = json_response(conn, 404)
      assert error["code"] == P.method_not_found()
      assert error["message"] =~ "tools/nope"
    end

    test "no Authorization header is 401" do
      body = modern_body(15, "tools/list", %{})

      conn = post_rpc("/mcp", nil, body, modern_headers(body))

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == P.unauthorized()
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "a key that is not ours is 401, and the key is not echoed back" do
      body = modern_body(16, "tools/list", %{})

      conn = post_rpc("/mcp", "mcpg_not-a-real-key", body, modern_headers(body))

      assert %{"error" => %{"code" => 401}} = json_response(conn, 401)
      refute conn.resp_body =~ "not-a-real-key"
    end

    test "a request from a foreign Origin is refused", %{key: key} do
      body = modern_body(17, "tools/list", %{})
      headers = Map.put(modern_headers(body), "origin", "https://evil.example")

      conn = post_rpc("/mcp", key, body, headers)

      assert %{"error" => _} = json_response(conn, 403)
    end

    test "a request from our own Origin is allowed", %{key: key} do
      body = modern_body(18, "tools/list", %{})
      headers = Map.put(modern_headers(body), "origin", "http://www.example.com")

      conn = post_rpc("/mcp", key, body, headers)

      assert %{"result" => _} = json_response(conn, 200)
    end

    test "a body that is not a single JSON-RPC object is rejected", %{key: key} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> key)
        |> post("/mcp", Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))

      assert %{"error" => %{"code" => code}} = json_response(conn, 400)
      assert code == P.invalid_request()
    end
  end

  ## Helpers

  defp fake_server(attrs \\ %{}) do
    server = Fixtures.insert_fake_server(attrs)
    on_exit(fn -> Fixtures.stop_upstream(server.slug) end)
    server
  end

  defp tool(server, name), do: server.slug <> "__" <> name

  # A modern request declares its protocol version and capabilities in `params._meta`.
  defp modern_body(id, method, params, version \\ @version) do
    meta = %{
      P.meta_version_key() => version,
      P.meta_client_caps_key() => %{},
      P.meta_client_info_key() => %{"name" => "test-client", "version" => "1.0.0"}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  # The headers a conforming client mirrors from the body. `overrides` replaces one (or removes
  # it with `nil`) so a test can break exactly one rule.
  defp modern_headers(body, overrides \\ %{}) do
    params = body["params"] || %{}

    %{
      "mcp-protocol-version" => get_in(params, ["_meta", P.meta_version_key()]),
      "mcp-method" => body["method"],
      "mcp-name" => params["name"]
    }
    |> Map.merge(overrides)
  end

  # A fresh conn per request: the endpoint is stateless, and so is the test.
  defp post_rpc(path, key, body, headers) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_auth(key)
    |> put_headers(headers)
    |> post(path, Jason.encode!(body))
  end

  defp put_auth(conn, nil), do: conn
  defp put_auth(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn
      {_name, nil}, acc -> acc
      {name, value}, acc -> put_req_header(acc, name, value)
    end)
  end
end
