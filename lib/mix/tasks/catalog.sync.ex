defmodule Mix.Tasks.Catalog.Sync do
  @shortdoc "Imports reviewed catalog files into the database through the compliance gate"

  @moduledoc """
  Turns the reviewed catalog files in `catalog/servers/*.json` into database rows.

      mix catalog.sync                  # sync every entry, probing each upstream
      mix catalog.sync --offline        # skip probing; keep the tools already discovered
      mix catalog.sync --slug arxiv     # just one entry
      mix catalog.sync --dir some/dir   # read a different catalog directory
      mix catalog.sync --prune          # also delist servers whose catalog file is gone

  Only an `allowed`, freshly checked entry is imported. Anything else is skipped, and is
  delisted if it was already listed, so a verdict that flipped stops routing in this run.

  The same holds for a file that no longer parses: it is reported as failed, and the slug it
  names is delisted too, because an entry we cannot verify is not a verified entry. A tool
  added to `exclude_tools` is dropped even when the upstream probe fails — an exclusion is a
  compliance decision and does not wait for a provider to come back.

  Each entry is applied on its own, so one broken file or one upstream sending metadata we
  cannot store never stops the rest of the directory from being evaluated.

  Exits with status 1 if any entry failed, so CI notices a catalog file that stopped parsing
  or an upstream that stopped answering.

  ## Options

    * `--dir`, `-d` — catalog directory (default: the `:catalog_dir` setting)
    * `--offline` — do not probe upstreams
    * `--slug`, `-s` — sync only the entry with this slug
    * `--prune` — delist active servers with no catalog file (skipped if any file failed)
  """

  use Mix.Task

  alias McpGateway.Catalog.Sync

  @switches [dir: :string, offline: :boolean, slug: :string, prune: :boolean]
  @aliases [d: :dir, s: :slug]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    Mix.Task.run("app.start")

    case Sync.sync_all(opts) do
      {:ok, report} ->
        print(report)
        if report.counts.failed > 0, do: exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("catalog sync: #{Sync.explain(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print(report) do
    shell = Mix.shell()
    shell.info("catalog: #{report.dir}")

    delisted = MapSet.new(report.delisted, fn {slug, _reason} -> slug end)
    skipped = MapSet.new(report.skipped, fn {slug, _reason} -> slug end)

    for slug <- report.imported, do: shell.info("  imported  #{slug}")
    for slug <- report.updated, do: shell.info("  updated   #{slug}")

    for {slug, reason} <- report.skipped do
      suffix = if MapSet.member?(delisted, slug), do: " (delisted)", else: ""
      shell.info("  skipped   #{slug} -- #{Sync.explain(reason)}#{suffix}")
    end

    for {slug, reason} <- report.delisted, not MapSet.member?(skipped, slug) do
      shell.info("  delisted  #{slug} -- #{Sync.explain(reason)}")
    end

    for {path, reason} <- report.failed do
      shell.error("  failed    #{Path.basename(path)} -- #{Sync.explain(reason)}")
    end

    counts = report.counts

    shell.info(
      "#{counts.imported} imported, #{counts.updated} updated, #{counts.delisted} delisted, " <>
        "#{counts.skipped} skipped, #{counts.failed} failed"
    )
  end
end
