defmodule McpGatewayWeb.HealthController do
  use McpGatewayWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{"status" => "ok", "version" => McpGateway.Settings.server_version()})
    )
  end
end
