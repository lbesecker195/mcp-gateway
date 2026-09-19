defmodule McpGateway.Upstream.StdioTest do
  use ExUnit.Case, async: true

  import McpGateway.Fixtures, only: [fake_stdio_upstream: 2, stop_upstream: 1, unique_slug: 0]

  alias McpGateway.Upstream

  # Each test gets its own upstream process, stopped when the test exits.
  defp server(era, env \\ %{}) do
    slug = unique_slug()
    on_exit(fn -> stop_upstream(slug) end)
    %{slug: slug, upstream: fake_stdio_upstream(era, env)}
  end

  describe "modern upstream (server/discover)" do
    test "lists tools and calls one, with resultType passed through" do
      server = server("modern")

      assert {:ok, tools} = Upstream.list_tools(server)
      assert Enum.map(tools, & &1["name"]) == ~w(echo fail sleep crash env)

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{"text" => "hi"})
      assert result["content"] == [%{"type" => "text", "text" => "echo: hi"}]
      assert result["resultType"] == "complete"
    end

    test "a slow probe answer still wins after the legacy fallback was sent" do
      # The server answers server/discover after the probe timeout, so the gateway has already
      # sent `initialize` and had it rejected as an unknown method. The late discover answer
      # must still settle the era as modern rather than failing the upstream.
      server = server("modern-slow")

      assert {:ok, result} =
               Upstream.call_tool(server, "echo", %{"text" => "late"}, timeout: 15_000)

      assert result["content"] == [%{"type" => "text", "text" => "echo: late"}]
      assert result["resultType"] == "complete"
    end
  end

  describe "legacy upstream (initialize handshake)" do
    test "falls back to initialize when server/discover is rejected" do
      server = server("legacy")

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{"text" => "hi"})
      assert result["content"] == [%{"type" => "text", "text" => "echo: hi"}]
      refute Map.has_key?(result, "resultType")
    end

    test "falls back to initialize when the server never answers server/discover" do
      server = server("legacy-silent")

      assert {:ok, result} = Upstream.call_tool(server, "echo", %{"text" => "quiet"})
      assert result["content"] == [%{"type" => "text", "text" => "echo: quiet"}]
    end
  end

  describe "errors" do
    test "a JSON-RPC error from the upstream is returned as {:rpc_error, ...}" do
      server = server("modern")

      assert {:error, {:rpc_error, -32602, "Unknown tool: nope", nil}} =
               Upstream.call_tool(server, "nope", %{})
    end

    test "a tool execution error (isError) is a normal result" do
      server = server("modern")
      assert {:ok, %{"isError" => true}} = Upstream.call_tool(server, "fail", %{})
    end

    test "a slow call times out and the upstream keeps serving" do
      server = server("modern")

      assert {:error, :timeout} =
               Upstream.call_tool(server, "sleep", %{"ms" => 5_000}, timeout: 300)

      assert {:ok, %{"isError" => false}} =
               Upstream.call_tool(server, "echo", %{"text" => "still up"})
    end

    test "a crashing upstream reports :unavailable and is restarted on the next call" do
      server = server("modern")

      assert {:ok, _} = Upstream.call_tool(server, "echo", %{"text" => "warm"})
      assert {:error, :unavailable} = Upstream.call_tool(server, "crash", %{})

      assert {:ok, %{"isError" => false}} =
               Upstream.call_tool(server, "echo", %{"text" => "again"})
    end

    test "only allow-listed launch commands can be spawned" do
      server = %{
        slug: unique_slug(),
        upstream: %{"type" => "stdio", "command" => "sh", "args" => ["-c", "true"]}
      }

      assert {:error, {:start_failed, {:command_not_allowed, "sh"}}} =
               Upstream.call_tool(server, "echo", %{})
    end
  end

  describe "concurrency" do
    test "many simultaneous calls are multiplexed and each gets its own answer" do
      server = server("modern")
      # Warm the process so the concurrent calls don't all wait on the handshake.
      assert {:ok, _} = Upstream.call_tool(server, "echo", %{"text" => "warm"})

      results =
        1..20
        |> Task.async_stream(
          fn n -> {n, Upstream.call_tool(server, "echo", %{"text" => "n#{n}"})} end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, {n, {:ok, result}}} -> {n, hd(result["content"])["text"]} end)

      assert Enum.all?(results, fn {n, text} -> text == "echo: n#{n}" end)
    end
  end

  describe "environment isolation" do
    test "the subprocess sees declared variables and none of the gateway's own" do
      System.put_env("GATEWAY_TEST_SECRET", "must-not-leak")
      on_exit(fn -> System.delete_env("GATEWAY_TEST_SECRET") end)

      server = server("modern", %{"FAKE_UPSTREAM_KEY" => "declared-value"})

      assert {:ok, %{"content" => [%{"text" => seen}]}} = Upstream.call_tool(server, "env", %{})
      assert seen =~ "GATEWAY_TEST_SECRET=unset"
      assert seen =~ "DATABASE_URL=unset"
      assert seen =~ "FAKE_UPSTREAM_KEY=declared-value"
    end

    test "from_env resolves a variable from the gateway's environment at launch" do
      System.put_env("GATEWAY_TEST_UPSTREAM_TOKEN", "resolved")
      on_exit(fn -> System.delete_env("GATEWAY_TEST_UPSTREAM_TOKEN") end)

      server =
        server("modern", %{"FAKE_UPSTREAM_KEY" => %{"from_env" => "GATEWAY_TEST_UPSTREAM_TOKEN"}})

      assert {:ok, %{"content" => [%{"text" => seen}]}} = Upstream.call_tool(server, "env", %{})
      assert seen =~ "FAKE_UPSTREAM_KEY=resolved"
    end

    test "a from_env variable that isn't set fails closed instead of launching without it" do
      server =
        server("modern", %{
          "FAKE_UPSTREAM_KEY" => %{"from_env" => "GATEWAY_TEST_NOT_SET_ANYWHERE"}
        })

      assert {:error, {:start_failed, {:missing_env, "GATEWAY_TEST_NOT_SET_ANYWHERE"}}} =
               Upstream.call_tool(server, "env", %{})
    end
  end
end
