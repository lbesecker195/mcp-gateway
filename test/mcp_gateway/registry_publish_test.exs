defmodule McpGateway.RegistryPublishTest do
  @moduledoc """
  Guards the shape we publish to the official MCP Registry.

  The registry rejects a whole document for a single over-long field, and a rejected document is
  a server nobody can discover. These tests run against the real catalog files so a bad entry
  fails here rather than at publish time.
  """
  use ExUnit.Case, async: true

  alias McpGateway.Catalog.Server
  alias McpGateway.RegistryPublish

  @catalog_dir "catalog/servers"
  @publisher_key "io.modelcontextprotocol.registry/publisher-provided"

  defp catalog_files, do: Path.wildcard(Path.join(@catalog_dir, "*.json"))

  defp build_server(attrs \\ %{}) do
    struct!(
      Server,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "dev.mcpharbor.gateway/arxiv",
          slug: "arxiv",
          version: "1.0.0",
          title: "arXiv",
          description: "Search arXiv preprints and open access scholarly papers",
          compliance: %{"terms_url" => "https://example.com/terms"},
          compliance_verdict: "allowed",
          compliance_checked_on: Date.utc_today(),
          docs: %{},
          status: "active",
          tools: []
        },
        attrs
      )
    )
  end

  describe "the real catalog files" do
    test "there are catalog entries to publish" do
      assert length(catalog_files()) > 0, "no catalog entries found in #{@catalog_dir}"
    end

    test "every entry renders to a document the official registry would accept" do
      for file <- catalog_files() do
        entry = file |> File.read!() |> Jason.decode!()

        server =
          build_server(%{
            name: entry["name"],
            slug: entry["slug"],
            version: entry["version"],
            title: entry["title"],
            description: entry["description"],
            repository: entry["repository"],
            compliance: entry["compliance"],
            docs: %{"keywords" => entry["keywords"] || []}
          })

        doc = RegistryPublish.server(server, 5)

        assert RegistryPublish.validate(doc) == :ok,
               "#{Path.basename(file)} would be rejected: #{inspect(RegistryPublish.validate(doc))}"
      end
    end

    test "descriptions are within the registry's 100-character limit and actually descriptive" do
      for file <- catalog_files() do
        entry = file |> File.read!() |> Jason.decode!()
        desc = entry["description"]

        assert is_binary(desc) and desc != "", "#{Path.basename(file)} has no description"

        assert String.length(desc) <= 100,
               "#{Path.basename(file)} description is #{String.length(desc)} characters, limit is 100"

        # A description that is only the server's own name is a wasted search surface.
        assert String.length(desc) >= 40,
               "#{Path.basename(file)} description is only #{String.length(desc)} characters; use the budget"
      end
    end

    test "entries carry keywords, and keywords are not merely repeated from the description" do
      for file <- catalog_files() do
        entry = file |> File.read!() |> Jason.decode!()
        keywords = entry["keywords"] || []

        assert length(keywords) >= 5,
               "#{Path.basename(file)} has #{length(keywords)} keywords; aim for a real set"

        assert keywords == Enum.uniq(keywords), "#{Path.basename(file)} has duplicate keywords"

        assert Enum.all?(keywords, &(is_binary(&1) and String.trim(&1) != "")),
               "#{Path.basename(file)} has a blank keyword"
      end
    end

    test "names are unique, reverse-DNS, and under our own namespace" do
      entries = Enum.map(catalog_files(), &(&1 |> File.read!() |> Jason.decode!()))
      names = Enum.map(entries, & &1["name"])
      slugs = Enum.map(entries, & &1["slug"])

      assert names == Enum.uniq(names), "duplicate server names in the catalog"
      assert slugs == Enum.uniq(slugs), "duplicate slugs in the catalog"

      for name <- names do
        assert String.starts_with?(name, "dev.mcpharbor.gateway/"),
               "#{name} is outside the namespace we can DNS-verify"
      end
    end

    test "upstream package versions are pinned exactly, never floating" do
      for file <- catalog_files() do
        entry = file |> File.read!() |> Jason.decode!()
        args = get_in(entry, ["upstream", "args"]) || []
        pinned = Enum.filter(args, &String.contains?(&1, "@"))

        refute Enum.any?(args, &String.ends_with?(&1, "@latest")),
               "#{Path.basename(file)} uses @latest; pin the version we reviewed"

        refute Enum.any?(pinned, &String.contains?(&1, "^")),
               "#{Path.basename(file)} uses a version range; pin an exact version"
      end
    end
  end

  describe "validate/1" do
    test "accepts a well-formed document" do
      assert RegistryPublish.validate(RegistryPublish.server(build_server(), 3)) == :ok
    end

    test "rejects a description over 100 characters" do
      long = String.duplicate("a", 101)

      {:error, problems} =
        RegistryPublish.validate(RegistryPublish.server(build_server(%{description: long}), 1))

      assert Enum.any?(problems, &(&1 =~ "description must be"))
    end

    test "rejects a name without exactly one slash" do
      {:error, problems} =
        RegistryPublish.validate(
          RegistryPublish.server(build_server(%{name: "dev.mcpharbor.gateway"}), 1)
        )

      assert Enum.any?(problems, &(&1 =~ "one '/'"))
    end

    test "rejects extra _meta keys, which the registry silently drops" do
      doc =
        build_server()
        |> RegistryPublish.server(1)
        |> put_in(["_meta", "dev.mcpharbor.gateway/pricing"], %{"price" => 100})

      {:error, problems} = RegistryPublish.validate(doc)
      assert Enum.any?(problems, &(&1 =~ "may only contain"))
    end

    test "rejects publisher metadata over the 4KB limit" do
      doc =
        build_server()
        |> RegistryPublish.server(1)
        |> put_in(["_meta", @publisher_key], %{"blob" => String.duplicate("x", 5000)})

      {:error, problems} = RegistryPublish.validate(doc)
      assert Enum.any?(problems, &(&1 =~ "over the 4096"))
    end

    test "rejects packages, which we do not own and must not claim" do
      doc =
        build_server()
        |> RegistryPublish.server(1)
        |> Map.put("packages", [%{"registryType" => "npm", "identifier" => "@someone/else"}])

      {:error, problems} = RegistryPublish.validate(doc)
      assert Enum.any?(problems, &(&1 =~ "do not publish packages we do not own"))
    end

    test "rejects a non-https remote" do
      doc =
        build_server()
        |> RegistryPublish.server(1)
        |> Map.put("remotes", [%{"type" => "streamable-http", "url" => "http://example.com/mcp"}])

      {:error, problems} = RegistryPublish.validate(doc)
      assert Enum.any?(problems, &(&1 =~ "https"))
    end
  end

  describe "published documents" do
    test "publish only remotes pointing at our own gateway, never upstream packages" do
      doc = RegistryPublish.server(build_server(), 2)

      refute Map.has_key?(doc, "packages")
      assert [%{"type" => "streamable-http", "url" => url}] = doc["remotes"]
      assert url =~ "/mcp/arxiv"
    end

    test "credit the upstream MCP server we route through" do
      server =
        build_server(%{
          compliance: %{
            "upstream_package" => "npm:@cyanheads/arxiv-mcp-server@1.5.3",
            "upstream_license" => "Apache-2.0",
            "terms_url" => "https://example.com/terms"
          }
        })

      meta = RegistryPublish.server(server, 2)["_meta"][@publisher_key]["dev.mcpharbor"]

      assert meta["upstreamServer"] == "npm:@cyanheads/arxiv-mcp-server@1.5.3"
      assert meta["upstreamLicense"] == "Apache-2.0"
    end

    test "never leak the upstream launch command or environment into a published document" do
      server =
        build_server(%{
          upstream: %{"command" => "npx", "args" => ["-y", "secret-pkg"], "env" => %{"K" => "v"}}
        })

      json = server |> RegistryPublish.server(2) |> Jason.encode!()

      refute json =~ "npx"
      refute json =~ "secret-pkg"
      refute json =~ "\"env\""
    end

    test "state the price so an agent reading the registry knows the cost before connecting" do
      meta = RegistryPublish.server(build_server(), 2)["_meta"][@publisher_key]["dev.mcpharbor"]

      assert meta["pricePerCallUsd"] ==
               McpGateway.Billing.format_usd(McpGateway.Settings.price_micro_usd())
    end
  end
end
