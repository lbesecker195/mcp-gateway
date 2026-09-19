defmodule Mix.Tasks.Registry.Export do
  @shortdoc "Write publish-ready server.json files for the official MCP Registry"

  @moduledoc """
  Renders every servable catalog entry, plus the gateway itself, as a `server.json` for the
  official MCP Registry, and validates each against that registry's limits.

      mix registry.export
      mix registry.export --out tmp/registry --check

  This writes files. It does **not** publish: publishing is an outward-facing action that
  changes a public, shared registry, so a human runs `mcp-publisher` on the output after
  reviewing it. Publishing also needs DNS proof of the namespace — for
  `#{"dev.mcpharbor.gateway"}` that means proving control of `gateway.mcpharbor.dev`.

  Options:

    * `--out DIR`  where to write (default `tmp/registry`)
    * `--check`    validate only, write nothing; exits non-zero if anything is invalid
  """

  use Mix.Task

  alias McpGateway.RegistryPublish

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [out: :string, check: :boolean])
    Mix.Task.run("app.start")

    out = opts[:out] || "tmp/registry"
    docs = RegistryPublish.all()

    # `all/0` always yields the gateway's own entry, so an empty catalog still renders one
    # document. Check the catalog itself rather than the rendered list.
    if McpGateway.Catalog.list_servers_with_tools() == [] do
      Mix.shell().error("Catalog has no servable entries. Run `mix catalog.sync` first.")
      exit({:shutdown, 1})
    end

    unless opts[:check], do: File.mkdir_p!(out)

    results =
      Enum.map(docs, fn doc ->
        name = doc["name"]
        file = String.replace(name, ~r{[/.]}, "_") <> ".json"
        json = Jason.encode!(doc, pretty: true)

        result = RegistryPublish.validate(doc)

        # Only a document that would actually be accepted gets written, so the output directory
        # never contains something that would fail at publish time.
        if result == :ok and opts[:check] != true do
          File.write!(Path.join(out, file), json <> "\n")
        end

        {name, String.length(doc["description"]), byte_size(json), result}
      end)

    Mix.shell().info("")

    Mix.shell().info(
      String.pad_trailing("server", 44) <> String.pad_trailing("desc", 6) <> "bytes"
    )

    Enum.each(results, fn {name, desc_len, bytes, result} ->
      mark = if result == :ok, do: "ok  ", else: "FAIL"

      Mix.shell().info(
        "#{mark} #{String.pad_trailing(name, 40)}#{String.pad_trailing("#{desc_len}/100", 6)}#{bytes}"
      )

      case result do
        {:error, problems} -> Enum.each(problems, &Mix.shell().error("       - #{&1}"))
        :ok -> :ok
      end
    end)

    failed = Enum.count(results, fn {_, _, _, r} -> r != :ok end)
    Mix.shell().info("")

    if failed > 0 do
      Mix.shell().error(
        "#{failed} of #{length(results)} documents are invalid; nothing was written for those."
      )

      exit({:shutdown, 1})
    end

    if opts[:check] do
      Mix.shell().info("#{length(results)} documents valid.")
    else
      Mix.shell().info("#{length(results)} documents written to #{out}/")

      Mix.shell().info(
        "Review them, then publish with `mcp-publisher` once the namespace is DNS-verified."
      )
    end
  end
end
