defmodule McpGateway.GatewayTest do
  @moduledoc """
  The money path. Every test here spends real ledger rows against a real subprocess upstream.
  """
  use McpGateway.DataCase, async: true

  alias McpGateway.Billing
  alias McpGateway.Fixtures
  alias McpGateway.Gateway
  alias McpGateway.Settings

  describe "call_tool/4 billing" do
    test "a successful call charges exactly one call's price and writes one ledger entry" do
      server = fake_server()
      %{account: account} = Fixtures.insert_account(1_000)

      assert {:ok, result, call_id} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "hi"})

      assert result["content"] == [%{"type" => "text", "text" => "echo: hi"}]
      assert is_binary(call_id)

      # The price is a product promise, not an implementation detail: $0.0001 = 100 micro-USD.
      assert Settings.price_micro_usd() == 100
      assert Billing.balance(account.id) == 900

      assert [charge] = charges(account)
      assert charge.amount_micro_usd == -100
      assert charge.balance_after_micro_usd == 900
      assert charge.idempotency_key == "charge:" <> call_id
      assert charge.metadata["tool"] == tool(server, "echo")
      assert charge.metadata["server"] == server.slug
    end

    test "an upstream failure is refunded, netting zero" do
      server = fake_server()
      %{account: account} = Fixtures.insert_account(1_000)

      # `crash` halts the subprocess mid-call, so the gateway never gets a result.
      assert {:error, :unavailable} = Gateway.call_tool(account, tool(server, "crash"), %{})

      assert Billing.balance(account.id) == 1_000

      entries = Enum.reject(Billing.list_entries(account.id), &(&1.kind == "topup"))
      assert entries |> Enum.map(& &1.kind) |> Enum.sort() == ["charge", "refund"]
      assert entries |> Enum.map(& &1.amount_micro_usd) |> Enum.sum() == 0

      assert refund = Enum.find(entries, &(&1.kind == "refund"))
      assert refund.metadata["reason"] == "unavailable"
    end

    test "a tool execution error (isError) is still charged" do
      server = fake_server()
      %{account: account} = Fixtures.insert_account(1_000)

      # The upstream reached the provider and came back with an actionable message. That is the
      # service, so it is billable.
      assert {:ok, %{"isError" => true} = result, _call_id} =
               Gateway.call_tool(account, tool(server, "fail"), %{})

      assert result["content"] == [%{"type" => "text", "text" => "boom"}]
      assert Billing.balance(account.id) == 1_000 - Settings.price_micro_usd()
      assert [_charge] = charges(account)
    end

    test "an unaffordable call is rejected before the upstream is contacted" do
      server = fake_server()
      %{account: account} = Fixtures.insert_account(0)

      assert {:error, :insufficient_funds} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "hi"})

      assert Billing.balance(account.id) == 0
      assert Billing.list_entries(account.id) == []
      refute upstream_running?(server.slug)
    end

    test "a balance smaller than one call is not enough" do
      server = fake_server()
      %{account: account} = Fixtures.insert_account(Settings.price_micro_usd() - 1)

      assert {:error, :insufficient_funds} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "hi"})

      assert Billing.balance(account.id) == Settings.price_micro_usd() - 1
      assert charges(account) == []
      refute upstream_running?(server.slug)
    end
  end

  describe "call_tool/4 rate limits" do
    test "an exhausted upstream quota is refused without charging for it" do
      # One request an hour: the second call in this test is certain to be over the limit.
      server = fake_server(%{rate_limit: %{"requests" => 1, "window_ms" => 3_600_000}})
      %{account: account} = Fixtures.insert_account(1_000)
      price = Settings.price_micro_usd()

      assert {:ok, _result, _id} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "one"})

      assert {:error, {:upstream_busy, retry_ms}} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "two"})

      assert is_integer(retry_ms) and retry_ms > 0

      # Our own quota management is not the caller's problem, so only the first call was billed.
      assert Billing.balance(account.id) == 1_000 - price
      assert length(charges(account)) == 1
    end
  end

  describe "call_tool/4 compliance gate" do
    test "a tool on a not_allowed server is simply unknown" do
      server = fake_server(%{compliance_verdict: "not_allowed"})
      %{account: account} = Fixtures.insert_account(1_000)

      assert {:error, :unknown_tool} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "hi"})

      assert Billing.balance(account.id) == 1_000
    end

    test "a tool whose compliance check has gone stale is simply unknown" do
      stale = Date.add(Date.utc_today(), -(Settings.get(:compliance_max_age_days) + 1))
      server = fake_server(%{compliance_checked_on: stale})
      %{account: account} = Fixtures.insert_account(1_000)

      assert {:error, :unknown_tool} =
               Gateway.call_tool(account, tool(server, "echo"), %{"text" => "hi"})

      assert Billing.balance(account.id) == 1_000
    end

    test "a scope restricts routing to that one server" do
      a = fake_server()
      b = fake_server()
      %{account: account} = Fixtures.insert_account(1_000)

      assert {:error, :unknown_tool} =
               Gateway.call_tool(account, tool(a, "echo"), %{"text" => "hi"}, scope: b.slug)

      assert Billing.balance(account.id) == 1_000
    end
  end

  describe "call_tool/4 concurrency" do
    test "concurrent calls from one account never overdraw the balance" do
      server = fake_server()
      price = Settings.price_micro_usd()

      # Warm the subprocess on a separate account so the handshake isn't on the clock for the
      # calls under test.
      %{account: warmer} = Fixtures.insert_account(10 * price)

      assert {:ok, _result, _id} =
               Gateway.call_tool(warmer, tool(server, "echo"), %{"text" => "w"})

      %{account: account} = Fixtures.insert_account(5 * price)

      outcomes =
        1..20
        |> Task.async_stream(
          fn n -> Gateway.call_tool(account, tool(server, "echo"), %{"text" => "n#{n}"}) end,
          max_concurrency: 20,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      assert Enum.count(outcomes, &match?({:ok, _result, _id}, &1)) == 5
      assert Enum.count(outcomes, &(&1 == {:error, :insufficient_funds})) == 15
      assert Billing.balance(account.id) == 0
      assert length(charges(account)) == 5

      # Every successful call got its own ledger row, not a shared one.
      ids = for {:ok, _result, id} <- outcomes, do: id
      assert length(Enum.uniq(ids)) == 5
    end
  end

  describe "list_tools/1 and describe/0" do
    test "list_tools only returns tools we may serve, and prices them" do
      listed = Fixtures.insert_fake_server()
      hidden = Fixtures.insert_fake_server(%{compliance_verdict: "unknown"})

      assert {:ok, tools, nil} = Gateway.list_tools([])
      names = Enum.map(tools, & &1["name"])

      assert tool(listed, "echo") in names
      refute Enum.any?(names, &String.starts_with?(&1, hidden.slug <> "__"))

      assert echo = Enum.find(tools, &(&1["name"] == tool(listed, "echo")))
      assert echo["inputSchema"]["type"] == "object"

      pricing = echo["_meta"][Settings.meta_key("pricing")]
      assert pricing["pricePerCallMicroUsd"] == Settings.price_micro_usd()
    end

    test "list_tools rejects a cursor it did not issue" do
      assert {:error, :invalid_cursor} = Gateway.list_tools(cursor: "not base64!!")
    end

    test "describe reports the versions we speak and what a call costs" do
      described = Gateway.describe()

      assert described["resultType"] == "complete"
      assert "2026-07-28" in described["supportedVersions"]
      assert described["capabilities"]["tools"] == %{}
      assert described["instructions"] =~ "Bearer"

      assert described["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "mcp-gateway"

      pricing = described["_meta"][Settings.meta_key("pricing")]
      assert pricing["pricePerCallMicroUsd"] == Settings.price_micro_usd()
      assert pricing["pricePerCallUsd"] == "0.0001"
    end
  end

  ## Helpers

  defp fake_server(attrs \\ %{}) do
    server = Fixtures.insert_fake_server(attrs)
    on_exit(fn -> Fixtures.stop_upstream(server.slug) end)
    server
  end

  defp tool(server, name), do: server.slug <> "__" <> name

  defp charges(account) do
    account.id
    |> Billing.list_entries()
    |> Enum.filter(&(&1.kind == "charge"))
  end

  # Proof that nothing was spawned: the upstream registry has no process for this slug.
  defp upstream_running?(slug) do
    McpGateway.Upstream.Registry
    |> Registry.select([{{{:"$1", :_}, :_, :_}, [{:==, :"$1", slug}], [true]}])
    |> Enum.any?()
  end
end
