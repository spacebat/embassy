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

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    finch = Keyword.fetch!(opts, :finch)
    task_supervisor = task_supervisor_name(name)

    snapshot = %{name: name, finch: finch, task_supervisor: task_supervisor}

    children = [
      {Registry, keys: :unique, name: registry_name(name), meta: [config: snapshot]},
      {Task.Supervisor, name: task_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "required option #{inspect(key)} is missing"
    end
  end
end
