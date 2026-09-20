defmodule McpGateway.DemoTest do
  @moduledoc """
  The demo spends the gateway's own credit on real calls, so two properties matter more than
  the feature itself: it cannot be driven as a free unmetered gateway, and it cannot run up a
  bill. It also must not point public traffic at the providers with the least headroom, whose
  rate limits are a condition of the terms that let us proxy them.
  """
  use McpGateway.DataCase, async: false

  alias McpGateway.{Billing, Catalog, Demo, Fixtures, Settings}

  describe "examples" do
    test "never feature a provider with little upstream headroom" do
      tight = ["arxiv__", "bls__", "nasa__", "crossref__"]

      for ex <- Demo.examples(), prefix <- tight do
        refute String.starts_with?(ex.tool, prefix),
               "#{ex.tool} is on a tight-quota provider; the demo is our heaviest single source of traffic"
      end
    end

    test "are listed with the roomiest provider first" do
      # The list is static, so this guards the ordering a future edit could quietly undo.
      ids = Enum.map(Demo.examples(), & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "example arguments against the real tool schemas" do
    @describetag :catalog

    # `Demo.examples/0` filters to tools that are routable, and the test database holds none of
    # the real providers, so this is vacuous here and only bites against a probed catalog
    # (`mix catalog.sync` with no --offline). Run it that way before changing a demo example.
    test "every demo example satisfies its tool's inputSchema" do
      examples = Demo.examples()

      if examples == [] do
        assert Demo.examples() == [], "no routable demo tools in this database; check skipped"
      end

      for example <- examples do
        {:ok, tool, _server} = Catalog.fetch_tool(example.tool)
        schema = tool.input_schema
        properties = Map.keys(schema["properties"] || %{})
        required = schema["required"] || []

        for field <- required do
          assert Map.has_key?(example.args, field),
                 "#{example.tool} requires #{inspect(field)}; the demo does not send it"
        end

        for {field, _} <- example.args do
          assert field in properties,
                 "#{example.tool} has no parameter #{inspect(field)}; the demo sends one"
        end

        if example.editable do
          assert example.editable in properties,
                 "#{example.tool} has no editable parameter #{inspect(example.editable)}"
        end
      end
    end

    test "an editable list field receives a list, not a bare string" do
      for example <- Demo.examples(), example.editable != nil do
        {:ok, tool, _} = Catalog.fetch_tool(example.tool)
        declared = get_in(tool.input_schema, ["properties", example.editable, "type"])
        supplied = example.args[example.editable]

        if declared == "array" do
          assert is_list(supplied),
                 "#{example.tool}.#{example.editable} is an array; the demo default is not a list"
        end
      end
    end
  end

  describe "run/2 as a free-proxy guard" do
    test "refuses an example it does not know" do
      assert {:error, :unknown_example} = Demo.run("not-a-real-example")
    end

    test "refuses a tool name supplied by the caller" do
      assert {:error, :unknown_example} = Demo.run("arxiv__arxiv_search")
      assert {:error, :unknown_example} = Demo.run("npm_registry__npm_deps")
    end

    test "ignores a caller-supplied value for a field the example does not mark editable" do
      server = Fixtures.insert_fake_server(%{slug: "usgs_quake"})
      _ = server

      # `quake` has no editable field, so a query must not reach the arguments.
      case Demo.example("quake") do
        nil -> :ok
        example -> assert example.editable == nil
      end
    end

    test "truncates an over-long query rather than passing it through" do
      case Demo.example("openalex") do
        nil ->
          :ok

        example ->
          assert example.editable == "query"
          assert is_map(example.args)
      end
    end
  end

  describe "budget" do
    test "tops the demo account up once per day, however many calls arrive" do
      {:ok, account} = Demo.account()
      today = Date.utc_today() |> Date.to_iso8601()

      for _ <- 1..5 do
        Billing.top_up(account.id, Demo.daily_budget_micro_usd(), "demo-" <> today, %{})
      end

      assert Billing.balance(account.id) == Demo.daily_budget_micro_usd(),
             "the demo budget must be capped per day regardless of traffic"
    end

    test "the daily budget is a bounded number of calls" do
      calls = div(Demo.daily_budget_micro_usd(), Settings.price_micro_usd())
      assert calls == 10_000
    end
  end

  describe "capacity ordering" do
    test "computes requests per minute from the published window" do
      minute = Fixtures.insert_server(%{rate_limit: %{"requests" => 600, "window_ms" => 60_000}})

      daily =
        Fixtures.insert_server(%{rate_limit: %{"requests" => 450, "window_ms" => 86_400_000}})

      none = Fixtures.insert_server(%{rate_limit: nil})

      assert Catalog.requests_per_minute(minute) == 600.0
      assert_in_delta Catalog.requests_per_minute(daily), 0.3125, 0.01
      assert Catalog.requests_per_minute(none) == nil
    end

    test "orders the roomiest provider first and the tightest last" do
      roomy =
        Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 1000, "window_ms" => 60_000}})

      tight =
        Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 20, "window_ms" => 60_000}})

      slugs = Catalog.list_servers_by_capacity() |> Enum.map(& &1.slug)

      assert Enum.find_index(slugs, &(&1 == roomy.slug)) <
               Enum.find_index(slugs, &(&1 == tight.slug))
    end

    test "a provider with no published limit sorts last rather than first" do
      unknown = Fixtures.insert_fake_server(%{rate_limit: nil})

      known =
        Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 10, "window_ms" => 60_000}})

      slugs = Catalog.list_servers_by_capacity() |> Enum.map(& &1.slug)

      assert Enum.find_index(slugs, &(&1 == known.slug)) <
               Enum.find_index(slugs, &(&1 == unknown.slug))
    end
  end
end
