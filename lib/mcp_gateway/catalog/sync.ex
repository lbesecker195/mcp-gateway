defmodule McpGateway.Catalog.Sync do
  @moduledoc """
  Write side of the catalog: reviewed files in `catalog/servers/*.json` become database rows.

  Each file is a human-reviewed record of one upstream MCP server, including the compliance
  verdict for the API behind it. This module is where that verdict is enforced:

    * only an `allowed` verdict that was checked within
      `:compliance_max_age_days` is imported (`McpGateway.Catalog.Compliance.servable?/3`);
    * anything else — `not_allowed`, `unknown`, or a verdict too old to trust — is skipped,
      and if that slug is already in the database it is **delisted in the same run**, so a
      verdict that flips stops routing immediately;
    * a file we cannot parse is a failure, never a silent default. Nothing is written for it,
      and if it names a slug we are currently routing to, that slug is delisted as well. An
      edit meant to pull a server must not leave it listed because the same edit had a typo
      in it: an entry we cannot verify is not a verified entry.

  Nothing here invents data. A missing field, an unparseable `checked_on`, or a verdict we
  don't recognize fails the entry instead of guessing at it.

  An entry that passes the gate is probed with `McpGateway.Upstream.list_tools/2` so the tools
  we list are the ones the upstream really exposes, then the server row and its tool rows are
  written in one transaction. A failed probe leaves the previous row untouched: a flaky
  upstream must not empty the catalog.

  ## Fail closed when the write doesn't happen

  There is one thing a failed write still has to do. `exclude_tools` is how we honor terms that
  allow only part of an API, so the tools it names are deleted even when the probe failed or
  the write rolled back. A forbidden tool must not stay listed, routable and billable until the
  upstream comes back.

  ## Third-party metadata is checked before it is stored

  `tools/list` is whatever the upstream sends. `McpGateway.Catalog.Tool.build_attrs/2` checks
  the tool's name; everything else — title, description, schemas, annotations — is validated
  here for type, length and storability, because a wrong type would raise out of `insert_all`
  and take the run down with it. A tool we cannot store is dropped and logged, never guessed
  at. Each entry is also evaluated independently: whatever one file does, the rest of the
  directory is still walked, so a verdict that flipped is never left unenforced because an
  earlier entry blew up.

  ## Report

  `sync_all/1` returns `{:ok, report}` where report is

      %{
        dir: "/abs/path/catalog/servers",
        imported: ["arxiv"],
        updated: ["openmeteo"],
        delisted: [{"wikipedia", {:verdict, "not_allowed"}}],
        skipped: [{"wikipedia", {:verdict, "not_allowed"}}],
        failed: [{"/abs/path/broken.json", {:missing_field, "version"}}],
        counts: %{imported: 1, updated: 1, delisted: 1, skipped: 1, failed: 1}
      }

  A skipped entry that was already listed appears in both `:skipped` (the gate's decision)
  and `:delisted` (what that decision did to the database). A failed file that was already
  listed appears in both `:failed` and `:delisted`. `explain/1` turns any reason into a line
  fit for an operator.

  ## Options

    * `:dir` — read this directory instead of the configured one (tests, one-off imports)
    * `:offline` — skip probing; existing tools are kept, new servers start with none
    * `:slug` — only the entry with this slug
    * `:prune` — delist active servers that no longer have a catalog file. Skipped when any
      file failed to parse, since the unreadable file may be the one that lists the server.
    * `:today` — the date the compliance gate is evaluated against (defaults to today)
  """

  import Ecto.Query

  require Logger

  alias McpGateway.Catalog.{Compliance, Server, Tool}
  alias McpGateway.{Repo, Settings, Upstream}

  @required_strings ~w(slug name version description)
  @optional_strings ~w(title website_url)

  # `tools.title`, `tools.name` and `tools.upstream_name` are varchar(255); `description` is
  # text. Postgres counts characters, not graphemes, so `char_count/1` counts codepoints.
  @max_varchar 255
  @sized_strings [:name, :upstream_name, :title]
  @text_strings [:description]
  @required_maps [:input_schema]
  @optional_maps [:output_schema, :annotations]

  ## Public API

  @doc "Syncs every `*.json` file in the catalog directory. See the moduledoc for options."
  def sync_all(opts \\ []) do
    dir = catalog_dir(opts)

    if File.dir?(dir) do
      entries =
        dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&{&1, read_entry(&1)})
        |> select_slug(opts[:slug])

      report =
        Enum.reduce(entries, empty_report(dir), fn {path, entry}, report ->
          record(report, path, safely(path, fn -> apply_entry(path, entry, opts) end))
        end)

      {:ok, report |> prune(opts, known_slugs(entries)) |> finish()}
    else
      {:error, {:catalog_dir_not_found, dir}}
    end
  end

  @doc """
  Syncs one catalog file.

  Returns `{:ok, server}` when it passed the gate and was written, `{:skip, reason}` when the
  gate rejected it (the slug is delisted if it was listed), or `{:error, reason}` when the
  file is invalid or the upstream probe failed. An invalid file delists the slug it names, so
  `{:error, reason}` never means "still routing".
  """
  def sync_file(path, opts \\ []) do
    entry = read_entry(path)

    case safely(path, fn -> apply_entry(path, entry, opts) end) do
      {:ok, _action, server} -> {:ok, server}
      {:skipped, _slug, reason, _delisted?} -> {:skip, reason}
      {:error, reason, _delisted} -> {:error, reason}
    end
  end

  @doc """
  Marks a server `deprecated` so `McpGateway.Catalog` stops listing and routing to it.

  The tool rows stay: every catalog query joins through `Catalog.servable_servers/1`, so a
  deprecated server is already unreachable, and keeping them means a verdict that goes back
  to `allowed` doesn't need a probe to be useful again.
  """
  def delist(slug, reason) when is_binary(slug) do
    case Repo.get_by(Server, slug: slug) do
      nil ->
        {:ok, :not_listed}

      %Server{status: "deprecated"} ->
        {:ok, :already_delisted}

      server ->
        Logger.warning("catalog sync: delisting #{slug}: #{explain(reason)}")

        case server |> Server.changeset(%{status: "deprecated"}) |> Repo.update() do
          {:ok, _server} -> {:ok, :delisted}
          {:error, changeset} -> {:error, {:invalid_server, changeset_errors(changeset)}}
        end
    end
  end

  @doc """
  The directory catalog files are read from.

  `:dir` wins, then an absolute `:catalog_dir` setting, then the copy shipped inside the
  release, then the path relative to the project root.
  """
  def catalog_dir(opts \\ []) do
    case Keyword.get(opts, :dir) do
      dir when is_binary(dir) -> Path.expand(dir)
      _ -> default_dir(Settings.get(:catalog_dir))
    end
  end

  @doc "A one-line, operator-readable rendering of any reason this module returns."
  def explain({:missing_field, field}), do: "missing required field: #{field}"
  def explain({:invalid_field, field}), do: "invalid value for field: #{field}"
  def explain({:invalid_json, message}), do: "invalid JSON: #{message}"
  def explain({:invalid_date, value}), do: "unparseable date: #{inspect(value)}"
  def explain({:unknown_verdict, value}), do: "unknown compliance verdict: #{inspect(value)}"
  def explain({:unknown_upstream_type, value}), do: "unknown upstream type: #{inspect(value)}"
  def explain({:verdict, verdict}), do: "compliance verdict is #{verdict}"
  def explain(:not_in_catalog), do: "no catalog file for this server any more"
  def explain({:unreadable, posix}), do: "unreadable file: #{:file.format_error(posix)}"
  def explain({:catalog_dir_not_found, dir}), do: "catalog directory not found: #{dir}"
  def explain({:probe_failed, reason}), do: "upstream probe failed: #{inspect(reason)}"
  def explain({:unexpected, message}), do: "unexpected failure: #{message}"
  def explain(:not_a_json_object), do: "file is not a JSON object"

  def explain({:invalid_metadata, field, why}),
    do: "upstream tool metadata rejected: #{field} #{why}"

  def explain({:stale, %Date{} = checked_on}) do
    "compliance last checked on #{Date.to_iso8601(checked_on)}, " <>
      "older than #{Settings.get(:compliance_max_age_days)} days"
  end

  def explain({:invalid_server, errors}) do
    detail =
      errors
      |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(List.wrap(messages), ", ")}" end)
      |> Enum.join("; ")

    "invalid server record: #{detail}"
  end

  def explain(other), do: inspect(other)

  ## Per-entry isolation

  # One bad entry must not stop the run. `sync_all/1` walks the directory in sorted order, so
  # an exception escaping here would leave every later entry unevaluated — including a verdict
  # that flipped to `not_allowed` and still has to delist. Anything unexpected (a third-party
  # payload the database refuses, a bug in here) is recorded against the file it came from and
  # the walk continues.
  defp safely(path, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "catalog sync: #{Path.basename(path)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:unexpected, Exception.message(exception)}, nil}
  end

  ## The gate

  # Default deny. A file we cannot read, parse or validate is not a reviewed entry, so if it
  # names a server we are currently routing to, that server stops being routable now. Catalog
  # files are named after the slug they carry, which is what identifies the server when the
  # contents no longer parse at all.
  defp apply_entry(_path, {:error, reason, slug}, _opts) do
    case delist(slug, reason) do
      {:ok, :delisted} -> {:error, reason, slug}
      _ -> {:error, reason, nil}
    end
  end

  defp apply_entry(_path, {:ok, entry}, opts) do
    today = Keyword.get(opts, :today, Date.utc_today())

    if Compliance.servable?(entry.verdict, entry.checked_on, today) do
      import_entry(entry, opts)
    else
      reason = gate_reason(entry, today)

      case delist(entry.slug, reason) do
        {:ok, :delisted} -> {:skipped, entry.slug, reason, true}
        _ -> {:skipped, entry.slug, reason, false}
      end
    end
  end

  defp gate_reason(entry, today) do
    cond do
      entry.verdict != "allowed" -> {:verdict, entry.verdict}
      Compliance.stale?(entry.checked_on, today) -> {:stale, entry.checked_on}
      true -> :not_servable
    end
  end

  ## Import

  defp import_entry(entry, opts) do
    existing = Repo.get_by(Server, slug: entry.slug)

    result =
      case probe(entry, opts) do
        {:ok, tools} -> write(entry, existing, tools)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, action, server} -> {:ok, action, server}
      {:error, reason} -> {:error, fail_closed(entry, existing, reason), nil}
    end
  end

  # The write didn't happen: the probe failed, or the transaction rolled back. The previous row
  # and its tools stand, because a flaky upstream must not empty the catalog — but an exclusion
  # added to the file is a compliance decision, not a description of the upstream, and it takes
  # effect whether or not we could reach anyone. Otherwise a tool the terms now forbid stays
  # listed, routable and billable until the upstream comes back.
  defp fail_closed(_entry, nil, reason), do: reason

  defp fail_closed(entry, %Server{} = existing, reason) do
    drop_excluded(existing, entry.exclude_tools)
    reason
  end

  # `:keep` means "leave the tool rows alone": there was no probe to replace them with.
  defp probe(entry, opts) do
    if Keyword.get(opts, :offline, false) do
      {:ok, :keep}
    else
      upstream = %{slug: entry.slug, upstream: entry.upstream}

      case Upstream.list_tools(upstream, Keyword.take(opts, [:timeout])) do
        {:ok, tools} ->
          {:ok, tools}

        {:error, reason} ->
          reason = {:probe_failed, sanitize(reason)}
          Logger.warning("catalog sync: #{entry.slug}: #{explain(reason)}")
          {:error, reason}
      end
    end
  end

  # An upstream's error payload can carry anything; keep the code and message, drop the data.
  defp sanitize({:rpc_error, code, message, _data}), do: {:rpc_error, code, message}
  defp sanitize(reason), do: reason

  # Belt and braces. The gate above is the only caller, but this is the function that writes,
  # so it refuses anything but `allowed` on its own account.
  defp write(%{verdict: verdict}, _existing, _tools) when verdict != "allowed" do
    {:error, {:refused_verdict, verdict}}
  end

  defp write(entry, existing, tools) do
    attrs = server_attrs(entry, existing)

    Repo.transaction(fn ->
      with {:ok, server} <- upsert(existing, attrs),
           {:ok, _count} <- put_tools(server, entry, tools) do
        server
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          Repo.rollback({:invalid_server, changeset_errors(changeset)})

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, server} -> {:ok, action(existing), server}
      {:error, reason} -> {:error, reason}
    end
  end

  defp action(nil), do: :imported
  defp action(%Server{}), do: :updated

  defp upsert(nil, attrs), do: %Server{} |> Server.changeset(attrs) |> Repo.insert()

  defp upsert(%Server{} = existing, attrs),
    do: existing |> Server.changeset(attrs) |> Repo.update()

  defp server_attrs(entry, existing) do
    %{
      name: entry.name,
      slug: entry.slug,
      version: entry.version,
      title: entry.title,
      description: entry.description,
      website_url: entry.website_url,
      repository: entry.repository,
      upstream: entry.upstream,
      rate_limit: entry.rate_limit,
      compliance: entry.compliance,
      compliance_verdict: entry.verdict,
      compliance_checked_on: entry.checked_on,
      # Search terms, kept out of `compliance` because they are marketing copy, not evidence.
      docs: %{"keywords" => entry.keywords},
      status: "active",
      published_at: published_at(existing)
    }
  end

  defp published_at(%Server{published_at: %DateTime{} = at}), do: at
  defp published_at(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Tools

  # Offline: the previously discovered tools stand, but an exclusion added to the file takes
  # effect right away. That list is how we honor terms allowing only part of an API.
  defp put_tools(server, entry, :keep) do
    {:ok, drop_excluded(server, entry.exclude_tools)}
  end

  defp put_tools(server, entry, definitions) when is_list(definitions) do
    {rows, dropped} = tool_rows(server, entry, definitions)
    log_dropped(server.slug, dropped)

    Repo.delete_all(from t in Tool, where: t.server_id == ^server.id)
    {count, _} = Repo.insert_all(Tool, rows)

    if count == 0 do
      Logger.warning("catalog sync: #{server.slug}: no listable tools after exclusions")
    end

    {:ok, count}
  end

  defp drop_excluded(_server, []), do: 0

  defp drop_excluded(server, names) when is_list(names) do
    {count, _} =
      Repo.delete_all(
        from t in Tool, where: t.server_id == ^server.id and t.upstream_name in ^names
      )

    if count > 0 do
      Logger.info("catalog sync: #{server.slug}: removed #{count} excluded tool(s)")
    end

    count
  end

  defp tool_rows(server, entry, definitions) do
    excluded = MapSet.new(entry.exclude_tools)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {rows, dropped} =
      Enum.reduce(definitions, {[], []}, fn definition, {rows, dropped} ->
        name = is_map(definition) && definition["name"]

        cond do
          not is_binary(name) ->
            {rows, [{inspect(name), :not_a_tool} | dropped]}

          MapSet.member?(excluded, name) ->
            {rows, [{name, :excluded} | dropped]}

          true ->
            case build_row(server, definition, now) do
              {:ok, row} -> {[row | rows], dropped}
              {:error, reason} -> {rows, [{name, reason} | dropped]}
            end
        end
      end)

    {rows |> Enum.reverse() |> Enum.uniq_by(& &1.name), Enum.reverse(dropped)}
  end

  defp build_row(server, definition, now) do
    with {:ok, attrs} <- Tool.build_attrs(server.slug, definition),
         :ok <- check_attrs(attrs) do
      {:ok,
       Map.merge(attrs, %{
         id: Ecto.UUID.generate(),
         server_id: server.id,
         inserted_at: now,
         updated_at: now
       })}
    end
  end

  # `Tool.build_attrs/2` validates the tool's name. Everything else is metadata a third party
  # sent us, and `Repo.insert_all/2` does not validate: a description that is an object, a
  # title longer than the column, or a null byte anywhere in a JSON document all raise, aborting
  # the transaction and — before `safely/2` — the whole run. Check it here and drop the tool we
  # cannot store, rather than coercing it into something the upstream never said.
  defp check_attrs(attrs) do
    with :ok <- check_strings(attrs, @sized_strings, @max_varchar),
         :ok <- check_strings(attrs, @text_strings, :unbounded),
         :ok <- check_maps(attrs, @required_maps, :required),
         :ok <- check_maps(attrs, @optional_maps, :optional) do
      :ok
    end
  end

  defp check_strings(attrs, fields, limit) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case Map.get(attrs, field) do
        nil ->
          {:cont, :ok}

        value when is_binary(value) ->
          cond do
            null_byte?(value) -> {:halt, invalid(field, "contains a null byte")}
            too_long?(value, limit) -> {:halt, invalid(field, "is longer than #{limit} chars")}
            true -> {:cont, :ok}
          end

        _other ->
          {:halt, invalid(field, "is not a string")}
      end
    end)
  end

  defp check_maps(attrs, fields, presence) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case Map.get(attrs, field) do
        value when is_map(value) ->
          if null_byte?(value),
            do: {:halt, invalid(field, "contains a null byte")},
            else: {:cont, :ok}

        nil when presence == :optional ->
          {:cont, :ok}

        _other ->
          {:halt, invalid(field, "is not a JSON object")}
      end
    end)
  end

  defp invalid(field, why), do: {:error, {:invalid_metadata, field, why}}

  defp too_long?(_value, :unbounded), do: false
  defp too_long?(value, limit), do: char_count(value) > limit

  defp char_count(value), do: value |> String.to_charlist() |> length()

  # Postgres stores neither a text value nor a jsonb document containing U+0000, so a schema
  # with one buried in it fails at insert time. Look before we leap.
  defp null_byte?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp null_byte?(value) when is_list(value), do: Enum.any?(value, &null_byte?/1)

  defp null_byte?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> null_byte?(key) or null_byte?(val) end)
  end

  defp null_byte?(_value), do: false

  defp log_dropped(slug, dropped) do
    for {name, :excluded} <- dropped do
      Logger.info("catalog sync: #{slug}: excluding tool #{name} (exclude_tools)")
    end

    for {name, reason} <- dropped, reason != :excluded do
      Logger.warning("catalog sync: #{slug}: skipping tool #{name}: #{inspect(reason)}")
    end

    :ok
  end

  ## Reading and validating files

  # Returns `{:ok, entry}` or `{:error, reason, slug}`. The slug on a failure is what the file
  # claims to describe: its own `slug` field when the file parsed far enough to have one, and
  # otherwise the filename, since catalog files are named after their slug. It is what tells
  # the gate which server an unusable file leaves us unable to vouch for.
  defp read_entry(path) do
    fallback = Path.basename(path, ".json")

    case File.read(path) do
      {:ok, body} -> decode(body, fallback)
      {:error, posix} -> {:error, {:unreadable, posix}, fallback}
    end
  end

  defp decode(body, fallback) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) ->
        case validate(json) do
          {:ok, entry} -> {:ok, entry}
          {:error, reason} -> {:error, reason, claimed_slug(json, fallback)}
        end

      {:ok, _other} ->
        {:error, :not_a_json_object, fallback}

      {:error, error} ->
        {:error, {:invalid_json, Exception.message(error)}, fallback}
    end
  end

  defp claimed_slug(%{"slug" => slug}, _fallback) when is_binary(slug) and slug != "", do: slug
  defp claimed_slug(_json, fallback), do: fallback

  defp validate(json) do
    with :ok <- validate_strings(json, @required_strings, :required),
         :ok <- validate_strings(json, @optional_strings, :optional),
         :ok <- validate_map(json, "repository", :optional),
         :ok <- validate_upstream(json["upstream"]),
         :ok <- validate_rate_limit(json["rate_limit"]),
         {:ok, exclude} <- validate_exclude(json["exclude_tools"]),
         {:ok, keywords} <- validate_keywords(json["keywords"]),
         {:ok, compliance} <- validate_compliance(json["compliance"]) do
      {:ok,
       %{
         slug: json["slug"],
         keywords: keywords,
         name: json["name"],
         version: json["version"],
         title: json["title"],
         description: json["description"],
         website_url: json["website_url"],
         repository: json["repository"],
         upstream: json["upstream"],
         rate_limit: json["rate_limit"],
         exclude_tools: exclude,
         compliance: compliance.record,
         verdict: compliance.verdict,
         checked_on: compliance.checked_on
       }}
    end
  end

  defp validate_strings(json, fields, presence) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case Map.get(json, field) do
        value when is_binary(value) and value != "" -> {:cont, :ok}
        nil when presence == :optional -> {:cont, :ok}
        nil -> {:halt, {:error, {:missing_field, field}}}
        _other -> {:halt, {:error, {:invalid_field, field}}}
      end
    end)
  end

  defp validate_map(json, field, presence) do
    case Map.get(json, field) do
      map when is_map(map) and map_size(map) > 0 -> :ok
      nil when presence == :optional -> :ok
      nil -> {:error, {:missing_field, field}}
      _other -> {:error, {:invalid_field, field}}
    end
  end

  defp validate_upstream(%{"type" => "stdio"} = upstream) do
    if is_binary(upstream["command"]) and upstream["command"] != "" do
      :ok
    else
      {:error, {:missing_field, "upstream.command"}}
    end
  end

  defp validate_upstream(%{"type" => "streamable-http"} = upstream) do
    case upstream["url"] do
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} when scheme in ~w(http https) and is_binary(host) ->
            if host == "", do: {:error, {:invalid_field, "upstream.url"}}, else: :ok

          _ ->
            {:error, {:invalid_field, "upstream.url"}}
        end

      _ ->
        {:error, {:missing_field, "upstream.url"}}
    end
  end

  defp validate_upstream(%{"type" => type}) when is_binary(type) do
    {:error, {:unknown_upstream_type, type}}
  end

  defp validate_upstream(upstream) when is_map(upstream),
    do: {:error, {:missing_field, "upstream.type"}}

  defp validate_upstream(nil), do: {:error, {:missing_field, "upstream"}}
  defp validate_upstream(_), do: {:error, {:invalid_field, "upstream"}}

  defp validate_rate_limit(nil), do: :ok

  defp validate_rate_limit(%{"requests" => requests, "window_ms" => window})
       when is_integer(requests) and requests > 0 and is_integer(window) and window > 0 do
    :ok
  end

  defp validate_rate_limit(_), do: {:error, {:invalid_field, "rate_limit"}}

  defp validate_exclude(nil), do: {:ok, []}

  defp validate_exclude(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: {:error, {:invalid_field, "exclude_tools"}}
  end

  defp validate_exclude(_), do: {:error, {:invalid_field, "exclude_tools"}}

  # Search terms for our registry endpoint and for downstream aggregators. Trimmed, de-duplicated
  # and capped, because they are published and the registry caps publisher metadata at 4KB.
  defp validate_keywords(nil), do: {:ok, []}

  defp validate_keywords(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, list |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.take(12)}
    else
      {:error, {:invalid_field, "keywords"}}
    end
  end

  defp validate_keywords(_), do: {:error, {:invalid_field, "keywords"}}

  defp validate_compliance(record) when is_map(record) and map_size(record) > 0 do
    with :ok <- validate_compliance_strings(record),
         {:ok, verdict} <- validate_verdict(record["verdict"]),
         {:ok, checked_on} <- validate_date(record["checked_on"]) do
      {:ok, %{record: record, verdict: verdict, checked_on: checked_on}}
    end
  end

  defp validate_compliance(nil), do: {:error, {:missing_field, "compliance"}}
  defp validate_compliance(_), do: {:error, {:invalid_field, "compliance"}}

  # `terms_url` is the source the verdict was read from. An entry without one can't be
  # re-checked, so it isn't a reviewed entry at all.
  defp validate_compliance_strings(record) do
    case record["terms_url"] do
      url when is_binary(url) and url != "" -> :ok
      nil -> {:error, {:missing_field, "compliance.terms_url"}}
      _ -> {:error, {:invalid_field, "compliance.terms_url"}}
    end
  end

  defp validate_verdict(verdict) when is_binary(verdict) do
    if verdict in Compliance.verdicts(),
      do: {:ok, verdict},
      else: {:error, {:unknown_verdict, verdict}}
  end

  defp validate_verdict(nil), do: {:error, {:missing_field, "compliance.verdict"}}
  defp validate_verdict(other), do: {:error, {:unknown_verdict, other}}

  defp validate_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, {:invalid_date, value}}
    end
  end

  defp validate_date(nil), do: {:error, {:missing_field, "compliance.checked_on"}}
  defp validate_date(other), do: {:error, {:invalid_date, other}}

  ## Report

  defp empty_report(dir) do
    %{dir: dir, imported: [], updated: [], delisted: [], skipped: [], failed: []}
  end

  defp record(report, _path, {:ok, :imported, server}), do: add(report, :imported, server.slug)
  defp record(report, _path, {:ok, :updated, server}), do: add(report, :updated, server.slug)
  defp record(report, path, {:error, reason, nil}), do: add(report, :failed, {path, reason})

  defp record(report, path, {:error, reason, slug}) do
    report |> add(:failed, {path, reason}) |> add(:delisted, {slug, reason})
  end

  defp record(report, _path, {:skipped, slug, reason, delisted?}) do
    report = add(report, :skipped, {slug, reason})
    if delisted?, do: add(report, :delisted, {slug, reason}), else: report
  end

  defp add(report, key, value), do: Map.update!(report, key, &[value | &1])

  defp finish(report) do
    report =
      Map.merge(report, %{
        imported: Enum.reverse(report.imported),
        updated: Enum.reverse(report.updated),
        delisted: Enum.reverse(report.delisted),
        skipped: Enum.reverse(report.skipped),
        failed: Enum.reverse(report.failed)
      })

    counts =
      Map.new([:imported, :updated, :delisted, :skipped, :failed], fn key ->
        {key, length(Map.fetch!(report, key))}
      end)

    Map.put(report, :counts, counts)
  end

  defp known_slugs(entries) do
    for {_path, {:ok, entry}} <- entries, do: entry.slug
  end

  defp prune(report, opts, slugs) do
    cond do
      not Keyword.get(opts, :prune, false) -> report
      opts[:slug] -> report
      report.failed != [] -> report
      true -> do_prune(report, slugs)
    end
  end

  defp do_prune(report, slugs) do
    Server
    |> where([s], s.status == "active" and s.slug not in ^slugs)
    |> select([s], s.slug)
    |> Repo.all()
    |> Enum.reduce(report, fn slug, report ->
      case delist(slug, :not_in_catalog) do
        {:ok, :delisted} -> add(report, :delisted, {slug, :not_in_catalog})
        _ -> report
      end
    end)
  end

  ## Helpers

  defp select_slug(entries, nil), do: entries

  defp select_slug(entries, slug) do
    Enum.filter(entries, fn
      {_path, {:ok, entry}} -> entry.slug == slug
      {_path, {:error, _reason, claimed}} -> claimed == slug
    end)
  end

  defp default_dir(dir) do
    packaged = packaged_dir(dir)

    cond do
      Path.type(dir) == :absolute -> dir
      is_binary(packaged) and File.dir?(packaged) -> packaged
      true -> Path.expand(dir, File.cwd!())
    end
  end

  defp packaged_dir(dir) do
    Application.app_dir(:mcp_gateway, dir)
  rescue
    ArgumentError -> nil
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
