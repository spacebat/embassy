defmodule Embassy.Health.Monitor do
  @moduledoc """
  Per-instance upstream prober. Started by `Embassy` only when
  `:upstreams` is non-empty; see `Embassy.Health`.

  Probes run as tasks under the instance `Task.Supervisor`, so a hung
  upstream never blocks the monitor or `Embassy.Health.status/1`, and an
  upstream whose probe is still running is not probed again. A probe
  still running after the `:timeout` is killed and recorded as
  `{:down, :timeout}`; Finch's own timeouts don't cover connecting.
  """

  use GenServer
  require Logger

  @doc false
  def start_link(snapshot) do
    GenServer.start_link(__MODULE__, snapshot, name: Embassy.health_monitor_name(snapshot.name))
  end

  @impl true
  def init(snapshot) do
    status = Map.new(snapshot.upstreams, fn {name, _} -> {name, :unknown} end)
    {:ok, %{snapshot: snapshot, status: status, in_flight: %{}}, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  def handle_info({ref, result}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, record(state, ref, to_status(result))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    {:noreply, record(state, ref, {:down, {:probe_exit, reason}})}
  end

  def handle_info({:probe_deadline, ref}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    {_name, _start, pid} = Map.fetch!(in_flight, ref)
    Process.demonitor(ref, [:flush])
    Task.Supervisor.terminate_child(state.snapshot.task_supervisor, pid)
    {:noreply, record(state, ref, {:down, :timeout})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp tick(%{snapshot: snapshot} = state) do
    busy = state.in_flight |> Map.values() |> MapSet.new(fn {name, _, _} -> name end)

    in_flight =
      snapshot.upstreams
      |> Enum.reject(fn {name, _} -> MapSet.member?(busy, name) end)
      |> Enum.reduce(state.in_flight, fn {name, transport}, acc ->
        task = start_probe(snapshot, transport)
        Process.send_after(self(), {:probe_deadline, task.ref}, snapshot.health.timeout)
        Map.put(acc, task.ref, {name, System.monotonic_time(), task.pid})
      end)

    Process.send_after(self(), :tick, snapshot.health.interval)
    %{state | in_flight: in_flight}
  end

  defp start_probe(snapshot, transport) do
    %{name: instance, health: %{probe: probe, timeout: timeout}} = snapshot

    Task.Supervisor.async_nolink(snapshot.task_supervisor, fn ->
      probe.(instance, transport, timeout: timeout)
    end)
  end

  defp to_status(:ok), do: :up
  defp to_status({:error, reason}), do: {:down, reason}

  defp record(state, ref, new) do
    {{name, start, _pid}, in_flight} = Map.pop!(state.in_flight, ref)
    instance = state.snapshot.name

    :telemetry.execute(
      [:embassy, :upstream, :check],
      %{duration: System.monotonic_time() - start, up: if(new == :up, do: 1, else: 0)},
      %{instance: instance, upstream: name, result: new}
    )

    log_transition(instance, name, Map.fetch!(state.status, name), new)
    %{state | in_flight: in_flight, status: Map.put(state.status, name, new)}
  end

  defp log_transition(instance, name, old, {:down, reason}) when not is_tuple(old) do
    Logger.warning("Embassy #{inspect(instance)} upstream #{name} down: #{inspect(reason)}")
  end

  defp log_transition(instance, name, {:down, _}, :up) do
    Logger.info("Embassy #{inspect(instance)} upstream #{name} up")
  end

  defp log_transition(_instance, _name, _old, _new), do: :ok
end
