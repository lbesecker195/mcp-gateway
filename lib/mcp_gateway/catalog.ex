defmodule McpGateway.Catalog do
  @moduledoc """
  Read side of the catalog. Every query here goes through `servable_servers/1`, so an entry
  that isn't `allowed` (or whose verdict is stale) can't be listed, described, or routed to.
  """

  import Ecto.Query

  alias McpGateway.Catalog.{Compliance, Cursor, Server, Tool}
  alias McpGateway.Repo

  @default_limit 30
  @max_limit 100
  @tools_page_size 100

  @doc "Servers that may be listed and routed to right now."
  def servable_servers(today \\ Date.utc_today()) do
    cutoff = Compliance.cutoff(today)

    from s in Server,
      where:
        s.compliance_verdict == "allowed" and s.status == "active" and
          s.compliance_checked_on >= ^cutoff
  end

  @doc """
  Pages through servable servers ordered by name. Options: `:limit` (default 30, max 100),
  `:cursor`, `:search` (substring of name/title/description), `:updated_since` (`DateTime`).
  """
  def list_servers(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(@max_limit)

    with {:ok, after_name} <- Cursor.decode(opts[:cursor]) do
      rows =
        servable_servers()
        |> after_key(after_name)
        |> search(opts[:search])
        |> updated_since(opts[:updated_since])
        |> order_by([s], asc: s.name)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(rows, limit)
      next = if rest == [], do: nil, else: Cursor.encode(List.last(page).name)
      {:ok, %{servers: page, next_cursor: next}}
    end
  end

  def get_server_by_name(name) when is_binary(name) do
    servable_servers() |> where([s], s.name == ^name) |> Repo.one()
  end

  def get_server_by_slug(slug) when is_binary(slug) do
    servable_servers() |> where([s], s.slug == ^slug) |> Repo.one()
  end

  @doc "Tool counts keyed by server id, for the given servers."
  def tool_counts(servers) do
    ids = Enum.map(servers, & &1.id)

    Repo.all(
      from t in Tool,
        where: t.server_id in ^ids,
        group_by: t.server_id,
        select: {t.server_id, count(t.id)}
    )
    |> Map.new()
  end

  @doc "All servable servers with their tools preloaded, ordered by name. Used by the docs."
  def list_servers_with_tools do
    tools = from t in Tool, order_by: [asc: t.name]

    servable_servers()
    |> order_by([s], asc: s.name)
    |> preload(tools: ^tools)
    |> Repo.all()
  end

  @doc """
  Pages through tools of servable servers ordered by name. Options: `:scope` (a server slug to
  restrict to one server) and `:cursor`.
  """
  def list_tools(opts \\ []) do
    with {:ok, after_name} <- Cursor.decode(opts[:cursor]) do
      rows =
        from(t in Tool,
          join: s in ^servable_servers(),
          on: s.id == t.server_id,
          order_by: [asc: t.name],
          limit: ^(@tools_page_size + 1),
          select: t
        )
        |> scope(opts[:scope])
        |> tools_after(after_name)
        |> Repo.all()

      {page, rest} = Enum.split(rows, @tools_page_size)
      next = if rest == [], do: nil, else: Cursor.encode(List.last(page).name)
      {:ok, %{tools: page, next_cursor: next}}
    end
  end

  @doc "Looks up a servable tool by its gateway name. `:scope` restricts to one server slug."
  def fetch_tool(name, opts \\ []) when is_binary(name) do
    query =
      from t in Tool,
        join: s in ^servable_servers(),
        on: s.id == t.server_id,
        where: t.name == ^name,
        select: {t, s}

    case query |> scope(opts[:scope]) |> Repo.one() do
      {tool, server} -> {:ok, tool, server}
      nil -> {:error, :unknown_tool}
    end
  end

  defp scope(query, nil), do: query
  defp scope(query, slug), do: where(query, [t, s], s.slug == ^slug)

  defp tools_after(query, nil), do: query
  defp tools_after(query, name), do: where(query, [t], t.name > ^name)

  defp after_key(query, nil), do: query
  defp after_key(query, name), do: where(query, [s], s.name > ^name)

  defp search(query, term) when term in [nil, ""], do: query

  defp search(query, term) do
    pattern = "%" <> String.replace(term, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

    # Keywords are matched against the JSON array's text form, so a search for a term that
    # doesn't appear in the name, title or description can still find the server.
    where(
      query,
      [s],
      ilike(s.name, ^pattern) or ilike(s.title, ^pattern) or ilike(s.description, ^pattern) or
        fragment("? ->> 'keywords' ILIKE ?", s.docs, ^pattern)
    )
  end

  @doc """
  A server's upstream allowance in requests per minute, or `nil` when none is published.

  Used to order what we put in front of people: a provider with little headroom should not be
  the first thing a visitor clicks, because its rate limit is part of the terms that let us
  proxy it at all.
  """
  def requests_per_minute(%Server{rate_limit: %{"requests" => n, "window_ms" => w}})
      when is_integer(n) and is_integer(w) and w > 0,
      do: n * 60_000 / w

  def requests_per_minute(%Server{}), do: nil

  @doc """
  Servable servers ordered by upstream capacity, most first, then by name.

  This is a presentation order only. The registry API keeps its own name ordering, because its
  cursor pagination depends on it.
  """
  def list_servers_by_capacity do
    list_servers_with_tools()
    |> Enum.sort_by(fn s -> {-(requests_per_minute(s) || 0), s.name} end)
  end

  @doc "A server's published search keywords."
  def keywords(%Server{docs: %{"keywords" => keywords}}) when is_list(keywords), do: keywords
  def keywords(%Server{}), do: []

  defp updated_since(query, nil), do: query
  defp updated_since(query, %DateTime{} = since), do: where(query, [s], s.updated_at > ^since)

  defp clamp(n, max) when is_integer(n) and n > 0, do: min(n, max)
  defp clamp(_, _max), do: @default_limit
end
