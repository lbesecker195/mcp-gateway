defmodule McpGatewayWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves `Authorization: Bearer <key>` to the account that will be billed.

  The key is only ever read from the header. A key in a query string would end up in access
  logs, proxy logs and `Referer` headers, so that form is not accepted at all. Nothing here
  logs the key or any part of it, and a failure says only that the key is missing or invalid -
  never which of the two, and never whether an account exists.

  On success the account is in `conn.assigns.account`. On failure the connection is halted with
  HTTP 401 and a JSON-RPC error body, so an MCP client gets something it can parse.
  """

  @behaviour Plug

  import Plug.Conn

  alias McpGateway.Billing
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Settings

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, key} <- bearer_token(conn),
         {:ok, account} <- Billing.authenticate(key) do
      assign(conn, :account, account)
    else
      _ -> unauthorized(conn)
    end
  end

  # The scheme is case-insensitive per RFC 9110; the credential itself is not.
  defp bearer_token(conn) do
    with [value] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(value, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    body =
      P.error(
        request_id(conn),
        P.unauthorized(),
        "Missing or invalid API key. Send `Authorization: Bearer <your gateway API key>`.",
        %{"docsUrl" => "#{Settings.base_url()}/agent.txt"}
      )

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="mcp-gateway"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
    |> halt()
  end

  # Echo the request id when the body gave us one, so a client can match the error to its call.
  defp request_id(conn) do
    case conn.body_params do
      %{"id" => id} when is_binary(id) or is_integer(id) -> id
      _ -> nil
    end
  end
end
