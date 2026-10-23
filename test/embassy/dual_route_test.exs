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

  defmodule CookiePlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, _opts) do
      conn
      |> Plug.Conn.prepend_resp_headers([{"set-cookie", "a=1"}, {"set-cookie", "b=2"}])
      |> Plug.Conn.send_resp(200, "control")
    end
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
    ]
    |> Keyword.merge(overrides)
  end

  test "canonical :control returns the control response", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, canonical: :control))
    conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.status == 200
    assert conn.resp_body == "control"
  end

  test "the served response keeps repeated headers such as set-cookie", %{embassy: e} do
    opts =
      Embassy.DualRoute.init(base_opts(e, canonical: :control, control: {:plug, CookiePlug, []}))

    conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == ["a=1", "b=2"]
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

    defmodule RaisingReporter do
      @behaviour Embassy.DualRoute.Reporter
      @impl true
      def report(_result), do: raise("reporter boom")
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
        &__MODULE__.forward_own/4,
        {self(), e}
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
      assert meta.route == "/"
      assert meta.request_path == "/posts"
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

    test "runs a proxy target as the shadow end-to-end", %{embassy: e} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/posts", fn conn ->
        Plug.Conn.resp(conn, 200, "from-upstream")
      end)

      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:proxy, transport: {:http, "http://localhost:#{bypass.port}"}},
          comparator: :status_only
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "control"
      assert_receive {:telemetry, [:embassy, :dual_route, :match], _meas, meta}, 1_000
      assert meta.status == {200, 200}
    end

    test "a canonical proxy upstream error becomes the user's 502", %{embassy: e} do
      bypass = Bypass.open()
      Bypass.down(bypass)

      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:proxy, transport: {:http, "http://localhost:#{bypass.port}"}},
          candidate: {:plug, CandidatePlug, []},
          canonical: :control,
          comparator: :status_only
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.status == 502
      assert conn.resp_body == "Bad gateway: upstream unreachable"
    end

    test "a reporter that raises is isolated: canonical unaffected, :error emitted", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, CandidatePlug, []},
          comparator: :exact,
          reporter: RaisingReporter
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "control"
      assert_receive {:telemetry, [:embassy, :dual_route, :error], _meas, meta}, 1_000
      assert match?({:reporter_error, _}, meta.reason)
      assert meta.request_path == "/posts"
    end
  end

  describe "observability" do
    setup %{embassy: e} do
      handler = {__MODULE__, :obs, System.unique_integer([:positive])}

      :telemetry.attach_many(
        handler,
        [
          [:embassy, :dual_route, :dispatch],
          [:embassy, :dual_route, :match],
          [:embassy, :dual_route, :diff],
          [:embassy, :dual_route, :error],
          [:embassy, :proxy, :start],
          [:embassy, :proxy, :stop],
          [:embassy, :proxy, :exception]
        ],
        &__MODULE__.forward_own/4,
        {self(), e}
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "match metadata carries route label and request_path", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          embassy: e,
          control: {:plug, ControlPlug, []},
          candidate: {:plug, ControlPlug, []},
          comparator: :exact,
          route: :posts
        )

      conn(:get, "/posts/1") |> Embassy.DualRoute.call(opts)
      assert_receive {:telemetry, [:embassy, :dual_route, :match], _meas, meta}, 1_000
      assert meta.route == "posts"
      assert meta.request_path == "/posts/1"
    end

    test "dispatch fires for an unsampled plug-canonical request", %{embassy: e} do
      opts = Embassy.DualRoute.init(base_opts(e, canonical: :candidate, sample_rate: 0.0))
      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "candidate"

      assert_receive {:telemetry, [:embassy, :dual_route, :dispatch], %{monotonic_time: _}, meta}

      assert %{instance: ^e, route: "/", method: "GET"} = meta
      assert %{canonical: :candidate, served_by: :plug, sampled: false} = meta
      refute_receive {:telemetry, [:embassy, :dual_route, :dispatch], _, _}, 100
    end

    test "dispatch fires for a sampled request", %{embassy: e} do
      opts = Embassy.DualRoute.init(base_opts(e, []))
      conn(:get, "/posts") |> Embassy.DualRoute.call(opts)

      assert_receive {:telemetry, [:embassy, :dual_route, :dispatch], _, meta}
      assert %{canonical: :control, served_by: :plug, sampled: true} = meta
    end

    test "dispatch does not fire on 413", %{embassy: e} do
      opts = Embassy.DualRoute.init(base_opts(e, max_body_length: 1, methods: ["POST"]))
      conn = conn(:post, "/posts", "0123456789") |> Embassy.DualRoute.call(opts)
      assert conn.status == 413
      refute_receive {:telemetry, [:embassy, :dual_route, :dispatch], _, _}, 100
    end

    test "canonical proxy target emits proxy events with role :canonical", %{embassy: e} do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "GET", "/posts", &Plug.Conn.resp(&1, 200, "up"))

      opts =
        Embassy.DualRoute.init(
          base_opts(e,
            control: {:proxy, transport: {:http, "http://localhost:#{bypass.port}"}},
            sample_rate: 0.0
          )
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "up"

      assert_receive {:telemetry, [:embassy, :proxy, :start], _, %{role: :canonical}}
      assert_receive {:telemetry, [:embassy, :proxy, :stop], _, meta}
      assert %{role: :canonical, route: "/", status: 200, instance: ^e} = meta

      assert_receive {:telemetry, [:embassy, :dual_route, :dispatch], _, dispatch}
      assert dispatch.served_by == :proxy
    end

    test "shadow proxy target emits proxy events with role :shadow", %{embassy: e} do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "GET", "/posts", &Plug.Conn.resp(&1, 200, "up"))

      opts =
        Embassy.DualRoute.init(
          base_opts(e,
            control: {:proxy, transport: {:http, "http://localhost:#{bypass.port}"}},
            canonical: :candidate,
            route: "posts"
          )
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.resp_body == "candidate"

      assert_receive {:telemetry, [:embassy, :proxy, :stop], _, meta}, 1_000
      assert %{role: :shadow, route: "posts", status: 200} = meta
    end

    test "shadow proxy upstream error", %{embassy: e} do
      opts =
        Embassy.DualRoute.init(
          base_opts(e,
            control: {:proxy, transport: {:http, "http://localhost:1"}},
            canonical: :candidate
          )
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.status == 200
      assert conn.resp_body == "candidate"

      assert_receive {:telemetry, [:embassy, :proxy, :exception], _, meta}, 1_000
      assert %{role: :shadow, kind: :upstream_error} = meta
      assert_receive {:telemetry, [:embassy, :dual_route, :error], _, error_meta}, 1_000
      assert error_meta.request_path == "/posts"
      assert error_meta.route == "/"
    end

    test "a shadow proxy killed at shadow_timeout emits a proxy exception", %{embassy: e} do
      port = Embassy.Test.SilentServer.start()

      opts =
        Embassy.DualRoute.init(
          base_opts(e,
            canonical: :control,
            candidate: {:proxy, transport: {:http, "http://localhost:#{port}"}},
            shadow_timeout: 100
          )
        )

      conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
      assert conn.status == 200

      assert_receive {:telemetry, [:embassy, :proxy, :start], _, %{role: :shadow}}, 1_000
      assert_receive {:telemetry, [:embassy, :proxy, :exception], meas, meta}, 1_000
      assert %{role: :shadow, kind: :shadow_timeout, route: "/"} = meta
      assert is_integer(meas.duration)
      assert_receive {:telemetry, [:embassy, :dual_route, :error], _, _}, 1_000
    end
  end

  # Telemetry handlers are global and other async modules emit proxy
  # events, so forward only this test's instance.
  def forward_own(event, meas, %{instance: e} = meta, {pid, e}),
    do: send(pid, {:telemetry, event, meas, meta})

  def forward_own(_event, _meas, _meta, _config), do: :ok
end
