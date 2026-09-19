defmodule McpGateway.Settings do
  @moduledoc """
  Typed access to gateway configuration, so call sites don't repeat `Application.fetch_env!`.
  """

  @doc "Price of one successful tool call in integer micro-USD (100 = $0.0001)."
  def price_micro_usd, do: Application.fetch_env!(:mcp_gateway, :price_micro_usd)

  @doc "Reverse-DNS namespace for server names, e.g. `dev.mcpharbor.gateway/arxiv`."
  def registry_namespace, do: Application.fetch_env!(:mcp_gateway, :registry_namespace)

  @doc "A `_meta` key under our reverse-DNS namespace, e.g. `dev.mcpharbor.gateway/pricing`."
  def meta_key(name), do: "#{Application.fetch_env!(:mcp_gateway, :meta_namespace)}/#{name}"

  @doc "Base URL of *this* deployment, without a trailing slash. In dev this is localhost."
  def base_url, do: String.trim_trailing(McpGatewayWeb.Endpoint.url(), "/")

  @doc """
  The gateway's canonical public URL, without a trailing slash.

  Use this for anything that leaves the building — documents published to the official MCP
  Registry, links an external agent will follow — so a publish from a laptop cannot advertise
  `http://localhost`.
  """
  def canonical_base_url do
    :mcp_gateway
    |> Application.fetch_env!(:canonical_base_url)
    |> String.trim_trailing("/")
  end

  def server_version, do: :mcp_gateway |> Application.spec(:vsn) |> to_string()

  def get(key), do: Application.fetch_env!(:mcp_gateway, key)
end
