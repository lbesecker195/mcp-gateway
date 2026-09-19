defmodule McpGateway.RegistryPublish do
  @moduledoc """
  Renders catalog entries as `server.json` documents for publishing to the **official** MCP
  Registry at `registry.modelcontextprotocol.io`.

  This is deliberately separate from `McpGateway.RegistryJSON`, which renders entries for our
  own registry endpoint. The official registry enforces rules our own does not:

    * `name` at most 200 characters, reverse-DNS, exactly one `/`.
    * `description` at most **100 characters** — the main thing a search matches on.
    * `title` at most 100 characters, `version` at most 255.
    * In `_meta`, only `io.modelcontextprotocol.registry/publisher-provided` is preserved;
      every other key is silently dropped. So our pricing and compliance blocks have to be
      nested under that key or they vanish.
    * The publisher-provided object is capped at **4096 bytes** of JSON, and publishing fails
      above it.
    * Namespace ownership must be proven by DNS before publishing.

  We publish `remotes` (our own gateway endpoint), never `packages`. That matters: the official
  registry verifies that a publisher owns any package they reference, and we do not own the
  upstream npm and PyPI packages we route to. Publishing them as ours would be a false ownership
  claim. Each entry describes the endpoint *we* operate, and credits the upstream in its
  metadata.

  Rules: https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/server-json/official-registry-requirements.md
  """

  alias McpGateway.Catalog
  alias McpGateway.Catalog.Server
  alias McpGateway.Settings

  @schema_url "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json"
  @publisher_key "io.modelcontextprotocol.registry/publisher-provided"
  @max_name 200
  @max_description 100
  @max_title 100
  @max_version 255
  @max_publisher_bytes 4096

  @doc "Every servable catalog entry plus the gateway itself, as publish-ready documents."
  def all do
    servers = Catalog.list_servers_with_tools()
    counts = Map.new(servers, &{&1.id, length(&1.tools)})

    [gateway(servers) | Enum.map(servers, &server(&1, counts[&1.id]))]
  end

  @doc "One catalog entry as an official-registry `server.json`."
  def server(%Server{} = s, tool_count \\ nil) do
    %{
      "$schema" => @schema_url,
      "name" => s.name,
      "description" => s.description,
      "version" => s.version,
      "websiteUrl" => "#{Settings.canonical_base_url()}/docs/servers/#{s.slug}",
      "remotes" => [
        %{"type" => "streamable-http", "url" => "#{Settings.canonical_base_url()}/mcp/#{s.slug}"}
      ],
      "_meta" => %{@publisher_key => publisher_meta(s, tool_count)}
    }
    |> put_present("title", s.title)
    |> put_present("repository", s.repository)
  end

  @doc "The gateway's own aggregate entry."
  def gateway(servers) do
    tool_count = servers |> Enum.map(&length(&1.tools)) |> Enum.sum()

    %{
      "$schema" => @schema_url,
      "name" => "#{Settings.registry_namespace()}/gateway",
      "title" => "MCP Gateway",
      "description" => "One metered MCP endpoint for public data APIs, billed per tool call",
      "version" => Settings.server_version(),
      "websiteUrl" => Settings.canonical_base_url(),
      "remotes" => [
        %{"type" => "streamable-http", "url" => "#{Settings.canonical_base_url()}/mcp"}
      ],
      "_meta" => %{
        @publisher_key => %{
          "dev.mcpharbor" => %{
            "pricePerCallUsd" => McpGateway.Billing.format_usd(Settings.price_micro_usd()),
            "billing" => "prepaid credits, drawn down per tool call",
            "freeOperations" => "server/discover, tools/list, registry and documentation",
            "toolCount" => tool_count,
            "serverCount" => length(servers),
            "providers" => Enum.map(servers, & &1.slug),
            "registryApi" => "#{Settings.canonical_base_url()}/v0.1/servers",
            "llmsTxt" => "#{Settings.canonical_base_url()}/llms.txt",
            "agentTxt" => "#{Settings.canonical_base_url()}/agent.txt"
          }
        }
      }
    }
  end

  # Everything we want downstream aggregators to index, inside the one key the registry keeps.
  # Kept small on purpose: the whole object must marshal to under 4KB.
  defp publisher_meta(%Server{} = s, tool_count) do
    compliance = s.compliance || %{}

    inner =
      %{
        "keywords" => Enum.take(McpGateway.Catalog.keywords(s), 12),
        "pricePerCallUsd" => McpGateway.Billing.format_usd(Settings.price_micro_usd()),
        "billing" => "prepaid credits, drawn down per tool call",
        "toolCount" => tool_count,
        "dataProvider" => compliance["api_docs_url"],
        "dataTerms" => compliance["terms_url"],
        "attribution" => compliance["attribution"],
        # Credit the upstream MCP server we route through. We do not own it, and saying so
        # plainly is both accurate and courteous to its author.
        "upstreamServer" => compliance["upstream_package"],
        "upstreamLicense" => compliance["upstream_license"],
        "docs" => "#{Settings.canonical_base_url()}/docs/servers/#{s.slug}"
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)
      |> Map.new()

    %{"dev.mcpharbor" => inner}
  end

  @doc """
  Checks a rendered document against the official registry's limits. Returns `:ok` or
  `{:error, problems}`. Run this before publishing: the registry rejects the whole document,
  and a 101-character description is a silly way to fail.
  """
  def validate(doc) when is_map(doc) do
    problems =
      [
        check(byte_size(doc["name"] || "") in 1..@max_name, "name must be 1..#{@max_name} bytes"),
        check(length(String.split(doc["name"] || "", "/")) == 2, "name needs exactly one '/'"),
        check(
          String.match?(doc["name"] || "", ~r{^[a-zA-Z0-9.\-]+/[a-zA-Z0-9._\-]+$}),
          "name must be reverse-DNS namespace/name"
        ),
        check(
          String.length(doc["description"] || "") in 1..@max_description,
          "description must be 1..#{@max_description} characters (got #{String.length(doc["description"] || "")})"
        ),
        check(
          String.length(doc["title"] || "") <= @max_title,
          "title over #{@max_title} characters"
        ),
        check(
          byte_size(doc["version"] || "") in 1..@max_version,
          "version must be 1..#{@max_version}"
        ),
        check(
          Map.keys(doc["_meta"] || %{}) -- [@publisher_key] == [],
          "_meta may only contain #{@publisher_key}; other keys are dropped on publish"
        ),
        check(
          publisher_bytes(doc) <= @max_publisher_bytes,
          "publisher-provided metadata is #{publisher_bytes(doc)} bytes, over the #{@max_publisher_bytes} limit"
        ),
        check(doc["packages"] == nil, "do not publish packages we do not own; publish remotes"),
        check(
          Enum.all?(doc["remotes"] || [], &String.starts_with?(&1["url"] || "", "https://")),
          "every remote url must be https"
        )
      ]
      |> Enum.reject(&is_nil/1)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp publisher_bytes(doc) do
    case get_in(doc, ["_meta", @publisher_key]) do
      nil -> 0
      meta -> meta |> Jason.encode!() |> byte_size()
    end
  end

  defp check(true, _message), do: nil
  defp check(false, message), do: message

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
