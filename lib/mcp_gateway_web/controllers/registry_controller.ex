defmodule McpGatewayWeb.RegistryController do
  @moduledoc """
  The read-only MCP Registry API under `/v0.1`, so other registries and off-the-shelf clients
  can consume our catalog with standard tooling.

  Four rules shape this module:

    * It never queries the database. Everything it can see comes from `McpGateway.Catalog`,
      whose every query is already filtered to compliance-allowed, non-stale, active servers.
    * It never builds a response body. `McpGateway.RegistryJSON` is the single source of truth
      for the `server.json` shape, so `/v0.1/servers` and `/server.json` can't drift apart.
    * A server that exists but isn't servable is reported exactly like one that was never
      published: same status, same body, byte for byte. Confirming that a delisted entry exists
      would leak our compliance review, so the two cases are deliberately indistinguishable.
    * Nothing here is billed. Discovery is free; only `tools/call` draws down credit.

  Publishing (`POST /v0.1/publish`, and the `PUT`/`DELETE`/`PATCH` endpoints the spec marks
  optional) is deliberately absent from the router: entries enter the catalog through the
  compliance gate, not over HTTP.

  Spec: https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/generic-registry-api.md
  """

  use McpGatewayWeb, :controller

  alias McpGateway.Catalog
  alias McpGateway.Catalog.Server
  alias McpGateway.RegistryJSON

  # One constant body for both "no such name" and "delisted by the compliance gate".
  @not_found %{"error" => "not_found", "message" => "No such server, or no such version of it."}

  @doc """
  `GET /v0.1/servers` — one page of the catalog.

  Query params: `limit` (default 30, capped at 100), `cursor` (the opaque `metadata.nextCursor`
  of a previous response), `search` (substring of name, title or description) and
  `updated_since` (an ISO 8601 timestamp).

  Unparseable `limit` values fall back to the default rather than erroring, because a bad page
  size can't produce a wrong answer, only a differently sized one. A `cursor` or
  `updated_since` we can't read *would* silently change which servers are returned, so both are
  rejected with a 400 instead.
  """
  def index(conn, params) do
    with {:ok, updated_since} <- updated_since_param(params["updated_since"]),
         # A `nil` option means "not given": `Catalog.list_servers/1` owns the default page
         # size and the cap, so the limits live in one place.
         {:ok, page} <-
           Catalog.list_servers(
             limit: integer_param(params["limit"]),
             cursor: string_param(params["cursor"]),
             search: string_param(params["search"]),
             updated_since: updated_since
           ) do
      json(conn, RegistryJSON.list(page.servers, page.next_cursor))
    else
      {:error, :invalid_cursor} ->
        bad_request(conn, "cursor", "expected the opaque `nextCursor` of a previous response")

      {:error, :invalid_updated_since} ->
        bad_request(
          conn,
          "updated_since",
          "expected an ISO 8601 timestamp, e.g. 2026-01-01T00:00:00Z"
        )
    end
  end

  @doc """
  `GET /v0.1/servers/:name/versions` — every version of one server, in the same envelope as
  `index`.

  Server names contain a slash (`dev.mcpharbor.gateway/arxiv`) and so arrive percent-encoded.
  Phoenix splits the path on literal `/` and only then percent-decodes each segment, so `name`
  reaches us whole.
  """
  def versions(conn, %{"name" => name}) do
    case versions_of(name) do
      [] -> not_found(conn)
      servers -> json(conn, RegistryJSON.list(servers, nil))
    end
  end

  @doc """
  `GET /v0.1/servers/:name/versions/:version` — one `server.json`, wrapped in a `server`
  envelope. The literal version `latest` is an alias for the current version.
  """
  def show(conn, %{"name" => name, "version" => version}) do
    with [_ | _] = servers <- versions_of(name),
         %Server{} = server <- pick_version(servers, version) do
      counts = Catalog.tool_counts([server])
      json(conn, RegistryJSON.envelope(server, tool_count: Map.get(counts, server.id, 0)))
    else
      _ -> not_found(conn)
    end
  end

  # The catalog holds exactly one active version per name, so this returns at most one row
  # today. It is a list, and ordered newest first, so that `versions` and `show` keep telling
  # the truth if we ever retain older versions.
  defp versions_of(name) when is_binary(name) do
    name
    |> Catalog.get_server_by_name()
    |> List.wrap()
    |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
  end

  defp versions_of(_name), do: []

  # `servers` is guaranteed non-empty by the caller, so `max_by/3` can't fall over.
  defp pick_version(servers, "latest"), do: Enum.max_by(servers, & &1.published_at, DateTime)
  defp pick_version(servers, version), do: Enum.find(servers, &(&1.version == version))

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(@not_found)

  defp bad_request(conn, param, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid_request", "message" => "Invalid `#{param}`: #{detail}."})
  end

  # Query params are strings, but a client can send `?search[]=x` and hand us a list. Anything
  # that isn't a string is treated as absent rather than passed down to a query.
  defp string_param(value) when is_binary(value), do: value
  defp string_param(_value), do: nil

  defp integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer_param(_value), do: nil

  defp updated_since_param(value) when value in [nil, ""], do: {:ok, nil}

  defp updated_since_param(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _utc_offset} -> {:ok, at}
      {:error, _reason} -> {:error, :invalid_updated_since}
    end
  end

  defp updated_since_param(_value), do: {:error, :invalid_updated_since}
end
