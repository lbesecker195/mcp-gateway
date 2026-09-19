defmodule McpGateway.Catalog.Tool do
  @moduledoc """
  A tool as the gateway exposes it. `name` is namespaced by the upstream's slug
  (`slug__upstream_name`) so tools from different servers can never collide; `upstream_name`
  is what we send to the upstream.
  """
  use Ecto.Schema

  alias McpGateway.Settings

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  # Some MCP clients accept only [A-Za-z0-9_-] and at most 64 characters in tool names.
  @name_format ~r/^[A-Za-z0-9_-]{1,64}$/

  schema "tools" do
    field :name, :string
    field :upstream_name, :string
    field :title, :string
    field :description, :string
    field :input_schema, :map
    field :output_schema, :map
    field :annotations, :map

    belongs_to :server, McpGateway.Catalog.Server

    timestamps()
  end

  @doc """
  Builds insert attributes from a tool definition as returned by an upstream `tools/list`.
  """
  def build_attrs(slug, %{"name" => upstream_name} = tool) when is_binary(upstream_name) do
    name = slug <> "__" <> String.replace(upstream_name, ~r/[^A-Za-z0-9_-]/, "_")

    if Regex.match?(@name_format, name) do
      {:ok,
       %{
         name: name,
         upstream_name: upstream_name,
         title: tool["title"],
         description: tool["description"],
         input_schema: tool["inputSchema"] || %{"type" => "object"},
         output_schema: tool["outputSchema"],
         annotations: tool["annotations"]
       }}
    else
      {:error, {:invalid_tool_name, name}}
    end
  end

  def build_attrs(_slug, _tool), do: {:error, :invalid_tool}

  @doc "The tool as an MCP `Tool` object, with the per-call price in `_meta`."
  def to_mcp(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description || "",
      "inputSchema" => tool.input_schema,
      "_meta" => %{
        Settings.meta_key("pricing") => %{
          "pricePerCallMicroUsd" => Settings.price_micro_usd(),
          "currency" => "USD"
        }
      }
    }
    |> put_present("title", tool.title)
    |> put_present("outputSchema", tool.output_schema)
    |> put_present("annotations", tool.annotations)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
