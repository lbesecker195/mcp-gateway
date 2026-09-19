defmodule McpGateway.Fixtures do
  @moduledoc "Helpers for building catalog and billing data in tests."

  alias McpGateway.{Billing, Repo}
  alias McpGateway.Catalog.{Server, Tool}

  @fake_upstream Path.expand("fixtures/fake_upstream.exs", __DIR__)

  @doc """
  Upstream config for the fixture server. `era` is `"modern"`, `"legacy"` or `"legacy-silent"`.
  """
  def fake_stdio_upstream(era \\ "modern", env \\ %{}) do
    %{"type" => "stdio", "command" => "elixir", "args" => [@fake_upstream, era], "env" => env}
  end

  def unique_slug, do: "fake#{System.unique_integer([:positive])}"

  def insert_server(attrs \\ %{}) do
    attrs = Map.new(attrs)
    slug = Map.get(attrs, :slug, unique_slug())
    today = Map.get(attrs, :compliance_checked_on, Date.utc_today())

    base = %{
      name: "dev.mcpharbor.gateway/" <> slug,
      slug: slug,
      version: "1.0.0",
      title: "Fake #{slug}",
      description: "A fake server for tests",
      upstream: fake_stdio_upstream(),
      compliance: %{
        "verdict" => "allowed",
        "terms_url" => "https://example.com/terms",
        "checked_at" => Date.to_iso8601(today),
        "notes" => "test fixture"
      },
      compliance_verdict: "allowed",
      compliance_checked_on: today,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second),
      docs: %{}
    }

    %Server{} |> Server.changeset(Map.merge(base, attrs)) |> Repo.insert!()
  end

  def insert_tool(%Server{} = server, upstream_name, attrs \\ %{}) do
    {:ok, base} =
      Tool.build_attrs(server.slug, %{
        "name" => upstream_name,
        "description" => "The #{upstream_name} tool",
        "inputSchema" => %{"type" => "object"}
      })

    Repo.insert!(struct(Tool, Map.merge(base, Map.new(attrs)) |> Map.put(:server_id, server.id)))
  end

  @doc "A server with the fixture tools already in the catalog. Returns the server."
  def insert_fake_server(attrs \\ %{}) do
    server = insert_server(attrs)
    for name <- ~w(echo fail sleep crash env), do: insert_tool(server, name)
    server
  end

  @doc "An account with `balance_micro_usd` credit and one API key. Returns `%{account:, key:}`."
  def insert_account(balance_micro_usd \\ 1_000_000) do
    {:ok, account} = Billing.create_account("test account")

    if balance_micro_usd > 0 do
      {:ok, _} =
        Billing.top_up(
          account.id,
          balance_micro_usd,
          "seed-#{System.unique_integer([:positive])}"
        )
    end

    {:ok, key, _api_key} = Billing.create_api_key(account)
    %{account: account, key: key}
  end

  @doc "Stops the running stdio upstream process(es) for one server slug. Call from `on_exit`."
  def stop_upstream(slug) do
    pids =
      Registry.select(McpGateway.Upstream.Registry, [
        {{{:"$1", :_}, :"$2", :_}, [{:==, :"$1", slug}], [:"$2"]}
      ])

    for pid <- pids, do: DynamicSupervisor.terminate_child(McpGateway.Upstream.Supervisor, pid)
    :ok
  end

  @doc "Stops every running stdio upstream process. Only safe from non-async tests."
  def stop_upstreams do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(McpGateway.Upstream.Supervisor) do
      DynamicSupervisor.terminate_child(McpGateway.Upstream.Supervisor, pid)
    end

    :ok
  end
end
