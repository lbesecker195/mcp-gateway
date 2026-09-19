defmodule McpGatewayWeb.MCPController do
  @moduledoc """
  The gateway's own MCP endpoint, over Streamable HTTP.

  It is dual-era, because both kinds of client are out there and both pay:

    * **Modern** (revision 2026-07-28): stateless. Every request carries its protocol version
      and client capabilities in `params._meta`, mirrors `method`/`params.name` into the
      `Mcp-Method`/`Mcp-Name` headers, and gets a result stamped `"resultType" => "complete"`.
    * **Legacy** (2025-11-25 and earlier): an `initialize` handshake, no per-request `_meta`,
      no `resultType`.

  The era is read off the request, never off the connection: a request that declares a protocol
  version in `_meta` (or in the `MCP-Protocol-Version` header, unless that header names a legacy
  version) is modern; anything else is legacy.

  This revision removed the GET stream and the DELETE session endpoint, so the router sends
  every other verb to `not_allowed/2`, which answers 405. `Mcp-Session-Id` and `Last-Event-ID`
  are ignored, as the backward-compatibility rules require.

  Responses are always a single JSON object. The spec lets the server choose between
  `application/json` and an SSE stream per request, and we always have the whole result at once.

  Only `tools/call` is billed. `server/discover` and `tools/list` are free.
  """

  use McpGatewayWeb, :controller

  alias McpGateway.Billing
  alias McpGateway.Gateway
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Settings

  plug :validate_origin
  plug McpGatewayWeb.Plugs.Authenticate when action in [:handle]

  @doc """
  Handles one JSON-RPC request. `POST /mcp` exposes every servable tool; `POST /mcp/:slug`
  narrows the catalog to one upstream.
  """
  def handle(conn, _params) do
    case request_body(conn) do
      {:ok, body} -> route(conn, body)
      {:error, message} -> send_rpc(conn, 400, P.error(nil, P.invalid_request(), message))
    end
  end

  @doc "Every verb other than POST. The GET stream and DELETE session endpoints are gone."
  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_rpc(
      405,
      P.error(
        nil,
        P.invalid_request(),
        "This MCP endpoint accepts POST only: revision 2026-07-28 removed the GET stream and " <>
          "the DELETE session endpoint."
      )
    )
  end

  ## Request shape

  # Batching was removed from MCP, so the body is exactly one request or notification object.
  defp request_body(conn) do
    with %{"method" => method} = body when is_binary(method) <- conn.body_params,
         "2.0" <- Map.get(body, "jsonrpc", "2.0") do
      {:ok, body}
    else
      _ ->
        {:error,
         "The request body must be a single JSON-RPC 2.0 object with a string `method`. " <>
           "Batched requests are not part of this protocol revision."}
    end
  end

  defp route(conn, body) do
    id = body["id"]
    method = body["method"]
    params = if is_map(body["params"]), do: body["params"], else: %{}

    # A notification carries no id and MUST NOT get a JSON-RPC response.
    if is_nil(id) do
      send_resp(conn, 202, "")
    else
      dispatch(conn, id, method, params)
    end
  end

  defp dispatch(conn, id, method, params) do
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}
    header_version = header(conn, "mcp-protocol-version")

    if modern?(meta, header_version) do
      case validate_modern(conn, id, meta, method, params) do
        :ok -> modern(conn, id, method, params)
        {:error, status, error} -> send_rpc(conn, status, error)
      end
    else
      legacy(conn, id, method, params)
    end
  end

  # A `_meta` protocol version is the unambiguous modern marker. A bare header counts too,
  # unless it names a version from the handshake era - those clients send it after `initialize`.
  defp modern?(meta, header_version) do
    is_map_key(meta, P.meta_version_key()) or
      (is_binary(header_version) and header_version not in P.legacy_versions())
  end

  ## Modern era

  defp validate_modern(conn, id, meta, method, params) do
    header_version = header(conn, "mcp-protocol-version")
    body_version = meta[P.meta_version_key()]
    requested = body_version || header_version

    cond do
      requested not in P.supported_versions() ->
        {:error, 400,
         P.error(id, P.unsupported_version(), "Unsupported protocol version", %{
           "supported" => P.supported_versions(),
           "requested" => requested
         })}

      is_nil(header_version) ->
        {:error, 400,
         P.error(
           id,
           P.header_mismatch(),
           "Header mismatch: the MCP-Protocol-Version header is required on every POST."
         )}

      header_version != body_version ->
        {:error, 400,
         P.error(
           id,
           P.header_mismatch(),
           "Header mismatch: the MCP-Protocol-Version header must equal " <>
             "params._meta[\"#{P.meta_version_key()}\"]."
         )}

      not is_map_key(meta, P.meta_client_caps_key()) ->
        {:error, 400,
         P.error(
           id,
           P.invalid_params(),
           "params._meta[\"#{P.meta_client_caps_key()}\"] is required on every request."
         )}

      header(conn, "mcp-method") != method ->
        {:error, 400,
         P.error(
           id,
           P.header_mismatch(),
           "Header mismatch: the Mcp-Method header must equal the request method."
         )}

      method == "tools/call" and not name_header_matches?(conn, params) ->
        {:error, 400,
         P.error(
           id,
           P.header_mismatch(),
           "Header mismatch: the Mcp-Name header must equal params.name."
         )}

      true ->
        :ok
    end
  end

  # `Mcp-Name` may arrive Base64-wrapped in the spec's sentinel; decode before comparing.
  defp name_header_matches?(conn, params) do
    with value when is_binary(value) <- header(conn, "mcp-name"),
         {:ok, decoded} <- P.decode_header_value(value) do
      decoded == params["name"]
    else
      _ -> false
    end
  end

  defp modern(conn, id, method, params) do
    case method do
      "server/discover" -> send_rpc(conn, 200, P.result(id, Gateway.describe()))
      "ping" -> send_rpc(conn, 200, P.result(id, decorate(:modern, %{})))
      "tools/list" -> tools_list(conn, id, params, :modern)
      "tools/call" -> tools_call(conn, id, params, :modern)
      _ -> unknown_method(conn, id, method)
    end
  end

  ## Legacy era

  defp legacy(conn, id, method, params) do
    case method do
      "initialize" -> send_rpc(conn, 200, P.result(id, initialize_result(params)))
      "ping" -> send_rpc(conn, 200, P.result(id, %{}))
      "server/discover" -> send_rpc(conn, 200, P.result(id, Gateway.describe()))
      "tools/list" -> tools_list(conn, id, params, :legacy)
      "tools/call" -> tools_call(conn, id, params, :legacy)
      _ -> unknown_method(conn, id, method)
    end
  end

  # Echo the client's version when we support it, so it doesn't have to downgrade; otherwise
  # name the newest handshake-era version we speak.
  defp initialize_result(params) do
    requested = params["protocolVersion"]
    version = if requested in P.legacy_versions(), do: requested, else: hd(P.legacy_versions())

    %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => Gateway.server_info(),
      "instructions" => Gateway.instructions()
    }
  end

  ## Methods

  defp tools_list(conn, id, params, era) do
    case Gateway.list_tools(scope: scope(conn), cursor: params["cursor"]) do
      {:ok, tools, next_cursor} ->
        result = %{"tools" => tools}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        send_rpc(conn, 200, P.result(id, decorate(era, result)))

      {:error, :invalid_cursor} ->
        send_rpc(
          conn,
          200,
          P.error(id, P.invalid_params(), "Invalid cursor. Pass back a nextCursor unchanged.")
        )
    end
  end

  defp tools_call(conn, id, params, era) do
    name = params["name"]
    arguments = params["arguments"]

    cond do
      not is_binary(name) ->
        send_rpc(
          conn,
          200,
          P.error(id, P.invalid_params(), "params.name is required and must be a string.")
        )

      not (is_nil(arguments) or is_map(arguments)) ->
        send_rpc(
          conn,
          200,
          P.error(id, P.invalid_params(), "params.arguments must be an object.")
        )

      true ->
        account = conn.assigns.account
        call = Gateway.call_tool(account, name, arguments || %{}, scope: scope(conn))
        reply_to_call(conn, id, era, name, account, call)
    end
  end

  defp reply_to_call(conn, id, era, _name, _account, {:ok, result, call_id}) do
    result = decorate(era, put_call_meta(result, call_id))
    send_rpc(conn, 200, P.result(id, result))
  end

  # An excluded tool is indistinguishable from one that never existed. That is deliberate: the
  # compliance gate must not become a directory of servers we decided we may not proxy.
  defp reply_to_call(conn, id, _era, name, _account, {:error, :unknown_tool}) do
    send_rpc(conn, 200, P.error(id, P.invalid_params(), "Unknown tool: #{name}"))
  end

  defp reply_to_call(conn, id, _era, _name, account, {:error, :insufficient_funds}) do
    balance = Billing.balance(account.id)
    price = Settings.price_micro_usd()

    send_rpc(
      conn,
      402,
      P.error(
        id,
        P.payment_required(),
        "Insufficient credit for this call. Top up at #{Settings.base_url()} and retry.",
        %{
          "balanceMicroUsd" => balance,
          "balanceUsd" => Billing.format_usd(balance || 0),
          "priceMicroUsd" => price,
          "priceUsd" => Billing.format_usd(price),
          "topUpUrl" => Settings.base_url()
        }
      )
    )
  end

  defp reply_to_call(conn, id, _era, _name, _account, {:error, {:rate_limited, retry_ms}}) do
    conn
    |> retry_after(retry_ms)
    |> send_rpc(
      429,
      P.error(id, P.rate_limited(), "Account rate limit exceeded.", %{"retryAfterMs" => retry_ms})
    )
  end

  defp reply_to_call(conn, id, _era, _name, _account, {:error, {:upstream_busy, retry_ms}}) do
    conn
    |> retry_after(retry_ms)
    |> send_rpc(
      429,
      P.error(
        id,
        P.rate_limited(),
        "This upstream's rate limit is exhausted. Nothing was charged.",
        %{"retryAfterMs" => retry_ms}
      )
    )
  end

  # The upstream answered with a JSON-RPC error of its own (an unknown tool, bad arguments).
  # Pass it through untouched: it is the upstream's diagnosis and the client can act on it.
  defp reply_to_call(conn, id, _era, _name, _account, {:error, {:rpc_error, code, message, data}}) do
    send_rpc(conn, 200, P.error(id, code, message, data))
  end

  # Transport and protocol failures. The spec wants API failures reported as tool execution
  # errors so the model can react, rather than as protocol errors it can do nothing about.
  # `failure_kind/1` is coarse on purpose - an upstream's command or credentials never leave here.
  defp reply_to_call(conn, id, era, _name, _account, {:error, reason}) do
    result = %{
      "content" => [
        %{
          "type" => "text",
          "text" =>
            "The upstream MCP server did not return a result (#{Gateway.failure_kind(reason)}). " <>
              "This call was not charged. Retry, or try a different tool."
        }
      ],
      "isError" => true
    }

    send_rpc(conn, 200, P.result(id, decorate(era, result)))
  end

  defp unknown_method(conn, id, method) do
    # HTTP 404 *and* a JSON-RPC error: together they tell a client this is a modern MCP endpoint
    # that lacks the method, not a legacy server that lacks the endpoint.
    send_rpc(conn, 404, P.error(id, P.method_not_found(), "Method not found: #{method}"))
  end

  ## Result decoration

  # An upstream's `tools/call` result is forwarded verbatim; decoration only ever adds. That is
  # why the legacy branch is a no-op rather than a filter: stripping fields we did not put there
  # would mean, for instance, turning an upstream's `"input_required"` into a silent
  # `"complete"`. For the same reason a result that already carries `resultType` keeps its own.
  defp decorate(:modern, result) do
    result
    |> Map.put_new("resultType", "complete")
    |> put_meta(P.meta_server_info_key(), Gateway.server_info())
  end

  defp decorate(:legacy, result), do: result

  # The call id goes back to the caller in both eras: one id answers "what was I charged for?".
  defp put_call_meta(result, call_id) do
    put_meta(result, Settings.meta_key("call"), %{
      "id" => call_id,
      "chargedMicroUsd" => Settings.price_micro_usd()
    })
  end

  defp put_meta(result, key, value) do
    meta = if is_map(result["_meta"]), do: result["_meta"], else: %{}
    Map.put(result, "_meta", Map.put(meta, key, value))
  end

  ## Origin

  # DNS-rebinding protection: a page on some other origin must not be able to drive a client's
  # gateway key. A request with no Origin at all is a non-browser client and is fine.
  defp validate_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        if allowed_origin?(conn, origin) do
          conn
        else
          conn
          |> send_rpc(403, P.error(nil, P.invalid_request(), "Origin not allowed."))
          |> halt()
        end
    end
  end

  defp allowed_origin?(conn, origin) do
    origin in Settings.get(:allowed_origins) or origin == Settings.base_url() or
      origin_host(origin) == conn.host
  end

  defp origin_host(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  ## Plumbing

  defp scope(conn), do: conn.path_params["slug"]

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp retry_after(conn, retry_ms) do
    put_resp_header(conn, "retry-after", Integer.to_string(ceil_seconds(retry_ms)))
  end

  defp ceil_seconds(ms) when is_integer(ms) and ms > 0, do: max(div(ms + 999, 1000), 1)
  defp ceil_seconds(_ms), do: 1

  defp send_rpc(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
