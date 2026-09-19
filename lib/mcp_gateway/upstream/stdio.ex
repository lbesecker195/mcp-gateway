defmodule McpGateway.Upstream.Stdio do
  @moduledoc """
  One process per stdio upstream: it owns the subprocess and multiplexes requests over its
  stdin/stdout (newline-delimited JSON-RPC).

  Startup follows the spec's backward-compatibility rule for stdio: send `server/discover`
  first. A `DiscoverResult` means a modern server; a recognized modern error means a modern
  server that rejects our version; anything else, or silence past the probe timeout, means a
  legacy server and we fall back to the `initialize` handshake.

  The subprocess is launched through `env -i`, so it inherits none of the gateway's
  environment (database URL, secret key base, other upstreams' keys). It gets only PATH, an
  isolated HOME, and the variables its catalog entry declares.

  The process is started on first use and stops after an idle period. MCP is stateless in the
  modern era, so a restart loses nothing but in-flight requests, which callers see as
  `{:error, :unavailable}`.
  """
  use GenServer, restart: :temporary

  require Logger

  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Settings

  @registry McpGateway.Upstream.Registry
  @supervisor McpGateway.Upstream.Supervisor
  @max_line_bytes 16 * 1024 * 1024
  @max_restarts 3
  @env_name ~r/\A[A-Z_][A-Z0-9_]*\z/
  @reserved_env ~w(PATH HOME LANG)

  ## Client API

  @spec request(map(), String.t(), map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def request(server, method, params, timeout) do
    with {:ok, pid} <- ensure_started(server) do
      GenServer.call(pid, {:request, method, params, timeout}, timeout + 5_000)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  def start_link(server) do
    GenServer.start_link(__MODULE__, server, name: via(server))
  end

  defp ensure_started(server) do
    case Registry.lookup(@registry, key(server)) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, server}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:start_failed, reason}}
        end
    end
  end

  # A changed upstream config (new pinned version) gets a fresh process; the old one idles out.
  defp key(server), do: {server.slug, :erlang.phash2(server.upstream)}
  defp via(server), do: {:via, Registry, {@registry, key(server)}}

  ## Server

  @impl true
  def init(server) do
    Process.flag(:trap_exit, true)

    case open_port(server) do
      {:ok, port} ->
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        state = %{
          server: server,
          port: port,
          os_pid: os_pid,
          buf: "",
          # :handshake until an era is settled, then :ready. While in :handshake, `probe` tracks
          # the server/discover request and `init` the fallback initialize request.
          phase: :handshake,
          probe: :pending,
          init: :not_sent,
          init_error: nil,
          era: nil,
          next_id: 1,
          pending: %{},
          ids: %{},
          idle_ref: nil,
          restarts: 0
        }

        {:ok, state, {:continue, :probe}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:probe, state) do
    send_msg(state.port, %{
      "jsonrpc" => "2.0",
      "id" => "gw-probe",
      "method" => "server/discover",
      "params" => %{"_meta" => P.client_meta()}
    })

    Process.send_after(self(), :probe_timeout, Settings.get(:upstream_probe_timeout_ms))
    Process.send_after(self(), :startup_timeout, Settings.get(:upstream_startup_timeout_ms))
    {:noreply, touch_idle(state)}
  end

  @impl true
  def handle_call({:request, method, params, timeout}, from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:request_timeout, token}, timeout)
    entry = %{from: from, method: method, params: params, id: nil, timer: timer}
    state = %{state | pending: Map.put(state.pending, token, entry)} |> touch_idle()

    # Until the handshake finishes, requests wait in `pending` with no id assigned.
    state = if state.phase == :ready, do: dispatch(state, token), else: state
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(state.buf <> line, %{state | buf: ""})
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    buf = state.buf <> chunk

    if byte_size(buf) > @max_line_bytes do
      Logger.warning(
        "upstream #{state.server.slug}: output line over #{@max_line_bytes} bytes, stopping"
      )

      {:stop, :normal, fail_all(state, {:error, :unavailable})}
    else
      {:noreply, %{state | buf: buf}}
    end
  end

  # The subprocess exited. In-flight requests are lost, and the spec says to restart the server;
  # the protocol is stateless, so a fresh process can serve the next request. Restarting in place
  # also avoids a stale registry entry being handed to the next caller.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("upstream #{state.server.slug}: exited with status #{status}")
    state = fail_all(%{state | port: nil, os_pid: nil}, {:error, :unavailable})

    if state.restarts >= @max_restarts do
      Logger.error("upstream #{state.server.slug}: exited #{state.restarts + 1} times, giving up")
      {:stop, :normal, state}
    else
      restart_port(state)
    end
  end

  # No answer to server/discover yet. A legacy server may be ignoring it, so send `initialize`
  # as well, but keep listening: a slow-starting modern server (npx fetching a package) answers
  # the probe late, and that answer still decides the era.
  def handle_info(:probe_timeout, %{phase: :handshake} = state), do: maybe_send_initialize(state)
  def handle_info(:probe_timeout, state), do: {:noreply, state}

  def handle_info(:startup_timeout, %{phase: :ready} = state), do: {:noreply, state}

  def handle_info(:startup_timeout, state) do
    reason =
      if state.init_error, do: {:initialize_failed, state.init_error}, else: :handshake_timeout

    fail_start(state, reason)
  end

  def handle_info({:request_timeout, token}, state) do
    case Map.pop(state.pending, token) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        GenServer.reply(entry.from, {:error, :timeout})
        state = %{state | pending: pending}

        if entry.id do
          send_msg(state.port, %{
            "jsonrpc" => "2.0",
            "method" => "notifications/cancelled",
            "params" => %{"requestId" => entry.id, "reason" => "gateway timeout"}
          })

          {:noreply, %{state | ids: Map.delete(state.ids, entry.id)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(:idle, state) do
    if map_size(state.pending) == 0,
      do: {:stop, :normal, state},
      else: {:noreply, touch_idle(state)}
  end

  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port, os_pid: os_pid}) when not is_nil(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    # Closing stdin is the graceful shutdown signal; follow up if the server ignores it.
    if os_pid do
      Task.start(fn ->
        Process.sleep(2_000)
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Handshake

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method}} when is_binary(method) ->
        answer_server_request(state, id, method)

      {:ok, %{"id" => id} = msg} ->
        handle_response(state, id, msg)

      {:ok, _notification} ->
        {:noreply, state}

      {:error, _} ->
        # Some launchers print banners to stdout. The spec forbids it, so ignore rather than fail.
        Logger.debug("upstream #{state.server.slug}: ignoring non-JSON stdout line")
        {:noreply, state}
    end
  end

  # The era is already settled; a late handshake reply is ignored.
  defp handle_response(%{phase: :ready} = state, id, _msg) when id in ["gw-probe", "gw-init"],
    do: {:noreply, state}

  defp handle_response(state, "gw-probe", msg) do
    case msg do
      %{"result" => %{"supportedVersions" => versions}} when is_list(versions) ->
        cond do
          Enum.any?(versions, &(&1 in P.modern_versions())) -> ready(state, :modern)
          Enum.any?(versions, &(&1 in P.legacy_versions())) -> probe_says_legacy(state)
          true -> fail_start(state, {:unsupported_versions, versions})
        end

      %{"error" => %{"code" => -32022, "data" => %{"supported" => supported}}}
      when is_list(supported) ->
        # A modern server that doesn't speak our version; use legacy only if it offers one.
        if Enum.any?(supported, &(&1 in P.legacy_versions())),
          do: probe_says_legacy(state),
          else: fail_start(state, {:unsupported_versions, supported})

      %{"error" => %{"code" => code}} when code in [-32020, -32021] ->
        # A recognized modern error: the server is modern but rejected our probe.
        fail_start(state, {:modern_error, code})

      _ ->
        # Any other error is a legacy server answering an unknown pre-initialize method. The
        # spec forbids keying this fallback to one error code.
        probe_says_legacy(state)
    end
  end

  defp handle_response(state, "gw-init", msg) do
    case msg do
      %{"result" => %{"protocolVersion" => version}} ->
        send_msg(state.port, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
        ready(state, {:legacy, version})

      _ ->
        # `initialize` failed. Give up only once the probe has also ruled out a modern server:
        # a modern server rejects `initialize` as an unknown method, and its `server/discover`
        # answer may still be on its way.
        state = %{state | init: :failed, init_error: msg["error"]}

        if state.probe == :legacy,
          do: fail_start(state, {:initialize_failed, state.init_error}),
          else: {:noreply, state}
    end
  end

  defp handle_response(state, id, msg) when is_integer(id) do
    case Map.pop(state.ids, id) do
      {nil, _} ->
        # Late response to a request that already timed out.
        {:noreply, state}

      {token, ids} ->
        {entry, pending} = Map.pop(state.pending, token)
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, decode_reply(msg))
        {:noreply, %{state | ids: ids, pending: pending}}
    end
  end

  # An id we don't recognize (including a handshake reply arriving after a restart).
  defp handle_response(state, _id, _msg), do: {:noreply, state}

  # Re-spawns the subprocess and redoes the handshake from scratch.
  defp restart_port(state) do
    case open_port(state.server) do
      {:ok, port} ->
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        state = %{
          state
          | port: port,
            os_pid: os_pid,
            buf: "",
            phase: :handshake,
            probe: :pending,
            init: :not_sent,
            init_error: nil,
            era: nil,
            restarts: state.restarts + 1
        }

        {:noreply, state, {:continue, :probe}}

      {:error, reason} ->
        Logger.error("upstream #{state.server.slug}: could not restart: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  # The probe answered and ruled out the modern era.
  defp probe_says_legacy(state), do: maybe_send_initialize(%{state | probe: :legacy})

  defp maybe_send_initialize(state) do
    cond do
      state.init == :failed and state.probe == :legacy ->
        fail_start(state, {:initialize_failed, state.init_error})

      state.init == :not_sent ->
        send_initialize(state)

      true ->
        {:noreply, state}
    end
  end

  defp send_initialize(state) do
    send_msg(state.port, %{
      "jsonrpc" => "2.0",
      "id" => "gw-init",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => hd(P.legacy_versions()),
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mcp-gateway", "version" => Settings.server_version()}
      }
    })

    {:noreply, %{state | init: :sent}}
  end

  defp ready(state, era) do
    state = %{state | phase: :ready, era: era}

    state =
      Enum.reduce(state.pending, state, fn
        {token, %{id: nil}}, acc -> dispatch(acc, token)
        _, acc -> acc
      end)

    {:noreply, state}
  end

  defp fail_start(state, reason) do
    Logger.warning("upstream #{state.server.slug}: handshake failed: #{inspect(reason)}")
    {:stop, :normal, fail_all(state, {:error, {:start_failed, reason}})}
  end

  # Legacy servers may send requests to the client. We declared no capabilities, so answer
  # ping and reject everything else instead of leaving the server waiting.
  defp answer_server_request(state, id, "ping") do
    send_msg(state.port, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
    {:noreply, state}
  end

  defp answer_server_request(state, id, _method) do
    send_msg(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => P.method_not_found(), "message" => "Not supported by the gateway"}
    })

    {:noreply, state}
  end

  ## Requests

  defp dispatch(state, token) do
    entry = Map.fetch!(state.pending, token)
    id = state.next_id

    params =
      case state.era do
        :modern -> Map.put(entry.params, "_meta", P.client_meta())
        {:legacy, _} -> entry.params
      end

    send_msg(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => entry.method,
      "params" => params
    })

    %{
      state
      | next_id: id + 1,
        pending: Map.put(state.pending, token, %{entry | id: id}),
        ids: Map.put(state.ids, id, token)
    }
  end

  defp decode_reply(%{"result" => result}) when is_map(result), do: {:ok, result}

  defp decode_reply(%{"error" => %{"code" => code, "message" => message} = error}),
    do: {:error, {:rpc_error, code, message, error["data"]}}

  defp decode_reply(_), do: {:error, :protocol}

  defp fail_all(state, reply) do
    Enum.each(state.pending, fn {_token, entry} ->
      Process.cancel_timer(entry.timer)
      GenServer.reply(entry.from, reply)
    end)

    %{state | pending: %{}, ids: %{}}
  end

  defp send_msg(nil, _msg), do: :ok
  defp send_msg(port, msg), do: Port.command(port, [Jason.encode!(msg), "\n"])

  defp touch_idle(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)

    %{
      state
      | idle_ref: Process.send_after(self(), :idle, Settings.get(:upstream_idle_timeout_ms))
    }
  end

  ## Launching

  defp open_port(%{upstream: upstream}) do
    command = upstream["command"]

    with :ok <- check_allowed(command),
         exe when is_binary(exe) <-
           System.find_executable(command) || {:error, :command_not_found},
         {:ok, env} <- build_env(upstream["env"] || %{}),
         env_exe when is_binary(env_exe) <-
           System.find_executable("env") || {:error, :env_not_found} do
      args = ["-i" | env] ++ [exe | List.wrap(upstream["args"])]

      port =
        Port.open({:spawn_executable, env_exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:line, 65_536},
          {:args, args}
        ])

      {:ok, port}
    end
  end

  defp check_allowed(command) when is_binary(command) do
    if command in Settings.get(:allowed_upstream_commands),
      do: :ok,
      else: {:error, {:command_not_allowed, command}}
  end

  defp check_allowed(_), do: {:error, :missing_command}

  defp build_env(declared) do
    home = upstream_home()
    path = System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin")
    base = ["PATH=" <> path, "HOME=" <> home, "LANG=C.UTF-8"]

    Enum.reduce_while(declared, {:ok, base}, fn {name, value}, {:ok, acc} ->
      cond do
        not Regex.match?(@env_name, name) or name in @reserved_env ->
          {:halt, {:error, {:invalid_env_name, name}}}

        is_binary(value) ->
          {:cont, {:ok, acc ++ ["#{name}=#{value}"]}}

        match?(%{"from_env" => _}, value) ->
          source = value["from_env"]

          case System.get_env(source) do
            nil -> {:halt, {:error, {:missing_env, source}}}
            resolved -> {:cont, {:ok, acc ++ ["#{name}=#{resolved}"]}}
          end

        true ->
          {:halt, {:error, {:invalid_env_value, name}}}
      end
    end)
  end

  defp upstream_home do
    home =
      Settings.get(:upstream_home) || Path.join(System.tmp_dir!(), "mcp_gateway_upstream_home")

    File.mkdir_p!(home)
    home
  end
end
