defmodule McpGateway.Demo do
  @moduledoc """
  The public "try it" demo behind `/try`.

  Visitors get to make a real, billed call through the real gateway, because a demo that fakes
  the response would not show what it claims to show. The credit comes from a gateway-owned
  account, which creates two problems this module exists to bound:

    * **It must not become a free proxy.** Only the examples below can be run, and only their
      one marked field can be edited. Arbitrary tool calls with arbitrary arguments are refused,
      so the demo cannot be driven as an unmetered gateway.
    * **It must not be able to run up a bill.** The demo account is topped up once per UTC day
      with an idempotency key derived from that date, so the demo's spend is capped at
      `@daily_budget_micro_usd` per day no matter how much traffic arrives. When the day's
      budget is gone, calls fail with `{:error, :demo_budget_exhausted}` rather than drawing on
      anything else.

  Per-visitor rate limiting is applied by the controller on top of this.
  """

  alias McpGateway.{Billing, Catalog, Gateway, Settings}

  @demo_account_name "__demo__"
  # $1.00 a day: 10,000 demo calls, and a hard ceiling on what the demo can ever cost.
  @daily_budget_micro_usd 1_000_000
  @max_query_length 120

  # Ordered by how much upstream capacity the provider has, most first. The demo is the single
  # heaviest source of traffic we point at a provider, so it must lean on the ones with room.
  # arXiv is deliberately absent: at 20 requests a minute it is our tightest provider, and its
  # rate limit is a condition of the terms we verified. OpenAlex covers the same
  # search-the-literature use case with 600 a minute.
  # Ordered by how much upstream capacity the provider has, most first. The demo is the single
  # heaviest source of traffic we point at a provider, so it must lean on the ones with room.
  # arXiv is deliberately absent: at 20 requests a minute it is our tightest provider, and its
  # rate limit is a condition of the terms we verified. OpenAlex covers the same
  # search-the-literature use case with 600 a minute.
  #
  # The arguments below are checked against each tool's real inputSchema by demo_test.exs, so a
  # provider that changes its parameters fails the build rather than the demo.
  @examples [
    %{
      id: "npm",
      question: "What does the express package depend on?",
      tool: "npm_registry__npm_deps",
      editable: "name",
      args: %{"name" => "express"},
      note: "npm registry, 1000 requests/minute"
    },
    %{
      id: "openalex",
      question: "Find research about the Model Context Protocol",
      tool: "openalex__openalex_search_entities",
      editable: "query",
      args: %{"entity_type" => "works", "query" => "model context protocol", "per_page" => 3},
      note: "OpenAlex scholarly graph, 600 requests/minute"
    },
    %{
      id: "quake",
      question: "What earthquakes happened this week?",
      tool: "usgs_quake__earthquake_get_feed",
      editable: nil,
      args: %{"time_window" => "week", "magnitude_tier" => "significant", "limit" => 5},
      note: "USGS significant earthquakes, 600 requests/minute"
    },
    %{
      id: "pubchem",
      question: "Look up the chemistry of caffeine",
      tool: "pubchem__pubchem_search_compounds",
      editable: "identifiers",
      args: %{
        "searchType" => "identifier",
        "identifierType" => "name",
        "identifiers" => ["caffeine"],
        "maxResults" => 1
      },
      note: "PubChem compound search, 350 requests/minute"
    }
  ]

  @doc "The demo examples, filtered to those whose tool is actually routable right now."
  def examples do
    Enum.filter(@examples, fn ex -> match?({:ok, _, _}, Catalog.fetch_tool(ex.tool)) end)
  end

  def example(id), do: Enum.find(examples(), &(&1.id == id))

  def daily_budget_micro_usd, do: @daily_budget_micro_usd

  @doc """
  Runs one demo example. `query` overrides the example's editable field, when it has one.

  Returns `{:ok, %{result:, charged_micro_usd:, tool:, arguments:}}` or `{:error, reason}`.
  """
  def run(id, query \\ nil) do
    with {:ok, example} <- fetch_example(id),
         {:ok, args} <- build_args(example, query),
         {:ok, account} <- account(),
         :ok <- ensure_budget(account) do
      case Gateway.call_tool(account, example.tool, args) do
        {:ok, result, call_id} ->
          {:ok,
           %{
             result: result,
             call_id: call_id,
             charged_micro_usd: Settings.price_micro_usd(),
             tool: example.tool,
             arguments: args
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_example(id) do
    case example(id) do
      nil -> {:error, :unknown_example}
      example -> {:ok, example}
    end
  end

  # Only the field the example marks as editable can be set, and only as a short plain string.
  # Everything else is fixed, which is what stops the demo being driven as a general gateway.
  defp build_args(%{editable: nil} = example, _query), do: {:ok, example.args}

  defp build_args(example, query) when is_binary(query) do
    cleaned = query |> String.trim() |> String.slice(0, @max_query_length)

    if cleaned == "" do
      {:ok, example.args}
    else
      # Match the shape the tool's schema declares: a field that holds a list gets a
      # single-element list, not a bare string.
      value = if is_list(example.args[example.editable]), do: [cleaned], else: cleaned
      {:ok, Map.put(example.args, example.editable, value)}
    end
  end

  defp build_args(example, _query), do: {:ok, example.args}

  @doc """
  The gateway-owned account the demo spends from, created on first use.

  Its key is never handed out: the demo runs server-side, so a visitor never holds credentials
  for this account.
  """
  def account do
    case Billing.get_account_by_name(@demo_account_name) do
      %{} = account -> {:ok, account}
      nil -> Billing.create_account(@demo_account_name)
    end
  end

  # One top-up per UTC day, keyed by that date, so repeated calls cannot mint more than the
  # day's budget however often this runs.
  defp ensure_budget(account) do
    today = Date.utc_today() |> Date.to_iso8601()

    _ =
      Billing.top_up(account.id, @daily_budget_micro_usd, "demo-" <> today, %{
        "reason" => "demo_budget"
      })

    if Billing.balance(account.id) >= Settings.price_micro_usd() do
      :ok
    else
      {:error, :demo_budget_exhausted}
    end
  end

  @doc "A human-readable explanation for a demo failure."
  def explain(:unknown_example), do: "That example is not available."

  def explain(:demo_budget_exhausted),
    do:
      "The demo has used up today's budget. Try again tomorrow, or get your own free credit below."

  def explain(:unknown_tool), do: "That provider is not routable right now."
  def explain(:insufficient_funds), do: "The demo account is out of credit."
  def explain({:rate_limited, _}), do: "The demo is busy. Give it a moment."

  def explain({:upstream_busy, _}),
    do: "That provider is rate limited right now. Try another example."

  def explain(:timeout), do: "The provider took too long. This call was not charged."
  def explain(_other), do: "That call did not come back. It was not charged."
end
