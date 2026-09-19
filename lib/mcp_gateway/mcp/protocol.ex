defmodule McpGateway.MCP.Protocol do
  @moduledoc """
  Constants and JSON-RPC helpers for the MCP wire protocol.

  Two eras of MCP exist and the gateway speaks both, on both sides:

    * **modern** (revision 2026-07-28 and later): stateless. Every request carries its protocol
      version and client capabilities in `params._meta`, and there is no `initialize` handshake.
    * **legacy** (2025-11-25 and earlier Streamable HTTP revisions): a connection starts with an
      `initialize` handshake.

  Spec: https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
  """

  @modern_versions ["2026-07-28"]
  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26"]

  @meta_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_info "io.modelcontextprotocol/clientInfo"
  @meta_client_caps "io.modelcontextprotocol/clientCapabilities"
  @meta_server_info "io.modelcontextprotocol/serverInfo"

  def modern_versions, do: @modern_versions
  def legacy_versions, do: @legacy_versions
  def supported_versions, do: @modern_versions ++ @legacy_versions

  def meta_version_key, do: @meta_version
  def meta_client_info_key, do: @meta_client_info
  def meta_client_caps_key, do: @meta_client_caps
  def meta_server_info_key, do: @meta_server_info

  # JSON-RPC 2.0 and MCP error codes.
  def parse_error, do: -32700
  def invalid_request, do: -32600
  def method_not_found, do: -32601
  def invalid_params, do: -32602
  def internal_error, do: -32603
  def header_mismatch, do: -32020
  def missing_capability, do: -32021
  def unsupported_version, do: -32022

  # Gateway errors. Positive codes sit outside the range the spec reserves; they mirror the
  # HTTP status the same failure is returned with.
  def unauthorized, do: 401
  def payment_required, do: 402
  def rate_limited, do: 429

  def result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  def error(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  @doc "The `_meta` the gateway attaches to modern requests it sends to upstream servers."
  def client_meta do
    %{
      @meta_version => hd(@modern_versions),
      @meta_client_info => %{
        "name" => "mcp-gateway",
        "version" => McpGateway.Settings.server_version()
      },
      # The gateway offers no sampling, elicitation or roots to upstreams.
      @meta_client_caps => %{}
    }
  end

  ## Header value encoding (Streamable HTTP `Mcp-Name` / `Mcp-Param-*`)

  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="

  @doc "Encodes a value for an HTTP header, using the spec's Base64 sentinel when it isn't plain ASCII."
  def encode_header_value(value) when is_binary(value) do
    if safe_header_value?(value) do
      value
    else
      @sentinel_prefix <> Base.encode64(value) <> @sentinel_suffix
    end
  end

  @doc "Decodes a header value that may use the Base64 sentinel. `:error` if malformed."
  def decode_header_value(@sentinel_prefix <> rest) do
    if String.ends_with?(rest, @sentinel_suffix) do
      rest
      |> binary_part(0, byte_size(rest) - byte_size(@sentinel_suffix))
      |> Base.decode64()
    else
      {:ok, @sentinel_prefix <> rest}
    end
  end

  def decode_header_value(value) when is_binary(value), do: {:ok, value}

  defp safe_header_value?(value) do
    value == String.trim(value) and
      not (String.starts_with?(value, @sentinel_prefix) and
             String.ends_with?(value, @sentinel_suffix)) and
      String.match?(value, ~r/\A[\x20-\x7E\t]*\z/)
  end
end
