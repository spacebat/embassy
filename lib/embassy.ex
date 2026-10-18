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
      the consumer. All proxying goes through it. Embassy starts no
      Finch of its own for proxying; the only Finch it starts is the
      small probe-only one that comes with `:upstreams`.

  ## Optional options

    * `:upstreams` — keyword list of `name => transport`
      (`{:uds, path}` or `{:http, base_url}`) to health-check. When
      given, an `Embassy.Health.Monitor` and a probe-only Finch (one
      connection per upstream, separate from `:finch` so a saturated
      proxy pool never reads as an upstream outage) are started for the
      instance. Default `[]` (no monitor).
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
    opts |> Keyword.get(:health, []) |> validate_health!()
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

  @doc false
  def health_finch_name(name), do: Module.concat(name, HealthFinch)

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
      health: health_opts(name, upstreams, Keyword.get(opts, :health, []))
    }

    # rest_for_one: the monitor's in-flight probes live under the
    # Task.Supervisor, so if that restarts the monitor restarts with it
    # rather than recording every killed probe as a down upstream.
    children =
      [
        {Registry, keys: :unique, name: registry_name(name), meta: [config: snapshot]},
        {Task.Supervisor, name: task_supervisor}
      ] ++ health_children(snapshot)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp health_children(%{upstreams: []}), do: []

  defp health_children(snapshot) do
    [
      {Finch, name: snapshot.health.finch, pools: %{default: [size: 1]}},
      {Embassy.Health.Monitor, snapshot}
    ]
  end

  # `:probe` is undocumented and exists for tests. `:finch` is the
  # probe-only Finch, nil when no upstreams (and so no monitor) exist.
  defp health_opts(name, upstreams, opts) do
    %{
      interval: Keyword.get(opts, :interval, 5_000),
      timeout: Keyword.get(opts, :timeout, 1_000),
      probe: Keyword.get(opts, :probe, &Embassy.Health.check/3),
      finch: if(upstreams == [], do: nil, else: health_finch_name(name))
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

  defp validate_health!(health) when is_list(health) do
    for key <- [:interval, :timeout], Keyword.has_key?(health, key) do
      case Keyword.fetch!(health, key) do
        ms when is_integer(ms) and ms > 0 ->
          :ok

        other ->
          raise ArgumentError,
                ":health #{key} must be a positive integer (ms), got #{inspect(other)}"
      end
    end

    :ok
  end

  defp validate_health!(other),
    do: raise(ArgumentError, ":health must be a keyword list, got #{inspect(other)}")

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "required option #{inspect(key)} is missing"
    end
  end
end
