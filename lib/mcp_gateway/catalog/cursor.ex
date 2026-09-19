defmodule McpGateway.Catalog.Cursor do
  @moduledoc """
  Opaque pagination cursors. Clients must treat them as opaque strings; internally a cursor is
  the last key returned, base64url-encoded.
  """

  def encode(key) when is_binary(key), do: Base.url_encode64(key, padding: false)

  @doc "Decodes a cursor; `nil` and `\"\"` mean \"start from the beginning\"."
  def decode(nil), do: {:ok, nil}
  def decode(""), do: {:ok, nil}

  def decode(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_cursor}
    end
  end

  def decode(_), do: {:error, :invalid_cursor}
end
