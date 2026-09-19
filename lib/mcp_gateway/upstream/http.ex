defmodule McpGateway.Upstream.HTTP do
  @moduledoc """
  Streamable HTTP upstream client: the remote counterpart to `McpGateway.Upstream.Stdio`.

  Every JSON-RPC request is its own HTTP POST. The server answers with either
  `application/json` (one object) or `text/event-stream` (an SSE stream scoped to that
  request, carrying request-related notifications before the final response); both are
  supported, and the SSE stream is parsed incrementally so we stop reading the moment the
  response arrives.

  The era is detected the way the spec's HTTP backward-compatibility rule prescribes: the
  first real request is sent as a modern one, and only a `400`/`404`/`405` whose body is
  *not* a recognized modern JSON-RPC error makes us fall back to the legacy `initialize`
  handshake. A recognized modern error (`-32020`, `-32021`, `-32022`, or a JSON-RPC error
  under `404`/`405`) means the server is modern and we stay modern — except that an
  `UnsupportedProtocolVersionError` names the versions the server *does* speak, and if none
  of them is modern we honour that list and switch to the handshake. The verdict, and any
  legacy session id, is cached per URL in `McpGateway.Upstream.EraCache`, and dropped when
  the cached assumption later fails so the next call re-probes.

  Timing: one call gets one deadline, and every HTTP exchange it makes shares it. The
  exchange runs in a throwaway process that is killed when the deadline passes, because the
  HTTP client's own timeouts do not bound a response as a whole — see `under_deadline/2`.
  A `tools/call` is charged before it is sent, so a call that never returns is a charge that
  is never refunded.

  Security:

    * The endpoint URL comes only from the catalog entry, never from request input, and
      must be `https` unless it points at loopback (so tests and local upstreams work).
    * Redirects are never followed: an upstream cannot move us to another host.
    * Requests are never retried. A `tools/call` is not idempotent and one call is one
      billable unit.
    * Header values declared as `{"from_env": "VAR"}` fail closed when the variable is
      unset; the request is not sent without them. Values are never logged, and neither is
      any failure reason that could carry them.

  Not implemented: mirroring `x-mcp-header`-annotated tool arguments into
  `Mcp-Param-*` headers. That needs the tool's `inputSchema`, which `request/4` does not
  receive; it belongs with the catalog-side tool record.

  Not implemented: the deprecated 2024-11-05 HTTP+SSE transport (a `GET` returning an
  `endpoint` event). A `405` without a modern error body falls back to `initialize` and
  stops there.

  Spec: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
  """

  require Logger

  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Settings
  alias McpGateway.Upstream.EraCache

  @accept "application/json, text/event-stream"
  @max_body_bytes 8 * 1024 * 1024
  @connect_timeout_ms 10_000

  # Protocol headers we set ourselves; a catalog entry may not override them.
  @reserved_headers ~w(accept content-type content-length host mcp-protocol-version mcp-method
                       mcp-name mcp-session-id)

  # RFC 9110 field-name token syntax.
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  # RFC 9110 field values: visible ASCII, space and horizontal tab.
  @header_value ~r/\A[\x20-\x7E\t]*\z/

  @doc """
  Sends one JSON-RPC request to a `streamable-http` upstream and returns its result.

  Mirrors `McpGateway.Upstream.Stdio.request/4`, including the hard `timeout`: `{:ok, result}`
  or `{:error, reason}` where reason is `:timeout`, `:unavailable`, `:protocol`,
  `{:start_failed, why}`, `{:http_status, status}` or `{:rpc_error, code, message, data}`.
  """
  @spec request(map(), String.t(), map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def request(server, method, params, timeout) do
    with {:ok, url} <- endpoint_url(server),
         {:ok, headers} <- static_headers(server) do
      conn = %{
        url: url,
        headers: headers,
        deadline: System.monotonic_time(:millisecond) + timeout
      }

      dispatch(conn, EraCache.get(url), method, params)
    end
  end

  ## Era dispatch

  # `modern/5` answers `{:ok, result}` or `{:error, reason}` when it settled the call itself,
  # `{:legacy_hint, status}` when the status alone suggests a pre-modern server, and
  # `{:legacy_offer, version}` when the server named its supported versions and only legacy
  # ones are on the list. A hint is a guess; an offer is the server's own answer.

  # Unknown era: the request itself is the probe.
  defp dispatch(conn, nil, method, params) do
    case modern(conn, hd(P.modern_versions()), method, params) do
      {:legacy_hint, status} ->
        Logger.debug(
          "upstream #{host(conn.url)}: HTTP #{status} without a modern error, using initialize"
        )

        fall_back(conn, method, params, nil)

      {:legacy_offer, version} ->
        Logger.debug("upstream #{host(conn.url)}: offers only legacy MCP, using initialize")
        fall_back(conn, method, params, version)

      other ->
        other
    end
  end

  defp dispatch(conn, :modern, method, params) do
    case modern(conn, hd(P.modern_versions()), method, params) do
      {:legacy_hint, status} ->
        # The cached verdict no longer holds; forget it so the next call probes again.
        EraCache.delete(conn.url)
        {:error, {:http_status, status}}

      {:legacy_offer, version} ->
        # Not a guess: the server enumerated the versions it speaks and none of them is
        # modern, so a dual-era upstream has retired modern support. Switch now instead of
        # failing every call from here on.
        Logger.debug("upstream #{host(conn.url)}: no longer modern, using initialize")
        EraCache.delete(conn.url)
        fall_back(conn, method, params, version)

      other ->
        other
    end
  end

  defp dispatch(conn, {:legacy, version, session}, method, params) do
    legacy_request(conn, version, session, method, params, true)
  end

  ## Modern era

  defp modern(conn, version, method, params, attempt \\ 0) do
    id = next_id()

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => modern_params(params, version)
    }

    headers =
      [{"mcp-protocol-version", version}, {"mcp-method", P.encode_header_value(method)}] ++
        name_header(method, params)

    with {:ok, resp} <- post(conn, headers, body, id) do
      case classify_modern(resp, id) do
        {:result, result} ->
          remember(conn.url, :modern)
          {:ok, result}

        # -32022, UnsupportedProtocolVersionError. The server is speaking to us, it just does
        # not implement the version we sent; the spec says to pick a mutually supported one
        # from `data.supported` and retry rather than give up.
        {:rpc, -32022, message, data} ->
          case negotiate(version, data) do
            {:modern, other} when attempt == 0 ->
              remember(conn.url, :modern)
              modern(conn, other, method, params, attempt + 1)

            {:legacy, other} ->
              # Don't remember `:modern`: the handshake that follows settles the era.
              {:legacy_offer, other}

            _none ->
              remember(conn.url, :modern)
              {:error, {:rpc_error, -32022, message, data}}
          end

        {:rpc, code, message, data} ->
          remember(conn.url, :modern)
          {:error, {:rpc_error, code, message, data}}

        {:legacy_hint, status} ->
          {:legacy_hint, status}

        {:bad, reason} ->
          {:error, reason}
      end
    end
  end

  # The header value MUST equal the body value, so both come from the same place.
  defp modern_params(params, version) do
    meta = Map.put(P.client_meta(), P.meta_version_key(), version)
    Map.put(params, "_meta", meta)
  end

  defp name_header("tools/call", %{"name" => name}) when is_binary(name),
    do: [{"mcp-name", P.encode_header_value(name)}]

  defp name_header("prompts/get", %{"name" => name}) when is_binary(name),
    do: [{"mcp-name", P.encode_header_value(name)}]

  defp name_header("resources/read", %{"uri" => uri}) when is_binary(uri),
    do: [{"mcp-name", P.encode_header_value(uri)}]

  defp name_header(_method, _params), do: []

  # Picks the version to retry an UnsupportedProtocolVersionError with. A modern version is
  # preferred; failing that, the newest legacy version we speak, which means the handshake.
  # `Upstream.Stdio` reads the same list the same way.
  defp negotiate(sent, %{"supported" => supported}) when is_list(supported) do
    modern = Enum.find(P.modern_versions(), &(&1 in supported and &1 != sent))
    legacy = Enum.find(P.legacy_versions(), &(&1 in supported))

    cond do
      modern -> {:modern, modern}
      legacy -> {:legacy, legacy}
      true -> :none
    end
  end

  defp negotiate(_sent, _data), do: :none

  ## Legacy era

  defp fall_back(conn, method, params, preferred) do
    with {:ok, version, session} <- initialize(conn, preferred) do
      legacy_request(conn, version, session, method, params, false)
    end
  end

  # `preferred` is the version the server asked for, when it told us; otherwise the newest
  # legacy revision we speak.
  defp initialize(conn, preferred) do
    id = next_id()
    requested = if preferred in P.legacy_versions(), do: preferred, else: hd(P.legacy_versions())

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => requested,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mcp-gateway", "version" => Settings.server_version()}
      }
    }

    # No MCP-Protocol-Version header yet: the version is what this request negotiates.
    with {:ok, resp} <- post(conn, [], body, id) do
      case classify_legacy(resp, id) do
        {:result, %{"protocolVersion" => version}} when is_binary(version) ->
          if version in P.supported_versions() do
            session = session_id(resp)
            notify_initialized(conn, version, session)
            EraCache.put(conn.url, {:legacy, version, session})
            {:ok, version, session}
          else
            {:error, {:start_failed, {:unsupported_versions, [version]}}}
          end

        {:result, _} ->
          {:error, {:start_failed, {:initialize_failed, :protocol}}}

        {:rpc, code, message, data} ->
          {:error,
           {:start_failed,
            {:initialize_failed, %{"code" => code, "message" => message, "data" => data}}}}

        {:bad, reason} ->
          {:error, {:start_failed, {:initialize_failed, reason}}}
      end
    end
  end

  defp notify_initialized(conn, version, session) do
    _ =
      post(
        conn,
        legacy_headers(version, session),
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        nil
      )

    :ok
  end

  defp legacy_request(conn, version, session, method, params, retry?) do
    id = next_id()
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    with {:ok, resp} <- post(conn, legacy_headers(version, session), body, id) do
      # 404 on an established session means the server dropped it; re-initialize once.
      if resp.status == 404 and retry? do
        EraCache.delete(conn.url)

        with {:ok, new_version, new_session} <- initialize(conn, version) do
          legacy_request(conn, new_version, new_session, method, params, false)
        end
      else
        case classify_legacy(resp, id) do
          {:result, result} -> {:ok, result}
          {:rpc, code, message, data} -> {:error, {:rpc_error, code, message, data}}
          {:bad, reason} -> {:error, reason}
        end
      end
    end
  end

  defp legacy_headers(version, nil), do: [{"mcp-protocol-version", version}]

  defp legacy_headers(version, session),
    do: [{"mcp-protocol-version", version}, {"mcp-session-id", session}]

  defp session_id(resp) do
    case Req.Response.get_header(resp, "mcp-session-id") do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  ## Response classification

  defp classify_modern(resp, id) do
    status = resp.status
    message = parse_message(resp, id)

    cond do
      status in 200..299 ->
        case message do
          {:ok, %{"result" => result}} when is_map(result) -> {:result, result}
          {:ok, %{"error" => error}} -> rpc(error)
          _ -> {:bad, :protocol}
        end

      status in [400, 404, 405] ->
        case message do
          {:ok, %{"error" => %{"code" => code} = error}} when is_integer(code) ->
            if modern_error?(status, code), do: rpc(error), else: {:legacy_hint, status}

          _ ->
            {:legacy_hint, status}
        end

      true ->
        case message do
          {:ok, %{"error" => error}} -> rpc(error)
          _ -> {:bad, {:http_status, status}}
        end
    end
  end

  # A modern server uses 400 for header-validation, capability and version failures, and
  # 404 with a JSON-RPC error for an unimplemented method. Anything else under these
  # statuses is a server that never understood the modern request at all.
  defp modern_error?(400, code),
    do: code in [P.header_mismatch(), P.missing_capability(), P.unsupported_version()]

  defp modern_error?(_status, _code), do: true

  defp classify_legacy(resp, id) do
    message = parse_message(resp, id)

    cond do
      resp.status in 200..299 ->
        case message do
          {:ok, %{"result" => result}} when is_map(result) -> {:result, result}
          {:ok, %{"error" => error}} -> rpc(error)
          _ -> {:bad, :protocol}
        end

      match?({:ok, %{"error" => _}}, message) ->
        {:ok, %{"error" => error}} = message
        rpc(error)

      true ->
        {:bad, {:http_status, resp.status}}
    end
  end

  defp rpc(%{"code" => code} = error) when is_integer(code),
    do: {:rpc, code, Map.get(error, "message", ""), error["data"]}

  defp rpc(_error), do: {:bad, :protocol}

  defp parse_message(resp, id) do
    state = Req.Response.get_private(resp, :mcp, empty_state())

    cond do
      state.overflow ->
        :none

      sse?(resp) ->
        if state.found, do: {:ok, state.found}, else: :none

      true ->
        case Jason.decode(state.buf) do
          {:ok, %{} = message} -> if response?(message, id), do: {:ok, message}, else: :none
          _ -> :none
        end
    end
  end

  defp response?(message, id) do
    (Map.has_key?(message, "result") or Map.has_key?(message, "error")) and
      id_match?(Map.get(message, "id"), id)
  end

  # An error response may omit the id when the request could not be read.
  defp id_match?(nil, _want), do: true

  defp id_match?(got, want) when is_integer(got) or is_binary(got),
    do: to_string(got) == to_string(want)

  defp id_match?(_got, _want), do: false

  ## HTTP

  defp post(conn, headers, body, id) do
    case remaining(conn) do
      left when left <= 0 ->
        {:error, :timeout}

      left ->
        options =
          [
            method: :post,
            url: conn.url,
            headers: [{"accept", @accept}] ++ conn.headers ++ headers,
            json: body,
            into: collector(id),
            # `receive_timeout` bounds the wait for each chunk, and `request_timeout` the
            # whole response — but Finch documents the latter as HTTP/1 only and best
            # effort, so `under_deadline/2` is what actually ends the call on time.
            receive_timeout: left,
            request_timeout: left,
            connect_options: [timeout: min(left, @connect_timeout_ms)],
            retry: false,
            redirect: false,
            decode_body: false
          ] ++ req_options()

        under_deadline(left, fn -> send_request(options) end)
    end
  end

  defp send_request(options) do
    case Req.request(Req.new(options)) do
      {:ok, resp} -> {:ok, resp}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, %Req.TransportError{}} -> {:error, :unavailable}
      {:error, %Req.HTTPError{}} -> {:error, :protocol}
      {:error, _other} -> {:error, :unavailable}
    end
  end

  # Runs `fun` in a throwaway process and abandons it once `timeout` has passed.
  #
  # Nothing in the HTTP client bounds an exchange as a whole: `receive_timeout` restarts on
  # every chunk, and `request_timeout` is HTTP/1 only and explicitly best effort. An upstream
  # that drips SSE keep-alive comments forever therefore holds a `tools/call` open for as
  # long as it likes — and that call was charged before it was sent, so it is also a charge
  # whose refund never runs, on top of a pinned caller connection and connection-pool slot.
  # `McpGateway.Upstream.Stdio` bounds its requests with a timer for the same reason.
  #
  # Killing the worker abandons the connection, which is the only safe thing to do with a
  # response we stopped reading half-way; the pool sees its owner go down and closes it.
  # The worker is deliberately not linked, so killing it cannot take the caller with it.
  defp under_deadline(timeout, fun) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        outcome =
          try do
            {:returned, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(parent, {ref, outcome})
      end)

    receive do
      {^ref, {:returned, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      # Raise in the caller, exactly as a direct call would have. The reason is never logged:
      # an exception from the HTTP client can carry the request headers, and those hold
      # upstream credentials.
      {^ref, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :unavailable}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        # A result that raced the kill is already in the mailbox; drop it.
        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  # Collects the response body. For an SSE stream it parses events as they arrive and halts
  # the stream as soon as the response to `id` has been seen, so a server that keeps the
  # stream open afterwards does not hold the call open until the timeout.
  defp collector(id) do
    fn {:data, chunk}, {req, resp} ->
      state = Req.Response.get_private(resp, :mcp, empty_state())
      state = %{state | bytes: state.bytes + byte_size(chunk)}

      cond do
        is_nil(id) ->
          {:cont, {req, Req.Response.put_private(resp, :mcp, state)}}

        state.bytes > @max_body_bytes ->
          {:halt, {req, Req.Response.put_private(resp, :mcp, %{state | overflow: true, buf: ""})}}

        sse?(resp) ->
          state = consume_sse(%{state | buf: state.buf <> chunk}, id)
          resp = Req.Response.put_private(resp, :mcp, state)
          if state.found, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}

        true ->
          {:cont, {req, Req.Response.put_private(resp, :mcp, %{state | buf: state.buf <> chunk})}}
      end
    end
  end

  defp empty_state, do: %{buf: "", data: [], found: nil, bytes: 0, overflow: false}

  defp sse?(resp) do
    resp
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "text/event-stream"))
  end

  ## Server-sent events

  defp consume_sse(state, id) do
    {lines, rest} = take_lines(state.buf)
    feed(lines, %{state | buf: rest}, id)
  end

  defp feed([], state, _id), do: state

  defp feed([line | rest], state, id) do
    cond do
      # A blank line dispatches the buffered event.
      line == "" ->
        case event_response(state.data, id) do
          nil -> feed(rest, %{state | data: []}, id)
          found -> %{state | data: [], found: found}
        end

      # A line starting with a colon is a comment (keep-alives use it); ignore it.
      String.starts_with?(line, ":") ->
        feed(rest, state, id)

      true ->
        case field(line) do
          {"data", value} -> feed(rest, %{state | data: [value | state.data]}, id)
          _other -> feed(rest, state, id)
        end
    end
  end

  # Splits off every complete line. A trailing "\r" is held back: the next chunk may make
  # it a "\r\n".
  defp take_lines(buf) do
    {scan, tail} =
      if String.ends_with?(buf, "\r"),
        do: {binary_part(buf, 0, byte_size(buf) - 1), "\r"},
        else: {buf, ""}

    parts = Regex.split(~r/\r\n|\n|\r/, scan)
    {lines, [rest]} = Enum.split(parts, length(parts) - 1)
    {lines, rest <> tail}
  end

  defp field(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> {name, strip_space(value)}
      [name] -> {name, ""}
    end
  end

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value

  defp event_response([], _id), do: nil

  defp event_response(data, id) do
    payload = data |> Enum.reverse() |> Enum.join("\n")

    case Jason.decode(payload) do
      # Notifications carry no result or error, so they never match.
      {:ok, %{} = message} -> if response?(message, id), do: message, else: nil
      _ -> nil
    end
  end

  ## Upstream configuration

  defp endpoint_url(server) do
    case Map.get(server.upstream, "url") do
      url when is_binary(url) ->
        uri = URI.parse(url)

        cond do
          uri.host in [nil, ""] ->
            {:error, {:start_failed, {:invalid_url, uri.scheme}}}

          uri.scheme == "https" ->
            {:ok, url}

          uri.scheme == "http" and loopback?(uri.host) ->
            {:ok, url}

          true ->
            {:error, {:start_failed, {:insecure_url, "#{uri.scheme}://#{uri.host}"}}}
        end

      _ ->
        {:error, {:start_failed, :missing_url}}
    end
  end

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp host(url), do: URI.parse(url).host

  defp static_headers(server) do
    declared = Map.get(server.upstream, "headers") || %{}

    Enum.reduce_while(declared, {:ok, []}, fn {name, value}, {:ok, acc} ->
      with :ok <- check_header_name(name),
           {:ok, resolved} <- resolve_header(name, value) do
        {:cont, {:ok, acc ++ [{name, resolved}]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_header_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@header_name, name) ->
        {:error, {:start_failed, {:invalid_header_name, name}}}

      String.downcase(name) in @reserved_headers ->
        {:error, {:start_failed, {:reserved_header, name}}}

      true ->
        :ok
    end
  end

  defp check_header_name(name),
    do: {:error, {:start_failed, {:invalid_header_name, inspect(name)}}}

  defp resolve_header(name, value) when is_binary(value), do: check_header_value(name, value)

  defp resolve_header(name, %{"from_env" => source}) when is_binary(source) do
    # Fail closed: an upstream that needs a key is not called without it.
    case System.get_env(source) do
      nil -> {:error, {:start_failed, {:missing_env, source}}}
      resolved -> check_header_value(name, resolved)
    end
  end

  defp resolve_header(name, _value), do: {:error, {:start_failed, {:invalid_header_value, name}}}

  # The value itself never appears in the error: it is usually a credential.
  defp check_header_value(name, value) do
    if Regex.match?(@header_value, value),
      do: {:ok, value},
      else: {:error, {:start_failed, {:invalid_header_value, name}}}
  end

  ## Misc

  defp remember(url, value) do
    if EraCache.get(url) != value, do: EraCache.put(url, value)
    :ok
  end

  defp remaining(conn), do: conn.deadline - System.monotonic_time(:millisecond)

  defp next_id, do: System.unique_integer([:positive, :monotonic])

  # Extra Req options, used by tests to route requests through a `Req.Test` stub instead of
  # the network. Empty in dev and production.
  defp req_options, do: Application.get_env(:mcp_gateway, :upstream_req_options, [])
end
