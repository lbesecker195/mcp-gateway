defmodule McpGatewayWeb.RegistryControllerTest do
  use McpGatewayWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias McpGateway.Catalog.Server
  alias McpGateway.Fixtures
  alias McpGateway.Repo
  alias McpGateway.Settings

  @unknown_name "dev.mcpharbor.gateway/no_such_server_anywhere"

  describe "GET /v0.1/servers" do
    test "renders the registry list envelope", %{conn: conn} do
      server = Fixtures.insert_server()

      body = conn |> get("/v0.1/servers") |> json_response(200)

      assert %{"servers" => [%{"server" => entry}], "metadata" => metadata} = body
      assert entry["name"] == server.name
      assert entry["version"] == server.version
      assert entry["description"] == server.description
      assert metadata["count"] == 1
      # No further page, so no cursor at all -- not a null one.
      refute Map.has_key?(metadata, "nextCursor")
    end

    test "responds as JSON", %{conn: conn} do
      conn = get(conn, "/v0.1/servers")

      assert conn |> get_resp_header("content-type") |> List.first() =~ "application/json"
    end

    test "an empty catalog is an empty list, not an error", %{conn: conn} do
      body = conn |> get("/v0.1/servers") |> json_response(200)

      assert body == %{"servers" => [], "metadata" => %{"count" => 0}}
    end

    test "paging with the returned cursor walks the whole catalog exactly once", %{conn: conn} do
      prefix = "pg#{System.unique_integer([:positive])}"
      expected = for i <- 1..5, do: Fixtures.insert_server(%{slug: "#{prefix}_#{i}"}).name

      # The first page comes from the test's own conn so the sandbox owner is unambiguous.
      assert %{"servers" => first, "metadata" => %{"nextCursor" => cursor}} =
               conn |> get("/v0.1/servers?limit=2") |> json_response(200)

      {names, page_count} = walk(cursor, names_of(first), 1)

      assert page_count == 3, "expected 5 servers at limit=2 to take 3 pages"
      assert length(names) == 5
      assert names == Enum.uniq(names), "a server was returned on two different pages"
      assert Enum.sort(names) == Enum.sort(expected)
    end

    test "limit caps the page and an unusable limit falls back to the default", %{conn: conn} do
      prefix = "lm#{System.unique_integer([:positive])}"
      for i <- 1..3, do: Fixtures.insert_server(%{slug: "#{prefix}_#{i}"})

      assert %{"metadata" => %{"count" => 1}} =
               conn |> get("/v0.1/servers?limit=1") |> json_response(200)

      for bad <- ~w(banana 0 -4 3.5) do
        assert %{"metadata" => %{"count" => 3}} =
                 build_conn() |> get("/v0.1/servers?limit=#{bad}") |> json_response(200),
               "limit=#{bad} should fall back to the default page size"
      end
    end

    test "a cursor we did not issue is a 400, not a crash", %{conn: conn} do
      Fixtures.insert_server()

      conn = get(conn, "/v0.1/servers?cursor=%21%21%21not-a-cursor")

      assert %{"error" => "invalid_request", "message" => message} = json_response(conn, 400)
      assert message =~ "cursor"
    end

    test "search filters the list", %{conn: conn} do
      n = System.unique_integer([:positive])
      wanted = Fixtures.insert_server(%{slug: "sq#{n}", description: "Quasar catalogue lookups"})
      Fixtures.insert_server(%{slug: "so#{n}"})

      body = conn |> get("/v0.1/servers?search=quasar") |> json_response(200)

      assert names_of(body["servers"]) == [wanted.name]
      assert body["metadata"]["count"] == 1
    end

    test "a wildcard in search matches literally", %{conn: conn} do
      Fixtures.insert_server()

      body = conn |> get(servers_path(%{"search" => "%"})) |> json_response(200)

      assert body["servers"] == []
    end

    test "updated_since drops entries that have not changed since then", %{conn: conn} do
      n = System.unique_integer([:positive])
      fresh = Fixtures.insert_server(%{slug: "uf#{n}"})
      backdate(Fixtures.insert_server(%{slug: "uo#{n}"}), -3600)

      since = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_iso8601()
      body = conn |> get(servers_path(%{"updated_since" => since})) |> json_response(200)

      assert names_of(body["servers"]) == [fresh.name]
    end

    test "a malformed updated_since is a 400", %{conn: conn} do
      Fixtures.insert_server()

      for bad <- ["yesterday", "2026-13-01T00:00:00Z", "2026-01-01"] do
        conn = build_conn() |> get(servers_path(%{"updated_since" => bad}))

        assert %{"error" => "invalid_request", "message" => message} = json_response(conn, 400)
        assert message =~ "updated_since"
      end

      # An explicitly empty value means "no filter", not a bad request.
      assert %{"metadata" => %{"count" => 1}} =
               conn |> get(servers_path(%{"updated_since" => ""})) |> json_response(200)
    end
  end

  describe "GET /v0.1/servers/:name/versions" do
    test "finds a server by its percent-encoded name", %{conn: conn} do
      server = Fixtures.insert_server()
      # The name contains a slash, so a real client sends it as %2F.
      path = "/v0.1/servers/dev.mcpharbor.gateway%2F#{server.slug}/versions"

      body = conn |> get(path) |> json_response(200)

      assert %{"servers" => [%{"server" => entry}], "metadata" => %{"count" => 1}} = body
      assert entry["name"] == server.name
      assert entry["version"] == server.version
    end

    test "404s for an unknown name", %{conn: conn} do
      conn = get(conn, server_path(@unknown_name) <> "/versions")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "GET /v0.1/servers/:name/versions/:version" do
    test "returns one server.json with its gateway remote and price", %{conn: conn} do
      server = Fixtures.insert_fake_server()

      body =
        conn
        |> get(server_path(server.name) <> "/versions/#{server.version}")
        |> json_response(200)

      assert %{"server" => entry} = body
      refute Map.has_key?(body, "servers")
      assert entry["name"] == server.name
      assert entry["$schema"] == McpGateway.RegistryJSON.schema_url()

      assert [%{"type" => "streamable-http", "url" => url}] = entry["remotes"]
      assert String.ends_with?(url, "/mcp/#{server.slug}")

      pricing = entry["_meta"][Settings.meta_key("pricing")]
      assert pricing["pricePerCallMicroUsd"] == Settings.price_micro_usd()
      assert pricing["pricePerCallUsd"] == "0.0001"

      catalog = entry["_meta"][Settings.meta_key("catalog")]
      assert catalog["slug"] == server.slug
      # insert_fake_server/1 registers echo, fail, sleep, crash and env.
      assert catalog["toolCount"] == 5
    end

    test "never discloses how the upstream is reached", %{conn: conn} do
      server = Fixtures.insert_fake_server()

      encoded =
        conn
        |> get(server_path(server.name) <> "/versions/latest")
        |> response(200)

      refute encoded =~ "fake_upstream"
      refute encoded =~ "stdio"
      refute encoded =~ "command"
    end

    test "`latest` is an alias for the current version", %{conn: conn} do
      server = Fixtures.insert_server()

      pinned =
        conn
        |> get(server_path(server.name) <> "/versions/#{server.version}")
        |> json_response(200)

      latest =
        build_conn()
        |> get(server_path(server.name) <> "/versions/latest")
        |> json_response(200)

      assert latest == pinned
      assert latest["server"]["version"] == server.version
    end

    test "404s for a version that does not exist", %{conn: conn} do
      server = Fixtures.insert_server()

      conn = get(conn, server_path(server.name) <> "/versions/9.9.9")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "the compliance gate" do
    test "a not_allowed server is invisible everywhere", %{conn: conn} do
      hidden =
        Fixtures.insert_server(%{
          slug: "na#{System.unique_integer([:positive])}",
          compliance_verdict: "not_allowed"
        })

      assert_absent_from_list(conn, hidden)
      assert_indistinguishable_from_unknown(hidden)
    end

    test "a server whose compliance check has gone stale is invisible everywhere", %{conn: conn} do
      hidden =
        Fixtures.insert_server(%{
          slug: "st#{System.unique_integer([:positive])}",
          compliance_checked_on: ~D[2000-01-01]
        })

      assert_absent_from_list(conn, hidden)
      assert_indistinguishable_from_unknown(hidden)
    end

    test "a deprecated server is invisible everywhere", %{conn: conn} do
      hidden =
        Fixtures.insert_server(%{
          slug: "dp#{System.unique_integer([:positive])}",
          status: "deprecated"
        })

      assert_absent_from_list(conn, hidden)
      assert_indistinguishable_from_unknown(hidden)
    end
  end

  describe "write endpoints" do
    test "publishing and mutation are not routed", %{conn: conn} do
      server = Fixtures.insert_server()
      version_path = server_path(server.name) <> "/versions/#{server.version}"

      # No route at all, so these never reach a controller: the endpoint answers 404.
      assert post(build_conn(), "/v0.1/publish", %{}).status == 404
      assert put(build_conn(), version_path, %{}).status == 404
      assert delete(build_conn(), version_path).status == 404
      assert patch(build_conn(), version_path <> "/status", %{}).status == 404

      # ...and the entry is still there, untouched.
      assert %{"metadata" => %{"count" => 1}} =
               conn |> get("/v0.1/servers") |> json_response(200)
    end
  end

  defp assert_absent_from_list(conn, server) do
    body = conn |> get("/v0.1/servers") |> json_response(200)

    refute server.name in names_of(body["servers"])
  end

  # The gate must not be observable: a delisted entry has to answer exactly as a name we have
  # never heard of, on every endpoint that takes a name.
  defp assert_indistinguishable_from_unknown(server) do
    for suffix <- ["/versions", "/versions/#{server.version}", "/versions/latest"] do
      hidden = build_conn() |> get(server_path(server.name) <> suffix)
      unknown = build_conn() |> get(server_path(@unknown_name) <> suffix)

      assert hidden.status == 404
      assert json_response(hidden, 404) == json_response(unknown, 404)
    end
  end

  # Follows nextCursor until the pages run out. Returns the names seen and the page count.
  defp walk(nil, names, pages), do: {names, pages}

  defp walk(_cursor, _names, pages) when pages > 10 do
    flunk("still paging after #{pages} pages -- the cursor is not advancing")
  end

  defp walk(cursor, names, pages) do
    body =
      build_conn()
      |> get(servers_path(%{"limit" => "2", "cursor" => cursor}))
      |> json_response(200)

    assert length(body["servers"]) <= 2, "a page exceeded the requested limit"

    walk(body["metadata"]["nextCursor"], names ++ names_of(body["servers"]), pages + 1)
  end

  defp names_of(entries), do: Enum.map(entries, & &1["server"]["name"])

  defp servers_path(query), do: "/v0.1/servers?" <> URI.encode_query(query)

  defp server_path(name), do: "/v0.1/servers/" <> URI.encode(name, &URI.char_unreserved?/1)

  defp backdate(%Server{} = server, seconds) do
    at = DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

    {1, _} = Repo.update_all(from(s in Server, where: s.id == ^server.id), set: [updated_at: at])

    :ok
  end
end
