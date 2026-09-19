defmodule McpGateway.RegistryJSON do
  @moduledoc """
  Renders catalog entries as `server.json` documents, in the shape the MCP Registry API serves.

  This is the single source of truth for that shape: the registry controller and the docs
  generator both render through here, so a client reading `/v0.1/servers` and an agent reading
  `/server.json` can never see two different descriptions of the same server.

  Gateway-specific facts (price, compliance, upstream provider) go in `_meta` under our own
  reverse-DNS key, never as extra top-level fields. The key
  `io.modelcontextprotocol.registry/official` is reserved for the official registry and is
  never written here.

  Spec: https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/server-json/generic-server-json.md
  """

  alias McpGateway.Billing
  alias McpGateway.Catalog.Server
  alias McpGateway.Settings

  @schema_url "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json"

  def schema_url, do: @schema_url

  @doc """
  One catalog entry as a `server.json`. Its `remotes` entry points at this gateway's
  server-scoped MCP endpoint, so a client that discovers the entry can connect straight to us.
  """
  def server(%Server{} = server, opts \\ []) do
    %{
      "$schema" => @schema_url,
      "name" => server.name,
      "description" => server.description,
      "version" => server.version,
      "remotes" => [
        %{
          "type" => "streamable-http",
          "url" => "#{Settings.base_url()}/mcp/#{server.slug}",
          "headers" => [
            %{
              "name" => "Authorization",
              "description" =>
                "Bearer <your gateway API key>. Get one at #{Settings.base_url()}.",
              "isRequired" => true,
              "isSecret" => true
            }
          ]
        }
      ],
      "_meta" => meta(server, opts)
    }
    |> put_present("title", server.title)
    |> put_present("websiteUrl", server.website_url)
    |> put_present("repository", server.repository)
  end

  @doc "A `server.json` entry wrapped for a registry list or detail response."
  def envelope(%Server{} = server, opts \\ []) do
    %{"server" => server(server, opts)}
  end

  @doc """
  A registry list response: `{\"servers\": [...], \"metadata\": {\"count\", \"nextCursor\"}}`.
  `nextCursor` is omitted when there is no further page.
  """
  def list(servers, next_cursor, opts \\ []) do
    metadata = %{"count" => length(servers)}
    metadata = if next_cursor, do: Map.put(metadata, "nextCursor", next_cursor), else: metadata

    %{"servers" => Enum.map(servers, &envelope(&1, opts)), "metadata" => metadata}
  end

  @doc """
  The gateway's own `server.json`: one aggregate MCP endpoint exposing every servable tool.
  """
  def gateway_server(tool_count) do
    %{
      "$schema" => @schema_url,
      "name" => "#{Settings.registry_namespace()}/gateway",
      "title" => "MCP Gateway",
      "description" => "One metered MCP endpoint for many free and freemium APIs.",
      "version" => Settings.server_version(),
      "websiteUrl" => Settings.base_url(),
      "remotes" => [
        %{
          "type" => "streamable-http",
          "url" => "#{Settings.base_url()}/mcp",
          "headers" => [
            %{
              "name" => "Authorization",
              "description" => "Bearer <your gateway API key>.",
              "isRequired" => true,
              "isSecret" => true
            }
          ]
        }
      ],
      "_meta" => %{
        Settings.meta_key("pricing") => pricing(),
        Settings.meta_key("gateway") => %{
          "toolCount" => tool_count,
          "registryApi" => "#{Settings.base_url()}/v0.1/servers",
          "docs" => %{
            "llmsTxt" => "#{Settings.base_url()}/llms.txt",
            "agentTxt" => "#{Settings.base_url()}/agent.txt",
            "skillTxt" => "#{Settings.base_url()}/skill.txt"
          }
        }
      }
    }
  end

  @doc "The pricing block repeated wherever a price is stated, so it can never drift."
  def pricing do
    price = Settings.price_micro_usd()

    %{
      "pricePerCallMicroUsd" => price,
      "pricePerCallUsd" => Billing.format_usd(price),
      "currency" => "USD",
      "billedOn" => "each tools/call that reaches the upstream and returns a result",
      "freeOperations" => ["server/discover", "tools/list", "registry endpoints", "docs files"],
      "model" => "prepaid credits, drawn down per call"
    }
  end

  defp meta(%Server{} = server, opts) do
    base = %{
      Settings.meta_key("pricing") => pricing(),
      Settings.meta_key("provider") => provider(server),
      Settings.meta_key("catalog") => %{
        "slug" => server.slug,
        "keywords" => McpGateway.Catalog.keywords(server),
        "status" => server.status,
        "publishedAt" => server.published_at && DateTime.to_iso8601(server.published_at),
        "updatedAt" => server.updated_at && DateTime.to_iso8601(server.updated_at),
        "isLatest" => true,
        "docsUrl" => "#{Settings.base_url()}/docs/servers/#{server.slug}"
      }
    }

    case opts[:tool_count] do
      nil -> base
      count -> put_in(base, [Settings.meta_key("catalog"), "toolCount"], count)
    end
  end

  # What we publish about the upstream provider: the terms we verified and the obligations that
  # ride along with the data (attribution, rate limits). Never the upstream's credentials or
  # launch command.
  defp provider(%Server{compliance: compliance} = server) do
    %{
      "termsUrl" => compliance["terms_url"],
      "termsCheckedOn" => Date.to_iso8601(server.compliance_checked_on),
      "attribution" => compliance["attribution"],
      "rateLimit" => server.rate_limit,
      "upstreamDocsUrl" => compliance["api_docs_url"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
