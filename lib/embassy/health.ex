defmodule Embassy.Health do
  @moduledoc """
  Upstream health: a one-shot probe (`check/3`) and the last result per
  upstream from the instance's monitor (`status/1`).

  Configure upstreams on the instance:

      {Embassy,
       name: MyApp.Embassy,
       finch: MyApp.Finch,
       upstreams: [rails: {:uds, "/tmp/puma.sock"}],
       health: [interval: 5_000, timeout: 1_000]}

  With `:upstreams` set, `Embassy.Health.Monitor` probes each one every
  `:interval` ms with `HEAD /`. Any HTTP response counts as up; a
  transport error or a timeout is down. Each probe emits
  `[:embassy, :upstream, :check]` with measurements
  `%{duration: native, up: 0 | 1}` and metadata
  `%{instance, upstream, result: :up | {:down, reason}}`. Transitions are
  logged once: a warning going down, an info line coming back.

  This is not a readiness check. An upstream outage should not take
  Phoenix pods out of service when some routes are served natively, so
  embassy never wires upstream health into readiness or liveness. A host
  that wants that can call `status/1` from its own health endpoint.
  """

  @type transport :: {:uds, String.t()} | {:http, String.t()}
  @type status :: :unknown | :up | {:down, term()}

  @doc """
  Probe `transport` once through the instance's Finch with `HEAD /`.

  Options: `:timeout` in ms (default: the instance's `health: [timeout:]`,
  1_000 unless set).
  """
  @spec check(atom(), transport(), keyword()) :: :ok | {:error, term()}
  def check(instance, transport, opts \\ []) do
    snapshot = Embassy.Config.snapshot(instance)
    timeout = Keyword.get(opts, :timeout, snapshot.health.timeout)

    transport
    |> probe_request()
    |> Finch.request(snapshot.finch, receive_timeout: timeout, pool_timeout: timeout)
    |> case do
      {:ok, %Finch.Response{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Last probe result per upstream, `:unknown` before the first probe
  completes. `%{}` when the instance has no upstreams.
  """
  @spec status(atom()) :: %{atom() => status()}
  def status(instance) do
    monitor = Embassy.health_monitor_name(instance)

    case Process.whereis(monitor) do
      nil -> %{}
      _pid -> GenServer.call(monitor, :status)
    end
  end

  defp probe_request({:http, base}), do: Finch.build(:head, base)

  defp probe_request({:uds, path}),
    do: Finch.build(:head, "http://localhost/", [], nil, unix_socket: path)
end
