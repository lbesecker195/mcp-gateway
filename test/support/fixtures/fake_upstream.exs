# A tiny MCP server over stdio, used only by the test suite. It speaks either era so tests can
# exercise the gateway's era probing without running any third-party code.
#
#   elixir fake_upstream.exs modern         # server/discover + per-request _meta
#   elixir fake_upstream.exs modern-slow    # modern, but answers server/discover very late
#   elixir fake_upstream.exs legacy         # initialize handshake; rejects server/discover
#   elixir fake_upstream.exs legacy-silent  # initialize handshake; ignores server/discover entirely
#
# Uses only the standard library (JSON ships with Elixir 1.18+).

defmodule FakeUpstream do
  @meta_version "io.modelcontextprotocol/protocolVersion"

  def tools do
    [
      %{
        "name" => "echo",
        "description" => "Echo the given text back.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"]
        }
      },
      %{
        "name" => "fail",
        "description" => "Always returns a tool execution error.",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "sleep",
        "description" => "Sleeps for `ms` milliseconds, then returns.",
        "inputSchema" => %{"type" => "object", "properties" => %{"ms" => %{"type" => "integer"}}}
      },
      %{
        "name" => "crash",
        "description" => "Exits the process.",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "env",
        "description" => "Reports which environment variables the process can see.",
        "inputSchema" => %{"type" => "object"}
      }
    ]
  end

  def run(era) do
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      case JSON.decode(String.trim(line)) do
        {:ok, msg} -> handle(era, msg)
        _ -> :ok
      end
    end)
  end

  # Notifications carry no id and get no reply.
  defp handle(_era, %{"method" => _} = msg) when not is_map_key(msg, "id"), do: :ok

  defp handle(era, %{"id" => id, "method" => method} = msg) do
    params = msg["params"] || %{}
    modern? = era in ["modern", "modern-slow"]

    cond do
      method == "server/discover" and modern? ->
        # modern-slow answers well after the gateway's probe timeout, like an npx server still
        # downloading its package. The gateway must still settle on the modern era.
        if era == "modern-slow", do: Process.sleep(4_000)

        reply(id, %{
          "resultType" => "complete",
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => %{"tools" => %{}},
          "_meta" => %{
            "io.modelcontextprotocol/serverInfo" => %{"name" => "fake", "version" => "0.0.1"}
          }
        })

      method == "server/discover" and era == "legacy" ->
        error(id, -32601, "Method not found")

      method == "server/discover" ->
        # legacy-silent: never answers, like a server that ignores unknown pre-initialize requests
        :ok

      method == "initialize" and not modern? ->
        reply(id, %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "fake", "version" => "0.0.1"}
        })

      method == "initialize" ->
        error(id, -32601, "Method not found")

      modern? and not is_map_key(params["_meta"] || %{}, @meta_version) ->
        error(id, -32602, "Missing _meta")

      method == "tools/list" ->
        reply(id, complete(modern?, %{"tools" => tools()}))

      method == "tools/call" ->
        call(id, modern?, params["name"], params["arguments"] || %{})

      true ->
        error(id, -32601, "Method not found")
    end
  end

  defp call(id, modern?, "echo", %{"text" => text}) do
    reply(
      id,
      complete(modern?, %{
        "content" => [%{"type" => "text", "text" => "echo: " <> text}],
        "isError" => false
      })
    )
  end

  defp call(id, _modern?, "echo", _args), do: error(id, -32602, "text is required")

  defp call(id, modern?, "fail", _args) do
    reply(
      id,
      complete(modern?, %{"content" => [%{"type" => "text", "text" => "boom"}], "isError" => true})
    )
  end

  defp call(id, modern?, "sleep", args) do
    Process.sleep(args["ms"] || 0)

    reply(
      id,
      complete(modern?, %{
        "content" => [%{"type" => "text", "text" => "slept"}],
        "isError" => false
      })
    )
  end

  defp call(_id, _modern?, "crash", _args), do: System.halt(1)

  defp call(id, modern?, "env", _args) do
    seen =
      ~w(DATABASE_URL SECRET_KEY_BASE GATEWAY_TEST_SECRET FAKE_UPSTREAM_KEY)
      |> Enum.map(fn name -> "#{name}=#{System.get_env(name) || "unset"}" end)
      |> Enum.join(";")

    reply(
      id,
      complete(modern?, %{"content" => [%{"type" => "text", "text" => seen}], "isError" => false})
    )
  end

  defp call(id, _modern?, name, _args), do: error(id, -32602, "Unknown tool: #{name}")

  defp complete(true, result), do: Map.put(result, "resultType", "complete")
  defp complete(false, result), do: result

  defp reply(id, result), do: emit(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, code, message),
    do:
      emit(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  defp emit(map), do: IO.puts(JSON.encode!(map))
end

FakeUpstream.run(List.first(System.argv()) || "modern")
