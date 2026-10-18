defmodule Embassy.HealthTest do
  use ExUnit.Case, async: true

  alias Embassy.Health

  setup do
    name = :"health_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: Module.concat(name, Finch)})
    start_supervised!({Embassy, name: name, finch: Module.concat(name, Finch)})
    %{embassy: name}
  end

  test "check/3 is :ok on any HTTP response", %{embassy: e} do
    bypass = Bypass.open()
    Bypass.expect_once(bypass, "HEAD", "/", &Plug.Conn.resp(&1, 503, ""))

    assert :ok = Health.check(e, {:http, "http://localhost:#{bypass.port}"}, [])
  end

  test "check/3 errors when unreachable", %{embassy: e} do
    assert {:error, _} = Health.check(e, {:http, "http://localhost:1"}, [])
  end

  test "check/3 errors on timeout", %{embassy: e} do
    port = Embassy.Test.SilentServer.start()
    assert {:error, _} = Health.check(e, {:http, "http://localhost:#{port}"}, timeout: 50)
  end

  test "check/3 probes a UDS upstream", %{embassy: e} do
    assert {:error, _} = Health.check(e, {:uds, "/nonexistent/embassy.sock"}, [])
  end

  test "status/1 is %{} without upstreams", %{embassy: e} do
    assert Health.status(e) == %{}
  end

  test "status/1 is %{} when the monitor name is registered to a dead process" do
    name = :"health_dead_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: Module.concat(name, Finch)})
    start_supervised!({Embassy, name: name, finch: Module.concat(name, Finch)})

    {:ok, pid} = Agent.start(fn -> :ok end, name: Embassy.health_monitor_name(name))
    Agent.stop(pid)
    assert Health.status(name) == %{}
  end

  test "check/3 does not go through the proxy Finch" do
    name = :"health_own_finch_#{System.unique_integer([:positive])}"
    bypass = Bypass.open()
    Bypass.stub(bypass, "HEAD", "/", &Plug.Conn.resp(&1, 200, ""))
    upstream = {:http, "http://localhost:#{bypass.port}"}

    # The monitor's own probes are stubbed so only check/3 hits Bypass.
    start_supervised!(
      {Embassy,
       name: name,
       finch: Module.concat(name, NotRunning),
       upstreams: [rails: upstream],
       health: [probe: fn _, _, _ -> :ok end]}
    )

    assert :ok = Health.check(name, upstream, [])
  end

  test "Embassy rejects a bad :upstreams entry" do
    name = :"health_bad_#{System.unique_integer([:positive])}"

    assert {:error, reason} =
             start_supervised({Embassy, name: name, finch: :f, upstreams: [rails: :nope]})

    assert inspect(reason) =~ "ArgumentError"
    assert inspect(reason) =~ ":upstreams"
  end

  test "Embassy rejects a non-positive :health interval or timeout" do
    for health <- [[interval: 0], [timeout: -1], [interval: "5s"]] do
      name = :"health_bad_#{System.unique_integer([:positive])}"

      assert {:error, reason} =
               start_supervised(
                 {Embassy,
                  name: name, finch: :f, upstreams: [rails: {:http, "x"}], health: health}
               )

      assert inspect(reason) =~ ":health"
    end
  end
end
