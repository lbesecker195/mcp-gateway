defmodule McpGateway.Upstream.HTTPTest do
  # Not async: the `Req.Test` plug is switched on through application env, which is global.
  # Running alone also keeps that switch away from other test modules.
  use ExUnit.Case, async: false

  import Plug.Conn

  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Upstream
  alias McpGateway.Upstream.EraCache

  @stub McpGateway.Upstream.HTTP

  setup_all do
    previous = Application.get_env(:mcp_gateway, :upstream_req_options)
    Application.put_env(:mcp_gateway, :upstream_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mcp_gateway, :upstream_req_options, previous),
        else: Application.delete_env(:mcp_gateway, :upstream_req_options)
    end)

    :ok
  end

  # The era cache is global ETS keyed on the URL, so every test gets its own URL.
  defp server(opts \\ []) do
    n = System.unique_integer([:positive])
    url = Keyword.get(opts, :url, "https://upstream.test/mcp/#{n}")

    upstream =
      case Keyword.fetch(opts, :headers) do
        {:ok, headers} -> %{"type" => "streamable-http", "url" => url, "headers" => headers}
        :error -> %{"type" => "streamable-http", "url" => url}
      end

    on_exit(fn -> EraCache.delete(url) end)
    %{slug: "http-upstream-#{n}", upstream: upstream}
  end

  defp url(server), do: server.upstream["url"]

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp sse(conn, chunks) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

    Enum.reduce(chunks, conn, fn data, acc ->
      {:ok, acc} = chunk(acc, data)
      acc
    end)
  end

  defp ok_result(conn, result) do
    json(conn, 200, %{"jsonrpc" => "2.0", "id" => conn.body_params["id"], "result" => result})
  end

  defp encode(message), do: Jason.encode!(message)

  # Holds a stubbed upstream up for `ms`, or until the gateway abandons it. This is the
  # upstream being slow — the behaviour under test — not test synchronisation.
  defp stall(ms) do
    receive do
      :never -> :ok
    after
      ms -> :ok
    end
  end

  defp elapsed_ms(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1000), result}
  end

  # Answers the modern probe with -32022 offering `supported`, then speaks legacy.
  defp legacy_offering_stub(parent, supported, negotiated) do
    fn conn ->
      body = conn.body_params
      session = get_req_header(conn, "mcp-session-id")
      send(parent, {:request, body["method"], session, body["params"]["protocolVersion"]})

      case {body["method"], session} do
        {"tools/call", []} ->
          json(conn, 400, %{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "error" => %{
              "code" => -32022,
              "message" => "Unsupported protocol version",
              "data" => %{"supported" => supported, "requested" => hd(P.modern_versions())}
            }
          })

        {"initialize", []} ->
          conn
          |> put_resp_header("mcp-session-id", "negotiated")
          |> json(200, %{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => %{"protocolVersion" => negotiated, "capabilities" => %{}}
          })

        {"notifications/initialized", ["negotiated"]} ->
          send_resp(conn, 202, "")

        {"tools/call", ["negotiated"]} ->
          json(conn, 200, %{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => "legacy ok"}],
              "isError" => false
            }
          })
      end
    end
  end

  describe "modern era" do
    test "a JSON response carries the result and the era is remembered" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:conn, conn})

        ok_result(conn, %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => "echo: hi"}],
          "isError" => false
        })
      end)

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{"text" => "hi"})
      assert result["resultType"] == "complete"
      assert result["content"] == [%{"type" => "text", "text" => "echo: hi"}]
      assert EraCache.get(url(server)) == :modern

      assert_receive {:conn, conn}
      assert conn.method == "POST"
      assert get_req_header(conn, "accept") == ["application/json, text/event-stream"]
      assert get_req_header(conn, "content-type") == ["application/json"]
    end

    test "the mirrored metadata headers match the request body" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:conn, conn})
        ok_result(conn, %{"resultType" => "complete", "content" => []})
      end)

      assert {:ok, _} = Upstream.call_tool(server, "echo", %{"text" => "hi"})
      assert_receive {:conn, conn}

      # Spec: MCP-Protocol-Version, Mcp-Method and (for tools/call) Mcp-Name are required,
      # and each MUST equal the corresponding body value or the server answers -32020.
      params = conn.body_params["params"]
      assert get_req_header(conn, "mcp-protocol-version") == [hd(P.modern_versions())]
      assert get_req_header(conn, "mcp-method") == [conn.body_params["method"]]
      assert get_req_header(conn, "mcp-name") == [params["name"]]

      assert conn.body_params["method"] == "tools/call"
      assert params["name"] == "echo"
      assert params["arguments"] == %{"text" => "hi"}

      meta = params["_meta"]
      assert meta[P.meta_version_key()] == hd(P.modern_versions())
      assert meta[P.meta_client_caps_key()] == %{}
      assert meta[P.meta_client_info_key()]["name"] == "mcp-gateway"
    end

    test "a tool name outside plain ASCII is carried with the base64 sentinel" do
      server = server()
      parent = self()
      name = "prévisions_météo"

      Req.Test.stub(@stub, fn conn ->
        [header] = get_req_header(conn, "mcp-name")
        send(parent, {:name_header, header})

        # What a conforming server does: decode the header, compare it to the body.
        decoded =
          case P.decode_header_value(header) do
            {:ok, value} -> value
            :error -> nil
          end

        if decoded == conn.body_params["params"]["name"] do
          ok_result(conn, %{"resultType" => "complete", "content" => []})
        else
          json(conn, 400, %{
            "jsonrpc" => "2.0",
            "id" => conn.body_params["id"],
            "error" => %{"code" => -32020, "message" => "Header mismatch"}
          })
        end
      end)

      assert {:ok, %{"resultType" => "complete"}} = Upstream.call_tool(server, name, %{})

      assert_receive {:name_header, header}
      assert header == "=?base64?" <> Base.encode64(name) <> "?="
      # A header value must be visible ASCII on the wire.
      assert String.match?(header, ~r/\A[\x20-\x7E]+\z/)
    end

    test "tools/list is sent without an Mcp-Name header and pagination is followed" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:name_header, get_req_header(conn, "mcp-name")})

        case conn.body_params["params"]["cursor"] do
          nil ->
            ok_result(conn, %{
              "resultType" => "complete",
              "tools" => [%{"name" => "echo"}],
              "nextCursor" => "page-2"
            })

          "page-2" ->
            ok_result(conn, %{"resultType" => "complete", "tools" => [%{"name" => "fail"}]})
        end
      end)

      assert {:ok, tools} = Upstream.list_tools(server)
      assert Enum.map(tools, & &1["name"]) == ~w(echo fail)
      assert_receive {:name_header, []}
    end

    test "a JSON-RPC error response becomes {:rpc_error, ...}" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        json(conn, 200, %{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "error" => %{"code" => -32602, "message" => "Unknown tool: nope"}
        })
      end)

      assert {:error, {:rpc_error, -32602, "Unknown tool: nope", nil}} =
               Upstream.call_tool(server, "nope", %{})

      assert EraCache.get(url(server)) == :modern
    end

    test "an isError result is a normal result, not an error" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        ok_result(conn, %{
          "resultType" => "complete",
          "isError" => true,
          "content" => [%{"type" => "text", "text" => "boom"}]
        })
      end)

      assert {:ok, %{"isError" => true}} = Upstream.call_tool(server, "fail", %{})
    end

    test "a 2xx body that is not a JSON-RPC response is a protocol error" do
      server = server()
      Req.Test.stub(@stub, fn conn -> json(conn, 200, %{"hello" => "world"}) end)
      assert {:error, :protocol} = Upstream.call_tool(server, "echo", %{})
    end
  end

  describe "SSE responses" do
    test "notifications and comments before the response are ignored" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        id = conn.body_params["id"]

        sse(conn, [
          ": keep-alive\n\n",
          "event: message\ndata: " <>
            encode(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => %{"progress" => 1, "total" => 2}
            }) <> "\n\n",
          "data: " <>
            encode(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "resultType" => "complete",
                "content" => [%{"type" => "text", "text" => "streamed"}]
              }
            }) <> "\n\n"
        ])
      end)

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{})
      assert result["resultType"] == "complete"
      assert result["content"] == [%{"type" => "text", "text" => "streamed"}]
      assert EraCache.get(url(server)) == :modern
    end

    test "CRLF framing, multi-line data and events split across chunks are handled" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        # Pretty JSON gives a payload that genuinely spans several `data:` lines; the SSE
        # rules join them back with "\n", so the reassembled payload must decode.
        payload =
          Jason.encode!(
            %{
              "jsonrpc" => "2.0",
              "id" => conn.body_params["id"],
              "result" => %{"resultType" => "complete", "content" => []}
            },
            pretty: true
          )

        [first | rest] = payload |> String.split("\n") |> Enum.map(&("data: " <> &1))

        # The chunk boundary falls between the CR and the LF of one line ending.
        sse(conn, [
          ":ping\r\n\r\n" <> first <> "\r",
          "\n" <> Enum.join(rest, "\r\n") <> "\r\n",
          "\r\n"
        ])
      end)

      assert {:ok, %{"resultType" => "complete"}} = Upstream.call_tool(server, "echo", %{})
    end

    test "a stream that ends without a response is a protocol error" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        sse(conn, [
          "data: " <> encode(%{"jsonrpc" => "2.0", "method" => "notifications/message"}) <> "\n\n"
        ])
      end)

      assert {:error, :protocol} = Upstream.call_tool(server, "echo", %{})
    end
  end

  describe "the call deadline" do
    test "an upstream that answers inside the deadline is not cut short" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        stall(150)
        ok_result(conn, %{"resultType" => "complete", "content" => []})
      end)

      assert {:ok, %{"resultType" => "complete"}} =
               Upstream.call_tool(server, "echo", %{}, timeout: 3_000)
    end

    test "a response that outlives the deadline is abandoned and reported as :timeout" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, :started)
        # Far beyond the deadline: if nothing bounds the exchange, the call waits here.
        stall(5_000)
        ok_result(conn, %{"resultType" => "complete", "content" => []})
      end)

      {elapsed, result} =
        elapsed_ms(fn -> Upstream.call_tool(server, "echo", %{}, timeout: 300) end)

      assert result == {:error, :timeout}
      assert_receive :started
      # It waited for the deadline, and it did not wait for the upstream.
      assert elapsed >= 250
      assert elapsed < 2_000
    end

    test "an SSE stream that only trickles keep-alives is cut off at the deadline" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        send(parent, :streaming)

        # A conforming keep-alive comment every 100 ms and no response: exactly what a quiet
        # long-lived stream looks like, and what a charged tools/call must not wait on.
        Enum.reduce(1..50, conn, fn _i, acc ->
          stall(100)
          {:ok, acc} = chunk(acc, ": keep-alive\n\n")
          acc
        end)
      end)

      {elapsed, result} =
        elapsed_ms(fn -> Upstream.call_tool(server, "echo", %{}, timeout: 400) end)

      assert result == {:error, :timeout}
      assert_receive :streaming
      assert elapsed < 2_500
    end

    test "the deadline covers the whole exchange, not each request separately" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:method, conn.body_params["method"]})

        case conn.body_params["method"] do
          "tools/call" ->
            send_resp(conn, 400, "")

          "initialize" ->
            # The probe already spent part of the deadline; the handshake inherits the rest
            # rather than starting a fresh timeout of its own.
            stall(5_000)
            send_resp(conn, 200, "")
        end
      end)

      {elapsed, result} =
        elapsed_ms(fn -> Upstream.call_tool(server, "echo", %{}, timeout: 400) end)

      assert result == {:error, :timeout}
      assert_receive {:method, "tools/call"}
      assert_receive {:method, "initialize"}
      assert elapsed < 2_500
    end
  end

  describe "era detection" do
    test "a 400 without a modern error body falls back to the initialize handshake" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        body = conn.body_params
        session = get_req_header(conn, "mcp-session-id")
        send(parent, {:request, body["method"], session})

        case {body["method"], session} do
          {"tools/call", []} ->
            # A legacy server has no idea what this request is.
            send_resp(conn, 400, "")

          {"initialize", []} ->
            conn
            |> put_resp_header("mcp-session-id", "session-abc")
            |> json(200, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{
                "protocolVersion" => "2025-11-25",
                "capabilities" => %{},
                "serverInfo" => %{"name" => "legacy-upstream", "version" => "1.0.0"}
              }
            })

          {"notifications/initialized", ["session-abc"]} ->
            send_resp(conn, 202, "")

          {"tools/call", ["session-abc"]} ->
            json(conn, 200, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{
                "content" => [%{"type" => "text", "text" => "legacy ok"}],
                "isError" => false
              }
            })
        end
      end)

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{})
      assert result["content"] == [%{"type" => "text", "text" => "legacy ok"}]
      # Legacy servers predate resultType.
      refute Map.has_key?(result, "resultType")

      assert_receive {:request, "tools/call", []}
      assert_receive {:request, "initialize", []}
      assert_receive {:request, "notifications/initialized", ["session-abc"]}
      assert_receive {:request, "tools/call", ["session-abc"]}

      assert EraCache.get(url(server)) == {:legacy, "2025-11-25", "session-abc"}
    end

    test "the remembered legacy session skips the probe and is resent on later calls" do
      server = server()
      parent = self()
      EraCache.put(url(server), {:legacy, "2025-11-25", "session-xyz"})

      Req.Test.stub(@stub, fn conn ->
        send(
          parent,
          {:request, conn.body_params["method"], get_req_header(conn, "mcp-session-id")}
        )

        ok_result(conn, %{"content" => [], "isError" => false})
      end)

      assert {:ok, _} = Upstream.call_tool(server, "echo", %{})
      assert {:ok, _} = Upstream.call_tool(server, "echo", %{})

      # Exactly two requests, both carrying the remembered session and no handshake.
      assert_receive {:request, "tools/call", ["session-xyz"]}
      assert_receive {:request, "tools/call", ["session-xyz"]}
      refute_receive {:request, _, _}
    end

    test "a 404 on an established session re-initializes once and retries" do
      server = server()
      parent = self()
      EraCache.put(url(server), {:legacy, "2025-11-25", "stale"})

      Req.Test.stub(@stub, fn conn ->
        body = conn.body_params
        session = get_req_header(conn, "mcp-session-id")
        send(parent, {:request, body["method"], session})

        case {body["method"], session} do
          {"tools/call", ["stale"]} ->
            send_resp(conn, 404, "")

          {"initialize", _} ->
            conn
            |> put_resp_header("mcp-session-id", "fresh")
            |> json(200, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{"protocolVersion" => "2025-11-25", "capabilities" => %{}}
            })

          {"notifications/initialized", ["fresh"]} ->
            send_resp(conn, 202, "")

          {"tools/call", ["fresh"]} ->
            json(conn, 200, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{"isError" => false}
            })
        end
      end)

      assert {:ok, %{"isError" => false}} = Upstream.call_tool(server, "echo", %{})

      assert_receive {:request, "tools/call", ["stale"]}
      # The expired session is not replayed on the new handshake.
      assert_receive {:request, "initialize", []}
      assert_receive {:request, "tools/call", ["fresh"]}
      assert EraCache.get(url(server)) == {:legacy, "2025-11-25", "fresh"}
    end

    test "a modern -32022 with no version we share does not fall back to the handshake" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:method, conn.body_params["method"]})

        json(conn, 400, %{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "error" => %{
            "code" => -32022,
            "message" => "Unsupported protocol version",
            "data" => %{"supported" => ["2099-01-01"], "requested" => hd(P.modern_versions())}
          }
        })
      end)

      assert {:error, {:rpc_error, -32022, "Unsupported protocol version", data}} =
               Upstream.call_tool(server, "echo", %{})

      assert data["supported"] == ["2099-01-01"]

      assert_receive {:method, "tools/call"}
      refute_receive {:method, "initialize"}
      # The server is modern; the verdict is remembered even though the call failed.
      assert EraCache.get(url(server)) == :modern
    end

    test "a 400 carrying -32020 is treated as a modern server, not a legacy one" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:method, conn.body_params["method"]})

        json(conn, 400, %{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "error" => %{"code" => -32020, "message" => "Header mismatch"}
        })
      end)

      assert {:error, {:rpc_error, -32020, "Header mismatch", nil}} =
               Upstream.call_tool(server, "echo", %{})

      refute_receive {:method, "initialize"}
      assert EraCache.get(url(server)) == :modern
    end

    test "a 404 with a JSON-RPC error body is a modern server that lacks the method" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:method, conn.body_params["method"]})

        json(conn, 404, %{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
      end)

      assert {:error, {:rpc_error, -32601, "Method not found", nil}} =
               Upstream.call_tool(server, "echo", %{})

      refute_receive {:method, "initialize"}
    end

    test "an initialize that fails reports {:start_failed, {:initialize_failed, _}}" do
      server = server()

      Req.Test.stub(@stub, fn conn ->
        case conn.body_params["method"] do
          "tools/call" -> send_resp(conn, 405, "")
          "initialize" -> send_resp(conn, 500, "nope")
        end
      end)

      assert {:error, {:start_failed, {:initialize_failed, {:http_status, 500}}}} =
               Upstream.call_tool(server, "echo", %{})
    end
  end

  describe "version negotiation after -32022" do
    # The spec (basic/versioning): "The client SHOULD select a mutually supported version
    # from the `supported` list and retry the request". That list may hold only legacy
    # versions, which means the initialize handshake — a modern error identifies a modern
    # *server*, not a server that still serves a modern *version*.

    test "a -32022 offering only legacy versions falls back to the handshake" do
      server = server()
      parent = self()
      newest_legacy = hd(P.legacy_versions())

      Req.Test.stub(@stub, legacy_offering_stub(parent, P.legacy_versions(), newest_legacy))

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{})
      assert result["content"] == [%{"type" => "text", "text" => "legacy ok"}]

      assert_receive {:request, "tools/call", [], nil}
      assert_receive {:request, "initialize", [], ^newest_legacy}
      assert_receive {:request, "tools/call", ["negotiated"], nil}

      # The upstream is not serving a modern version, so it must not be filed as modern:
      # that verdict would make every later call fail the same way without re-probing.
      assert EraCache.get(url(server)) == {:legacy, newest_legacy, "negotiated"}
    end

    test "the handshake asks for the legacy version the upstream actually named" do
      server = server()
      parent = self()
      offered = List.last(P.legacy_versions())

      # Only meaningful if the offered version is not the one we would have sent anyway.
      refute offered == hd(P.legacy_versions())

      Req.Test.stub(@stub, legacy_offering_stub(parent, [offered], offered))

      assert {:ok, _} = Upstream.call_tool(server, "echo", %{})

      assert_receive {:request, "initialize", [], ^offered}
      assert EraCache.get(url(server)) == {:legacy, offered, "negotiated"}
    end

    test "an upstream cached as modern that has retired modern support switches to legacy" do
      server = server()
      parent = self()
      newest_legacy = hd(P.legacy_versions())
      EraCache.put(url(server), :modern)

      Req.Test.stub(@stub, legacy_offering_stub(parent, [newest_legacy], newest_legacy))

      assert {:ok, %{"isError" => false}} = Upstream.call_tool(server, "echo", %{})

      assert_receive {:request, "tools/call", [], nil}
      assert_receive {:request, "initialize", [], ^newest_legacy}
      assert EraCache.get(url(server)) == {:legacy, newest_legacy, "negotiated"}
    end

    test "a supported list naming both eras still reaches the tool" do
      server = server()
      parent = self()
      newest_legacy = hd(P.legacy_versions())

      # The list names the modern version we just sent — which the server nonetheless
      # rejected — alongside legacy ones. Retrying the rejected version would loop, so the
      # only mutually supported version left is legacy, and the call must still land.
      supported = [hd(P.modern_versions()) | P.legacy_versions()]
      Req.Test.stub(@stub, legacy_offering_stub(parent, supported, newest_legacy))

      assert {:ok, %{"isError" => false}} = Upstream.call_tool(server, "echo", %{})
      assert_receive {:request, "initialize", [], ^newest_legacy}
      assert EraCache.get(url(server)) == {:legacy, newest_legacy, "negotiated"}
    end

    test "a -32022 without a usable supported list is surfaced, not retried" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:method, conn.body_params["method"]})

        json(conn, 400, %{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "error" => %{"code" => -32022, "message" => "Unsupported protocol version"}
        })
      end)

      assert {:error, {:rpc_error, -32022, "Unsupported protocol version", nil}} =
               Upstream.call_tool(server, "echo", %{})

      assert_receive {:method, "tools/call"}
      refute_receive {:method, _}
      assert EraCache.get(url(server)) == :modern
    end
  end

  describe "transport and HTTP failures" do
    test "a timeout is reported as :timeout" do
      server = server()
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, :timeout} = Upstream.call_tool(server, "echo", %{})
    end

    test "a closed connection is reported as :unavailable" do
      server = server()
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :closed) end)
      assert {:error, :unavailable} = Upstream.call_tool(server, "echo", %{})
    end

    test "a non-2xx status without a JSON-RPC body is reported as {:http_status, status}" do
      server = server()
      Req.Test.stub(@stub, fn conn -> send_resp(conn, 502, "bad gateway") end)
      assert {:error, {:http_status, 502}} = Upstream.call_tool(server, "echo", %{})
    end

    test "a redirect is not followed" do
      server = server()
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:host, conn.host})

        conn
        |> put_resp_header("location", "https://elsewhere.test/mcp")
        |> send_resp(302, "")
      end)

      assert {:error, {:http_status, 302}} = Upstream.call_tool(server, "echo", %{})
      assert_receive {:host, "upstream.test"}
      refute_receive {:host, "elsewhere.test"}
    end
  end

  describe "upstream configuration" do
    test "declared headers are sent, including ones resolved from the environment" do
      System.put_env("GATEWAY_TEST_HTTP_TOKEN", "resolved-token")
      on_exit(fn -> System.delete_env("GATEWAY_TEST_HTTP_TOKEN") end)

      server =
        server(
          headers: %{
            "X-Static" => "literal",
            "X-API-Key" => %{"from_env" => "GATEWAY_TEST_HTTP_TOKEN"}
          }
        )

      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, {:conn, conn})
        ok_result(conn, %{"resultType" => "complete", "content" => []})
      end)

      assert {:ok, _} = Upstream.call_tool(server, "echo", %{})
      assert_receive {:conn, conn}
      assert get_req_header(conn, "x-static") == ["literal"]
      assert get_req_header(conn, "x-api-key") == ["resolved-token"]
    end

    test "a from_env header whose variable is unset fails closed before any request" do
      server = server(headers: %{"X-API-Key" => %{"from_env" => "GATEWAY_TEST_HTTP_MISSING"}})
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, :requested)
        ok_result(conn, %{"content" => []})
      end)

      assert {:error, {:start_failed, {:missing_env, "GATEWAY_TEST_HTTP_MISSING"}}} =
               Upstream.call_tool(server, "echo", %{})

      refute_receive :requested
    end

    test "a declared header may not override a protocol header" do
      server = server(headers: %{"Mcp-Protocol-Version" => "1999-01-01"})
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, :requested)
        ok_result(conn, %{"content" => []})
      end)

      assert {:error, {:start_failed, {:reserved_header, "Mcp-Protocol-Version"}}} =
               Upstream.call_tool(server, "echo", %{})

      refute_receive :requested
    end

    test "a plain http URL that is not loopback is rejected" do
      server = server(url: "http://upstream.test/mcp")
      parent = self()

      Req.Test.stub(@stub, fn conn ->
        send(parent, :requested)
        ok_result(conn, %{"content" => []})
      end)

      assert {:error, {:start_failed, {:insecure_url, "http://upstream.test"}}} =
               Upstream.call_tool(server, "echo", %{})

      refute_receive :requested
    end

    test "a plain http URL on loopback is allowed" do
      server = server(url: "http://localhost:4010/mcp/#{System.unique_integer([:positive])}")

      Req.Test.stub(@stub, fn conn ->
        ok_result(conn, %{"resultType" => "complete", "content" => []})
      end)

      assert {:ok, %{"resultType" => "complete"}} = Upstream.call_tool(server, "echo", %{})
    end

    test "an upstream without a URL fails closed" do
      server = %{slug: "no-url", upstream: %{"type" => "streamable-http"}}
      assert {:error, {:start_failed, :missing_url}} = Upstream.call_tool(server, "echo", %{})
    end
  end
end
