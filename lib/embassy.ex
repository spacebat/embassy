defmodule Embassy do
  @moduledoc """
  Per-instance supervisor and public entry point for an Embassy
  reverse-proxy installation.

  Consumers add `{Embassy, name: ..., finch: ...}` to their application
  supervision tree. Plugs and helpers look up configuration by the
  given `:name` via `Embassy.Config.snapshot/1`.

  ## Required options

    * `:name` — atom; the instance name. Must be unique within the BEAM.
    * `:finch` — atom; the name of a running `Finch` instance owned by
      the consumer. Embassy never starts its own Finch.

  ## Optional options

    * `:upstreams` — keyword list of `name => transport`
      (`{:uds, path}` or `{:http, base_url}`) to health-check. When
      given, an `Embassy.Health.Monitor` is started for the instance.
      Default `[]` (no monitor).
    * `:health` — keyword list: `:interval` between probes in ms
      (default `5_000`) and probe `:timeout` in ms (default `1_000`).

  See `Embassy.Health`.

  ## Example

      children = [
        {Finch, name: MyApp.Finch},
        {Embassy, name: MyApp.Embassy, finch: MyApp.Finch}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use Supervisor

  @doc """
  Start an Embassy instance under a supervisor.

  See the module doc for required options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = fetch_required!(opts, :name)
    _finch = fetch_required!(opts, :finch)
    opts |> Keyword.get(:upstreams, []) |> validate_upstreams!()
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Child-spec for use in a consumer's supervision tree.

  The `:id` is derived from `:name` so multiple Embassy instances
  cohabit in the same tree without collision.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = fetch_required!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def registry_name(name), do: Module.concat(name, Registry)

  @doc false
  def task_supervisor_name(name), do: Module.concat(name, TaskSupervisor)

  @doc false
  def health_monitor_name(name), do: Module.concat(name, HealthMonitor)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    finch = Keyword.fetch!(opts, :finch)
    task_supervisor = task_supervisor_name(name)

    upstreams = Keyword.get(opts, :upstreams, [])

    snapshot = %{
      name: name,
      finch: finch,
      task_supervisor: task_supervisor,
      upstreams: upstreams,
      health: health_opts(Keyword.get(opts, :health, []))
    }

    children =
      [
        {Registry, keys: :unique, name: registry_name(name), meta: [config: snapshot]},
        {Task.Supervisor, name: task_supervisor}
      ] ++ health_monitor(snapshot)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp health_monitor(%{upstreams: []}), do: []
  defp health_monitor(snapshot), do: [{Embassy.Health.Monitor, snapshot}]

  # `:probe` is undocumented and exists for tests.
  defp health_opts(opts) do
    %{
      interval: Keyword.get(opts, :interval, 5_000),
      timeout: Keyword.get(opts, :timeout, 1_000),
      probe: Keyword.get(opts, :probe, &Embassy.Health.check/3)
    }
  end

  defp validate_upstreams!(upstreams) when is_list(upstreams) do
    Enum.each(upstreams, fn
      {name, {:uds, path}} when is_atom(name) and is_binary(path) -> :ok
      {name, {:http, base}} when is_atom(name) and is_binary(base) -> :ok
      other -> raise ArgumentError, "invalid :upstreams entry #{inspect(other)}"
    end)
  end

  defp validate_upstreams!(other),
    do: raise(ArgumentError, ":upstreams must be a keyword list, got #{inspect(other)}")

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "required option #{inspect(key)} is missing"
    end
  end
end
