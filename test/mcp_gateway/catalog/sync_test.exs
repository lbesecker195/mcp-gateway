defmodule McpGateway.Catalog.SyncTest do
  @moduledoc """
  The compliance gate is the business's legal footing, so these tests drive the real thing:
  temporary catalog files on disk, and the fixture MCP server as the upstream being probed.
  """
  use McpGateway.DataCase, async: true

  alias McpGateway.Catalog
  alias McpGateway.Catalog.{Server, Sync, Tool}
  alias McpGateway.{Fixtures, Settings}

  @fixture_tools ~w(crash echo env fail sleep)

  # A stdio MCP server written for one test: it speaks the modern era and answers `tools/list`
  # with whatever payload it was handed on the command line, so a test can decide exactly what
  # metadata an upstream sends us.
  @scripted_upstream ~S"""
  tools = JSON.decode!(Enum.at(System.argv(), 0))

  emit = fn map -> IO.puts(JSON.encode!(map)) end

  IO.stream(:stdio, :line)
  |> Enum.each(fn line ->
    case JSON.decode(String.trim(line)) do
      {:ok, %{"id" => id, "method" => "server/discover"}} ->
        emit.(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "resultType" => "complete",
            "supportedVersions" => ["2026-07-28"],
            "capabilities" => %{"tools" => %{}}
          }
        })

      {:ok, %{"id" => id, "method" => "tools/list"}} ->
        emit.(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"resultType" => "complete", "tools" => tools}
        })

      _ ->
        :ok
    end
  end)
  """

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mcp_gateway_catalog_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "the compliance gate" do
    test "an allowed entry imports, and its tools are discovered and namespaced", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.imported == [slug]
      assert report.counts == %{imported: 1, updated: 0, delisted: 0, skipped: 0, failed: 0}

      server = Catalog.get_server_by_slug(slug)
      assert server.status == "active"
      assert server.compliance_verdict == "allowed"
      assert server.compliance["terms_url"] == "https://example.com/terms"
      assert server.upstream["command"] == "elixir"

      assert tool_names(slug) == Enum.map(@fixture_tools, &"#{slug}__#{&1}")

      assert {:ok, tool, found} = Catalog.fetch_tool("#{slug}__echo")
      assert tool.upstream_name == "echo"
      assert tool.description == "Echo the given text back."
      assert tool.input_schema["required"] == ["text"]
      assert found.id == server.id
    end

    test "a not_allowed entry is skipped and never creates a row", %{dir: dir} do
      slug = Fixtures.unique_slug()
      write_entry(dir, slug, %{"compliance" => %{"verdict" => "not_allowed"}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.skipped == [{slug, {:verdict, "not_allowed"}}]
      assert report.imported == []
      assert report.delisted == []
      assert Repo.get_by(Server, slug: slug) == nil
    end

    test "an unknown verdict is skipped and never creates a row", %{dir: dir} do
      slug = Fixtures.unique_slug()
      write_entry(dir, slug, %{"compliance" => %{"verdict" => "unknown"}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.skipped == [{slug, {:verdict, "unknown"}}]
      assert Repo.get_by(Server, slug: slug) == nil
    end

    test "a verdict that flips to not_allowed delists the row and stops routing", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)

      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{slug}__echo")

      write_entry(dir, slug, %{"compliance" => %{"verdict" => "not_allowed"}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.delisted == [{slug, {:verdict, "not_allowed"}}]
      assert report.skipped == [{slug, {:verdict, "not_allowed"}}]
      assert report.counts.updated == 0

      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
      assert Catalog.get_server_by_slug(slug) == nil
      assert Repo.get_by(Server, slug: slug).status == "deprecated"
    end

    test "a stale checked_on is skipped even when the verdict says allowed", %{dir: dir} do
      slug = Fixtures.unique_slug()
      stale = Date.add(Date.utc_today(), -(Settings.get(:compliance_max_age_days) + 1))
      write_entry(dir, slug, %{"compliance" => %{"checked_on" => Date.to_iso8601(stale)}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.skipped == [{slug, {:stale, stale}}]
      assert report.imported == []
      assert Repo.get_by(Server, slug: slug) == nil
    end

    test "a verdict that goes stale delists an entry that is already listed", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)

      stale = Date.add(Date.utc_today(), -(Settings.get(:compliance_max_age_days) + 1))
      write_entry(dir, slug, %{"compliance" => %{"checked_on" => Date.to_iso8601(stale)}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.delisted == [{slug, {:stale, stale}}]
      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
      assert Repo.get_by(Server, slug: slug).status == "deprecated"
    end

    test "a verdict that goes back to allowed relists the server", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug, %{"compliance" => %{"verdict" => "not_allowed"}})
      assert {:ok, %{skipped: [_]}} = Sync.sync_all(dir: dir)

      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)
      assert Catalog.get_server_by_slug(slug).status == "active"
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{slug}__echo")
    end
  end

  describe "exclude_tools" do
    test "removes exactly the listed tools and keeps the rest", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug, %{"exclude_tools" => ["crash", "sleep"]})

      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)

      assert tool_names(slug) == Enum.map(~w(echo env fail), &"#{slug}__#{&1}")
      assert Catalog.fetch_tool("#{slug}__crash") == {:error, :unknown_tool}
      assert Catalog.fetch_tool("#{slug}__sleep") == {:error, :unknown_tool}
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{slug}__echo")
    end

    test "an exclusion added later removes the tool on the next sync", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)
      assert length(tool_names(slug)) == 5

      write_entry(dir, slug, %{"exclude_tools" => ["echo"]})
      assert {:ok, %{updated: [^slug]}} = Sync.sync_all(dir: dir)

      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
      assert tool_names(slug) == Enum.map(~w(crash env fail sleep), &"#{slug}__#{&1}")
    end

    # An exclusion is a compliance decision, not a description of the upstream. If terms change
    # while the provider happens to be down, the forbidden tool still has to stop being listed,
    # routable and billable — waiting for the upstream to answer would keep charging for it.
    test "an exclusion is applied even when the upstream probe fails", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{slug}__echo")

      write_entry(dir, slug, %{
        "exclude_tools" => ["echo"],
        "upstream" => unreachable_upstream()
      })

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.counts.failed == 1
      assert report.updated == []

      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}

      # Everything else survives the flaky upstream: a failed probe must not empty the catalog.
      assert tool_names(slug) == Enum.map(~w(crash env fail sleep), &"#{slug}__#{&1}")
      assert Catalog.get_server_by_slug(slug).upstream["command"] == "elixir"
    end
  end

  describe "invalid files" do
    test "a missing field, a bad date or an unknown verdict fails and writes nothing", %{dir: dir} do
      no_version = Fixtures.unique_slug()
      bad_date = Fixtures.unique_slug()
      bad_verdict = Fixtures.unique_slug()
      no_terms = Fixtures.unique_slug()

      write_raw(dir, no_version, Map.delete(entry(no_version), "version"))
      write_entry(dir, bad_date, %{"compliance" => %{"checked_on" => "2026-13-99"}})
      write_entry(dir, bad_verdict, %{"compliance" => %{"verdict" => "probably_fine"}})
      write_raw(dir, no_terms, pop_compliance_key(entry(no_terms), "terms_url"))

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.counts.failed == 4
      assert report.imported == []
      assert report.skipped == []
      # Nothing was listed, so there was nothing to delist.
      assert report.delisted == []

      failures = Map.new(report.failed, fn {path, reason} -> {Path.basename(path), reason} end)
      assert failures["#{no_version}.json"] == {:missing_field, "version"}
      assert failures["#{bad_date}.json"] == {:invalid_date, "2026-13-99"}
      assert failures["#{bad_verdict}.json"] == {:unknown_verdict, "probably_fine"}
      assert failures["#{no_terms}.json"] == {:missing_field, "compliance.terms_url"}

      for slug <- [no_version, bad_date, bad_verdict, no_terms] do
        assert Repo.get_by(Server, slug: slug) == nil
      end
    end

    test "a file that isn't JSON fails without touching the rest of the catalog", %{dir: dir} do
      good = probing_slug()
      write_entry(dir, good)
      File.write!(Path.join(dir, "broken.json"), "{not json")

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.imported == [good]
      assert [{path, {:invalid_json, _message}}] = report.failed
      assert Path.basename(path) == "broken.json"
    end

    test "an unknown upstream type fails instead of importing an unroutable server", %{dir: dir} do
      slug = Fixtures.unique_slug()
      write_entry(dir, slug, %{"upstream" => %{"type" => "carrier-pigeon", "command" => "coo"}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert [{_path, {:unknown_upstream_type, "carrier-pigeon"}}] = report.failed
      assert Repo.get_by(Server, slug: slug) == nil
    end
  end

  # An operator edits an entry to pull a server and fat-fingers the edit. Default deny: an entry
  # we cannot verify is not a verified entry, so it stops being routable in the same run rather
  # than staying active and billable until someone reads the failure line.
  describe "an invalid file for a server that is already listed" do
    test "a typo in the verdict delists it", %{dir: dir} do
      slug = listed_slug(dir)

      write_entry(dir, slug, %{"compliance" => %{"verdict" => "not-allowed"}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert [{_path, {:unknown_verdict, "not-allowed"}}] = report.failed
      assert report.delisted == [{slug, {:unknown_verdict, "not-allowed"}}]
      assert report.updated == []

      assert Catalog.get_server_by_slug(slug) == nil
      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
      assert Repo.get_by(Server, slug: slug).status == "deprecated"
    end

    test "a deleted compliance field delists it", %{dir: dir} do
      slug = listed_slug(dir)

      write_raw(dir, slug, pop_compliance_key(entry(slug), "checked_on"))

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert [{_path, {:missing_field, "compliance.checked_on"}}] = report.failed
      assert report.delisted == [{slug, {:missing_field, "compliance.checked_on"}}]

      assert Catalog.get_server_by_slug(slug) == nil
      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
    end

    # Nothing parsed, so the filename is what says which server we can no longer vouch for.
    test "a file truncated mid-write delists the server it is named after", %{dir: dir} do
      slug = listed_slug(dir)

      path = Path.join(dir, "#{slug}.json")
      File.write!(path, path |> File.read!() |> binary_part(0, 40))

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert [{_path, {:invalid_json, _message}}] = report.failed
      assert [{^slug, {:invalid_json, _message}}] = report.delisted

      assert Catalog.get_server_by_slug(slug) == nil
      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
    end

    test "only the server the broken file names is delisted", %{dir: dir} do
      broken = listed_slug(dir)
      untouched = listed_slug(dir)

      File.write!(Path.join(dir, "#{broken}.json"), "{not json")

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert [{^broken, _reason}] = report.delisted
      assert report.updated == [untouched]

      assert Catalog.get_server_by_slug(broken) == nil
      assert Catalog.get_server_by_slug(untouched).status == "active"
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{untouched}__echo")
    end
  end

  describe "probing" do
    test "a probe failure leaves an existing server's tools intact", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)
      assert length(tool_names(slug)) == 5

      # `sh` isn't an allow-listed launcher, so the probe fails before the upstream is reached.
      write_entry(dir, slug, %{"upstream" => unreachable_upstream()})

      assert {:ok, report} = Sync.sync_all(dir: dir)

      assert [{_path, {:probe_failed, {:start_failed, {:command_not_allowed, "sh"}}}}] =
               report.failed

      assert report.updated == []

      # The previous row and its tools survive a flaky (or misconfigured) upstream.
      assert tool_names(slug) == Enum.map(@fixture_tools, &"#{slug}__#{&1}")
      assert Catalog.get_server_by_slug(slug).upstream["command"] == "elixir"
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{slug}__echo")
    end

    test "a probe failure on a new entry creates no row at all", %{dir: dir} do
      slug = Fixtures.unique_slug()

      write_entry(dir, slug, %{"upstream" => unreachable_upstream()})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.counts.failed == 1
      assert Repo.get_by(Server, slug: slug) == nil
    end

    test "offline skips the probe and keeps the tools already discovered", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)

      # An upstream that could never be launched proves no probe happened.
      write_entry(dir, slug, %{
        "title" => "Renamed offline",
        "upstream" => %{"type" => "stdio", "command" => "sh", "args" => [], "env" => %{}}
      })

      assert {:ok, report} = Sync.sync_all(dir: dir, offline: true)
      assert report.updated == [slug]
      assert report.failed == []
      assert Catalog.get_server_by_slug(slug).title == "Renamed offline"
      assert tool_names(slug) == Enum.map(@fixture_tools, &"#{slug}__#{&1}")
    end

    test "offline still honors a newly added exclusion", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)

      write_entry(dir, slug, %{"exclude_tools" => ["echo", "crash"]})
      assert {:ok, %{updated: [^slug]}} = Sync.sync_all(dir: dir, offline: true)

      assert tool_names(slug) == Enum.map(~w(env fail sleep), &"#{slug}__#{&1}")
    end
  end

  # `tools/list` is whatever a third party sends. None of it may reach `insert_all` unchecked:
  # a description that is an object, a title longer than the column or a null byte in a schema
  # each raise from the driver, and before this was checked one such upstream aborted the whole
  # run with it.
  describe "upstream tool metadata" do
    test "a tool we cannot store is dropped and the rest of the server still imports", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug, %{"upstream" => scripted_upstream(dir, slug, unstorable_tools())})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.imported == [slug]
      assert report.failed == []

      assert tool_names(slug) == ["#{slug}__good"]

      assert {:ok, tool, _server} = Catalog.fetch_tool("#{slug}__good")
      assert tool.description == "A tool we can store."
    end

    test "it does not stop a later entry's verdict flip from delisting", %{dir: dir} do
      # `sync_all/1` walks the directory in sorted order, so the bad entry is evaluated first.
      bad = "a" <> Fixtures.unique_slug()
      flipped = "z" <> Fixtures.unique_slug()
      on_exit(fn -> Enum.each([bad, flipped], &Fixtures.stop_upstream/1) end)

      write_entry(dir, flipped)
      assert {:ok, %{imported: [^flipped]}} = Sync.sync_all(dir: dir)
      assert {:ok, _tool, _server} = Catalog.fetch_tool("#{flipped}__echo")

      write_entry(dir, bad, %{"upstream" => scripted_upstream(dir, bad, unstorable_tools())})
      write_entry(dir, flipped, %{"compliance" => %{"verdict" => "not_allowed"}})

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.imported == [bad]
      assert report.delisted == [{flipped, {:verdict, "not_allowed"}}]

      assert Catalog.fetch_tool("#{flipped}__echo") == {:error, :unknown_tool}
      assert Repo.get_by(Server, slug: flipped).status == "deprecated"
    end
  end

  describe "repeat runs" do
    test "re-syncing an unchanged entry is idempotent", %{dir: dir} do
      slug = probing_slug()
      write_entry(dir, slug)

      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)
      server = Catalog.get_server_by_slug(slug)

      assert {:ok, report} = Sync.sync_all(dir: dir)
      assert report.updated == [slug]
      assert report.imported == []

      assert Repo.aggregate(from(s in Server, where: s.slug == ^slug), :count) == 1
      assert Repo.aggregate(from(t in Tool, where: t.server_id == ^server.id), :count) == 5
      assert tool_names(slug) == Enum.map(@fixture_tools, &"#{slug}__#{&1}")

      # The row keeps its original publication date across re-syncs.
      assert Catalog.get_server_by_slug(slug).published_at == server.published_at
    end

    test "--slug syncs only that entry", %{dir: dir} do
      wanted = probing_slug()
      other = Fixtures.unique_slug()
      write_entry(dir, wanted)
      write_entry(dir, other, %{"compliance" => %{"verdict" => "not_allowed"}})

      assert {:ok, report} = Sync.sync_all(dir: dir, slug: wanted)
      assert report.imported == [wanted]
      assert report.skipped == []
      assert Repo.get_by(Server, slug: other) == nil
    end

    test "prune delists a server whose catalog file is gone", %{dir: dir} do
      slug = probing_slug()
      path = write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)

      File.rm!(path)

      assert {:ok, report} = Sync.sync_all(dir: dir, prune: true)
      assert report.delisted == [{slug, :not_in_catalog}]
      assert Catalog.get_server_by_slug(slug) == nil
      assert Repo.get_by(Server, slug: slug).status == "deprecated"
    end

    test "prune is skipped when a file failed to parse", %{dir: dir} do
      slug = probing_slug()
      path = write_entry(dir, slug)
      assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir)

      File.rm!(path)
      File.write!(Path.join(dir, "broken.json"), "{not json")

      assert {:ok, report} = Sync.sync_all(dir: dir, prune: true)
      assert report.delisted == []
      assert report.counts.failed == 1
      assert Catalog.get_server_by_slug(slug).status == "active"
    end
  end

  describe "sync_file/2" do
    test "returns the server, the skip reason, or the failure", %{dir: dir} do
      slug = probing_slug()
      path = write_entry(dir, slug)

      assert {:ok, server} = Sync.sync_file(path)
      assert server.slug == slug

      write_entry(dir, slug, %{"compliance" => %{"verdict" => "not_allowed"}})
      assert Sync.sync_file(path) == {:skip, {:verdict, "not_allowed"}}
      assert Repo.get_by(Server, slug: slug).status == "deprecated"

      write_raw(dir, slug, Map.delete(entry(slug), "upstream"))
      assert Sync.sync_file(path) == {:error, {:missing_field, "upstream"}}
    end

    test "an invalid file delists a server that was listed", %{dir: dir} do
      slug = probing_slug()
      path = write_entry(dir, slug)
      assert {:ok, _server} = Sync.sync_file(path)

      write_raw(dir, slug, Map.delete(entry(slug), "upstream"))

      assert Sync.sync_file(path) == {:error, {:missing_field, "upstream"}}
      assert Catalog.get_server_by_slug(slug) == nil
      assert Catalog.fetch_tool("#{slug}__echo") == {:error, :unknown_tool}
    end
  end

  test "a missing catalog directory is an error, not an empty run" do
    missing = Path.join(System.tmp_dir!(), "mcp_gateway_no_such_catalog_dir")
    assert {:error, {:catalog_dir_not_found, dir}} = Sync.sync_all(dir: missing)
    assert dir == Path.expand(missing)
  end

  ## Helpers

  # Every probing slug gets its upstream subprocess stopped when the test ends.
  defp probing_slug do
    slug = Fixtures.unique_slug()
    on_exit(fn -> Fixtures.stop_upstream(slug) end)
    slug
  end

  # A slug that is already imported, listed and routable when the test starts.
  defp listed_slug(dir) do
    slug = probing_slug()
    write_entry(dir, slug)
    assert {:ok, %{imported: [^slug]}} = Sync.sync_all(dir: dir, slug: slug)
    assert {:ok, _tool, _server} = Catalog.fetch_tool("#{slug}__echo")
    slug
  end

  # `sh` isn't an allow-listed launcher, so a probe fails before any upstream is reached.
  defp unreachable_upstream do
    %{"type" => "stdio", "command" => "sh", "args" => ["-c", "true"], "env" => %{}}
  end

  # An upstream that returns exactly `tools` from `tools/list`.
  defp scripted_upstream(dir, name, tools) do
    path = Path.join(dir, "#{name}_upstream.exs")
    File.write!(path, @scripted_upstream)

    %{
      "type" => "stdio",
      "command" => "elixir",
      "args" => [path, Jason.encode!(tools)],
      "env" => %{}
    }
  end

  # One storable tool, and one of every shape the database would refuse.
  defp unstorable_tools do
    [
      %{
        "name" => "good",
        "description" => "A tool we can store.",
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "object_description",
        "description" => %{"text" => "a structured description"},
        "inputSchema" => %{"type" => "object"}
      },
      %{"name" => "string_schema", "description" => "ok", "inputSchema" => "not an object"},
      %{"name" => "number_title", "title" => 42, "inputSchema" => %{"type" => "object"}},
      %{
        "name" => "list_annotations",
        "annotations" => ["readOnlyHint"],
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "long_title",
        "title" => String.duplicate("x", 300),
        "inputSchema" => %{"type" => "object"}
      },
      %{
        "name" => "null_byte_in_schema",
        "inputSchema" => %{"type" => "object", "title" => "bad" <> <<0>> <> "title"}
      }
    ]
  end

  defp tool_names(slug) do
    {:ok, %{tools: tools}} = Catalog.list_tools(scope: slug)
    tools |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp entry(slug) do
    %{
      "slug" => slug,
      "name" => "dev.mcpharbor.gateway/#{slug}",
      "version" => "1.0.0",
      "title" => "Fake #{slug}",
      "description" => "A fake server for catalog sync tests",
      "website_url" => "https://example.com",
      "repository" => %{"url" => "https://github.com/example/#{slug}", "source" => "github"},
      "upstream" => Fixtures.fake_stdio_upstream("modern", %{}),
      "rate_limit" => %{"requests" => 60, "window_ms" => 60_000},
      "compliance" => %{
        "verdict" => "allowed",
        "terms_url" => "https://example.com/terms",
        "checked_on" => Date.to_iso8601(Date.utc_today()),
        "commercial_use" => "yes",
        "proxy_or_resale" => "yes",
        "notes" => "fixture entry, no real provider"
      }
    }
  end

  # Top-level keys replace; keys inside "compliance" are merged onto the baseline, so a test
  # can flip just the verdict or just the date.
  defp write_entry(dir, slug, overrides \\ %{}) do
    base = entry(slug)
    {compliance, overrides} = Map.pop(overrides, "compliance", %{})

    json =
      base
      |> Map.merge(overrides)
      |> Map.put("compliance", Map.merge(base["compliance"], compliance))

    write_raw(dir, slug, json)
  end

  defp write_raw(dir, slug, json) do
    path = Path.join(dir, "#{slug}.json")
    File.write!(path, Jason.encode!(json))
    path
  end

  defp pop_compliance_key(json, key) do
    Map.put(json, "compliance", Map.delete(json["compliance"], key))
  end
end
