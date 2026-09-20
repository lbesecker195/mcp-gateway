defmodule McpGatewayWeb.DocsController do
  @moduledoc """
  Serves the gateway's documentation surface. Every document is generated from the catalog by
  `McpGateway.Docs`, so these routes describe exactly what is routable at the moment of the
  request.

  All of it is free and unauthenticated: an agent has to be able to read the price and the
  connection instructions before it has a key.
  """

  use McpGatewayWeb, :controller

  alias McpGateway.Docs
  alias McpGateway.Landing
  alias McpGateway.Settings

  @plain "text/plain"
  @markdown "text/markdown"

  # The landing page is the only HTML here. It answers "what is an MCP gateway" for people and
  # search engines; agents are pointed at llms.txt and agent.txt from it.
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Landing.html())
  end

  def sitemap(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, Landing.sitemap_xml())
  end

  def robots(conn, _params), do: send_text(conn, Landing.robots_txt())

  def llms(conn, _params), do: send_text(conn, Docs.llms_txt())
  def llms_full(conn, _params), do: send_text(conn, Docs.llms_full_txt())
  def agent(conn, _params), do: send_text(conn, Docs.agent_txt())
  def skill(conn, _params), do: send_text(conn, Docs.skill_txt())

  def server_json(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Docs.server_json()))
  end

  def server_doc(conn, %{"slug" => slug}) do
    send_doc(conn, Docs.server_doc(slug), "server", slug)
  end

  def tool_doc(conn, %{"name" => name}) do
    send_doc(conn, Docs.tool_doc(name), "tool", name)
  end

  defp send_doc(conn, {:ok, markdown}, _kind, _id) do
    conn
    |> put_resp_content_type(@markdown)
    |> send_resp(200, markdown)
  end

  defp send_doc(conn, {:error, :not_found}, kind, id) do
    conn
    |> put_resp_content_type(@plain)
    |> send_resp(404, not_found_body(kind, id))
  end

  defp send_text(conn, body) do
    conn
    |> put_resp_content_type(@plain)
    |> send_resp(200, body)
  end

  defp not_found_body(kind, id) do
    """
    404 Not Found

    No routable #{kind} named "#{sanitize(id)}" is in this gateway's catalog. Either it never
    existed, or it has been delisted: an entry leaves the catalog as soon as its provider's terms
    stop allowing us to proxy it, and its documentation goes with it.

    What is routable right now: #{Settings.base_url()}/llms.txt
    """
  end

  # The identifier is echoed back to make the error actionable, so it is reduced to the character
  # set catalog slugs and tool names are allowed to use.
  defp sanitize(value) do
    value |> String.replace(~r/[^A-Za-z0-9_.-]/, "") |> String.slice(0, 64)
  end
end
