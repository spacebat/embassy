defmodule Embassy.Test.TelemetryCollector do
  @moduledoc false

  @doc """
  Attach a handler for the given event names. Returns a `{:ok, ref}`
  whose `ref` is also the handler-id (use it with `events/1` and
  `detach/1`). Auto-detaches when the calling test process exits via
  `ExUnit.Callbacks.on_exit/1`.
  """
  def attach(event_names) when is_list(event_names) do
    ref = make_ref()
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :telemetry.attach_many(
      ref,
      event_names,
      &__MODULE__.__handle__/4,
      agent
    )

    ExUnit.Callbacks.on_exit(fn ->
      :telemetry.detach(ref)
    end)

    {:ok, %{ref: ref, agent: agent}}
  end

  @doc """
  Return all events captured so far, in arrival order. Each element is
  `{event_name, measurements, metadata}`.
  """
  def events(%{agent: agent}) do
    agent |> Agent.get(& &1) |> Enum.reverse()
  end

  @doc false
  def __handle__(event_name, measurements, metadata, agent) do
    Agent.update(agent, &[{event_name, measurements, metadata} | &1])
  catch
    # The owning test exited (taking the agent with it) before on_exit
    # detached this handler; another async test's event is not ours.
    :exit, _ -> :ok
  end
end
