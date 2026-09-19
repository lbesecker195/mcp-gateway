defmodule McpGateway.Upstream do
  @moduledoc """
  Talks to the upstream MCP servers that sit behind the catalog.

  An upstream is a `McpGateway.Catalog.Server` (or any map with `:slug` and a string-keyed
  `:upstream` config) whose `upstream["type"]` is `"stdio"` (a subprocess we launch) or
  `"streamable-http"` (a remote endpoint). Both transports speak modern and legacy MCP; the
  era is probed per upstream.

  Errors are `{:error, reason}` where reason is one of `:timeout`, `:unavailable`,
  `:protocol`, `{:start_failed, why}`, `{:http_status, status}` or
  `{:rpc_error, code, message, data}`.
  """

  alias McpGateway.Settings
  alias McpGateway.Upstream.{HTTP, Stdio}

  @max_pages 50

  @doc "Calls one tool on the upstream and returns its `tools/call` result map."
  def call_tool(server, tool_name, arguments, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Settings.get(:upstream_call_timeout_ms))
    request(server, "tools/call", %{"name" => tool_name, "arguments" => arguments}, timeout)
  end

  @doc "Lists every tool the upstream exposes, following pagination."
  def list_tools(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Settings.get(:upstream_startup_timeout_ms))
    collect_tools(server, nil, timeout, [], 0)
  end

  defp collect_tools(_server, _cursor, _timeout, _acc, pages) when pages >= @max_pages do
    {:error, :protocol}
  end

  defp collect_tools(server, cursor, timeout, acc, pages) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case request(server, "tools/list", params, timeout) do
      {:ok, %{"tools" => tools} = result} when is_list(tools) ->
        acc = acc ++ tools

        case result["nextCursor"] do
          next when is_binary(next) and next != "" ->
            collect_tools(server, next, timeout, acc, pages + 1)

          _ ->
            {:ok, acc}
        end

      {:ok, _} ->
        {:error, :protocol}

      {:error, _} = error ->
        error
    end
  end

  defp request(server, method, params, timeout) do
    case server.upstream["type"] do
      "stdio" -> Stdio.request(server, method, params, timeout)
      "streamable-http" -> HTTP.request(server, method, params, timeout)
      other -> {:error, {:start_failed, {:unknown_transport, other}}}
    end
  end
end
