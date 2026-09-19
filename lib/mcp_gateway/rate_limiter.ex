defmodule McpGateway.RateLimiter do
  @moduledoc """
  Fixed-window counters in ETS. Used per account (to bound abuse) and per upstream (to stay
  inside each provider's free-tier quota, which is part of what makes a listing compliant).

  Counters are node-local. Running several gateway nodes multiplies the effective limit, so
  set upstream limits with the node count in mind.
  """
  use GenServer

  @table __MODULE__
  @sweep_every_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Counts one event against `bucket`. Returns `:ok` while under `limit` events per `window_ms`,
  otherwise `{:error, :rate_limited, retry_after_ms}`.
  """
  def check(bucket, limit, window_ms, now_ms \\ System.system_time(:millisecond))
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    window = div(now_ms, window_ms)
    window_end = (window + 1) * window_ms
    key = {bucket, window}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, window_end})

    if count <= limit, do: :ok, else: {:error, :rate_limited, window_end - now_ms}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
end
