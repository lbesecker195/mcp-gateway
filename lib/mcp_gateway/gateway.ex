defmodule McpGateway.Gateway do
  @moduledoc """
  The metered path: one tool call, from catalog lookup to upstream result.

  This is where the product's integrity lives, so the order of the steps is fixed:

    1. Resolve the tool through `McpGateway.Catalog`, which only ever returns tools on
       compliance-allowed, freshly checked, active servers. A tool we may not proxy is reported
       as `:unknown_tool`: clients never learn that a non-compliant server exists.
    2. Account rate limit.
    3. Upstream rate limit, if the catalog entry declares one. Checked *before* the charge so a
       caller is never billed for our own quota management.
    4. Charge. This is the fail-closed step: if the balance can't cover the call we return
       `{:error, :insufficient_funds}` and the upstream is never contacted.
    5. Call the upstream, and refund if it failed.

  Money is integer micro-USD throughout; the price of one call is
  `McpGateway.Settings.price_micro_usd/0`.

  Discovery (`describe/0`, `list_tools/1`) is free and never touches the ledger.
  """

  require Logger

  alias McpGateway.Billing
  alias McpGateway.Catalog
  alias McpGateway.Catalog.Tool
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.RateLimiter
  alias McpGateway.RegistryJSON
  alias McpGateway.Settings
  alias McpGateway.Upstream

  @typedoc "An MCP `tools/call` result, exactly as the upstream returned it."
  @type result :: map()

  @typedoc "Our id for one billable call. It is the ledger's idempotency key and goes back to the caller."
  @type call_id :: String.t()

  @typedoc """
  Why a call did not produce a result.

    * `:unknown_tool` - not in the catalog, or not servable
    * `{:rate_limited, retry_ms}` - the account's own limit
    * `{:upstream_busy, retry_ms}` - the upstream's free-tier quota
    * `:insufficient_funds` - nothing was charged and the upstream was not contacted
    * anything else - an upstream failure, already refunded (see `McpGateway.Upstream`)
  """
  @type reason ::
          :unknown_tool
          | :insufficient_funds
          | {:rate_limited, non_neg_integer()}
          | {:upstream_busy, non_neg_integer()}
          | term()

  @doc """
  Calls one catalog tool for `account` and bills it.

  `opts[:scope]` narrows the lookup to a single server slug, which is what `POST /mcp/:slug`
  passes.

  Returns `{:ok, result, call_id}` on success. `call_id` identifies the ledger entry and is
  meant to be echoed to the caller (we put it in the response `_meta`) so a support question
  about a charge can be answered from one id.
  """
  @spec call_tool(struct(), String.t(), map(), keyword()) ::
          {:ok, result(), call_id()} | {:error, reason()}
  def call_tool(account, tool_name, arguments, opts \\ [])
      when is_binary(tool_name) and is_map(arguments) do
    started = System.monotonic_time()

    case Catalog.fetch_tool(tool_name, scope: opts[:scope]) do
      {:ok, tool, server} -> metered(account, tool, server, arguments, started)
      {:error, :unknown_tool} -> {:error, :unknown_tool}
    end
  end

  @doc """
  One page of the catalog rendered as MCP `Tool` objects. Free.

  Options are passed straight to `McpGateway.Catalog.list_tools/1`: `:scope` (a server slug)
  and `:cursor`. Ordering is by tool name, so paging is deterministic.
  """
  @spec list_tools(keyword()) :: {:ok, [map()], String.t() | nil} | {:error, :invalid_cursor}
  def list_tools(opts \\ []) do
    case Catalog.list_tools(opts) do
      {:ok, %{tools: tools, next_cursor: next_cursor}} ->
        {:ok, Enum.map(tools, &Tool.to_mcp/1), next_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The `server/discover` result: what we speak, what we can do, and what it costs.

  `resultType` is part of `DiscoverResult` itself, so it is present whichever era the client
  used to ask.
  """
  @spec describe() :: map()
  def describe do
    %{
      "resultType" => "complete",
      "supportedVersions" => P.supported_versions(),
      "capabilities" => %{"tools" => %{}},
      "instructions" => instructions(),
      "_meta" => %{
        P.meta_server_info_key() => server_info(),
        Settings.meta_key("pricing") => RegistryJSON.pricing()
      }
    }
  end

  @doc "Name and version we report as `serverInfo`."
  @spec server_info() :: map()
  def server_info do
    %{"name" => "mcp-gateway", "version" => Settings.server_version()}
  end

  @doc "Natural-language guidance for models, repeated in `initialize` for legacy clients."
  @spec instructions() :: String.t()
  def instructions do
    base = Settings.base_url()
    price = Settings.price_micro_usd()

    "A metered gateway in front of many free and freemium APIs, each reached through its own " <>
      "MCP server. Authenticate with `Authorization: Bearer <your gateway API key>`. " <>
      "Each tools/call costs #{price} micro-USD ($#{Billing.format_usd(price)}) and is drawn " <>
      "from a prepaid balance; server/discover and tools/list are free. Tool names are " <>
      "`<server>__<tool>` - POST to #{base}/mcp for every tool, or #{base}/mcp/<server> for " <>
      "one upstream. The catalog and per-tool docs live at #{base}/llms.txt and #{base}/agent.txt."
  end

  @doc """
  A one-word tag for an upstream failure, safe to show a client.

  Deliberately coarse: the underlying reason can carry an upstream's launch command or the name
  of an environment variable, and none of that belongs in a response, a log line or the ledger.
  """
  @spec failure_kind(term()) :: String.t()
  def failure_kind(:timeout), do: "timeout"
  def failure_kind(:unavailable), do: "unavailable"
  def failure_kind(:protocol), do: "protocol"
  def failure_kind({:start_failed, _why}), do: "start_failed"
  def failure_kind({:http_status, _status}), do: "http_status"
  def failure_kind({:rpc_error, _code, _message, _data}), do: "rpc_error"
  def failure_kind(_other), do: "error"

  ## The pipeline

  defp metered(account, tool, server, arguments, started) do
    with :ok <- account_limit(account),
         :ok <- upstream_limit(server),
         {:ok, call_id} <- charge(account, tool, server) do
      invoke(account, tool, server, arguments, call_id, started)
    else
      {:error, reason} ->
        stop(server, tool, outcome(reason), 0, started)
        {:error, reason}
    end
  end

  defp account_limit(account) do
    {limit, window_ms} = Settings.get(:account_rate_limit)

    case RateLimiter.check({:account, account.id}, limit, window_ms) do
      :ok -> :ok
      {:error, :rate_limited, retry_ms} -> {:error, {:rate_limited, retry_ms}}
    end
  end

  # Staying inside a provider's free-tier quota is part of what makes an entry compliant, so the
  # limit is enforced here rather than left to the upstream to reject.
  defp upstream_limit(%{rate_limit: %{"requests" => n, "window_ms" => window_ms}} = server)
       when is_integer(n) and n > 0 and is_integer(window_ms) and window_ms > 0 do
    case RateLimiter.check({:upstream, server.slug}, n, window_ms) do
      :ok -> :ok
      {:error, :rate_limited, retry_ms} -> {:error, {:upstream_busy, retry_ms}}
    end
  end

  defp upstream_limit(_server), do: :ok

  defp charge(account, tool, server) do
    call_id = Ecto.UUID.generate()

    metadata = %{
      "tool" => tool.name,
      "server" => server.slug,
      "upstream_tool" => tool.upstream_name
    }

    case Billing.charge(account.id, call_id, Settings.price_micro_usd(), metadata) do
      {:ok, _entry} -> {:ok, call_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke(account, tool, server, arguments, call_id, started) do
    case Upstream.call_tool(server, tool.upstream_name, arguments) do
      {:ok, result} ->
        # A result with `isError` is kept charged on purpose. The upstream reached the provider,
        # did the work and came back with an actionable message the model can correct against;
        # that is the service we sell. Only transport and protocol failures, below, are refunded.
        stop(server, tool, result_outcome(result), Settings.price_micro_usd(), started)
        {:ok, result, call_id}

      {:error, reason} ->
        refund(account, tool, server, call_id, reason)
        stop(server, tool, :refunded, 0, started)
        {:error, reason}
    end
  end

  defp refund(account, tool, server, call_id, reason) do
    metadata = %{
      "tool" => tool.name,
      "server" => server.slug,
      "reason" => failure_kind(reason)
    }

    case Billing.refund(account.id, call_id, metadata) do
      {:ok, _entry} ->
        :ok

      {:error, why} ->
        # The charge stands until this is reconciled, so it must be loud.
        Logger.error("gateway: refund of call #{call_id} failed: #{inspect(why)}")
        :ok
    end
  end

  ## Telemetry

  defp stop(server, tool, outcome, charged_micro_usd, started) do
    :telemetry.execute(
      [:mcp_gateway, :tool_call, :stop],
      %{duration: System.monotonic_time() - started, charged_micro_usd: charged_micro_usd},
      %{slug: server.slug, tool: tool.name, outcome: outcome}
    )
  end

  defp result_outcome(%{"isError" => true}), do: :tool_error
  defp result_outcome(_result), do: :ok

  defp outcome({:rate_limited, _ms}), do: :rate_limited
  defp outcome({:upstream_busy, _ms}), do: :upstream_busy
  defp outcome(:insufficient_funds), do: :insufficient_funds
  defp outcome(_other), do: :error
end
