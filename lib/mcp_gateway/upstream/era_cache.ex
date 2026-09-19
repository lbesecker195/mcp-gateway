defmodule McpGateway.Upstream.EraCache do
  @moduledoc """
  Remembers which MCP era an HTTP upstream speaks (and any legacy session id), so we probe once
  per upstream and not once per call. The spec says clients SHOULD cache the era of a server and
  re-probe only if the cached assumption later fails.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Returns `:modern`, `{:legacy, version, session_id | nil}`, or `nil` when unknown."
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  def put(key, value), do: :ets.insert(@table, {key, value})
  def delete(key), do: :ets.delete(@table, key)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
