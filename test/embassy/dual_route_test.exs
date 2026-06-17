defmodule Embassy.DualRouteTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defmodule ControlPlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "control")
  end

  defmodule CandidatePlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "candidate")
  end

  setup do
    name = :"dr_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: Module.concat(name, Finch)})
    start_supervised!({Embassy, name: name, finch: Module.concat(name, Finch)})
    %{embassy: name}
  end

  defp base_opts(embassy, overrides) do
    [
      embassy: embassy,
      control: {:plug, ControlPlug, []},
      candidate: {:plug, CandidatePlug, []},
      comparator: :status_only
    ] ++ overrides
  end

  test "canonical :control returns the control response", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, canonical: :control))
    conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.status == 200
    assert conn.resp_body == "control"
  end

  test "canonical :candidate returns the candidate response", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, canonical: :candidate))
    conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.resp_body == "candidate"
  end

  test "a non-listed method runs only the canonical target", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, methods: ["GET"]))
    conn = conn(:post, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.resp_body == "control"
  end

  test "init requires a comparator", %{embassy: e} do
    assert_raise KeyError, fn ->
      Embassy.DualRoute.init(
        embassy: e,
        control: {:plug, ControlPlug, []},
        candidate: {:plug, CandidatePlug, []}
      )
    end
  end

  describe "shadow experiment" do
    defmodule BoomPlug do
      @behaviour Plug
      @impl true
      def init(opts), do: opts
      @impl true
      def call(_conn, _opts), do: raise("boom")
    end

    defmodule EchoReporter do
      @behaviour Embassy.DualRoute.Reporter
      @impl true
      def report(result) do
        :persistent_term.get(:dr_reporter_pid) |> send({:reported, result})
        :ok
      end
    end

    setup %{embassy: e} do
      handler = {__MODULE__, System.unique_integer([:positive])}

      :telemetry.attach_many(
        handler,
        [
          [:embassy, :dual_route, :match],
          [:embassy, :dual_route, :diff],
          [:embassy, :dual_route, :error]
        ],
        fn event, meas, meta, pid -> send(pid, {:telemetry, event, meas, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{embassy: e}
    end

    test "emits :match when control and candidate agree", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, ControlPlug, []},
          comparator: :exact
        )

      conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert_receive {:telemetry, [:embassy, :dual_route, :match], _meas, meta}, 1_000
      assert meta.route == "/posts"
    end

    test "emits :diff when they disagree", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, CandidatePlug, []},
          comparator: :exact
        )

      conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert_receive {:telemetry, [:embassy, :dual_route, :diff], _meas, meta}, 1_000
      assert meta.diff.reason == :body
    end

    test "isolates a shadow crash: canonical still returned, :error emitted", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, BoomPlug, []},
          comparator: :exact
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "control"
      assert_receive {:telemetry, [:embassy, :dual_route, :error], _meas, _meta}, 1_000
    end

    test "invokes the reporter with a Result", %{embassy: e} do
      :persistent_term.put(:dr_reporter_pid, self())

      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, CandidatePlug, []},
          comparator: :exact,
          reporter: EchoReporter
        )

      conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert_receive {:reported, %Embassy.DualRoute.Result{verdict: :diff}}, 1_000
    end

    test "sample_rate 0.0 skips the experiment (no shadow telemetry)", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, CandidatePlug, []},
          comparator: :exact,
          sample_rate: 0.0
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "control"
      refute_receive {:telemetry, [:embassy, :dual_route, _], _, _}, 300
    end
  end
end
