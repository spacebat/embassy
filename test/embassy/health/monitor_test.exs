defmodule Embassy.Health.MonitorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Embassy.Health
  alias Embassy.Test.TelemetryCollector

  defp start_instance(upstreams, health) do
    name = :"monitor_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: Module.concat(name, Finch)})

    start_supervised!(
      {Embassy,
       name: name, finch: Module.concat(name, Finch), upstreams: upstreams, health: health}
    )

    name
  end

  defp wait_for(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        do_wait_for(fun, deadline)
    end
  end

  defp occurrences(log, needle), do: length(String.split(log, needle)) - 1

  test "reports :up and emits check events" do
    {:ok, collector} = TelemetryCollector.attach([[:embassy, :upstream, :check]])
    bypass = Bypass.open()
    Bypass.stub(bypass, "HEAD", "/", &Plug.Conn.resp(&1, 200, ""))

    e =
      start_instance([rails: {:http, "http://localhost:#{bypass.port}"}],
        interval: 50,
        timeout: 100
      )

    wait_for(fn -> Health.status(e) == %{rails: :up} end)

    assert Enum.any?(TelemetryCollector.events(collector), fn
             {_, %{up: 1, duration: d}, %{instance: ^e, upstream: :rails, result: :up}} ->
               is_integer(d)

             _ ->
               false
           end)
  end

  test "upstream down at boot" do
    log =
      capture_log(fn ->
        e = start_instance([rails: {:http, "http://localhost:1"}], interval: 50, timeout: 100)
        wait_for(fn -> match?(%{rails: {:down, _}}, Health.status(e)) end)
        Process.sleep(300)
        assert %{rails: {:down, _}} = Health.status(e)
        send(self(), {:instance, e})
      end)

    assert_received {:instance, e}
    assert occurrences(log, "#{inspect(e)} upstream rails down") == 1
  end

  test "logs recovery once" do
    bypass = Bypass.open()
    Bypass.stub(bypass, "HEAD", "/", &Plug.Conn.resp(&1, 200, ""))

    log =
      capture_log(fn ->
        e =
          start_instance([rails: {:http, "http://localhost:#{bypass.port}"}],
            interval: 50,
            timeout: 100
          )

        wait_for(fn -> Health.status(e) == %{rails: :up} end)
        Bypass.down(bypass)
        wait_for(fn -> match?(%{rails: {:down, _}}, Health.status(e)) end)
        Bypass.up(bypass)
        wait_for(fn -> Health.status(e) == %{rails: :up} end, 2_000)
        Process.sleep(150)
        send(self(), {:instance, e})
      end)

    assert_received {:instance, e}
    assert occurrences(log, "#{inspect(e)} upstream rails down") == 1
    assert occurrences(log, "#{inspect(e)} upstream rails up") == 1
  end

  test "does not start a second probe while one is in flight" do
    port = Embassy.Test.SilentServer.start(self())

    e =
      start_instance([rails: {:http, "http://localhost:#{port}"}], interval: 50, timeout: 1_000)

    assert_receive {:silent_accept, ^port}, 200
    refute_receive {:silent_accept, ^port}, 300

    {micros, status} = :timer.tc(fn -> Health.status(e) end)
    assert status == %{rails: :unknown}
    assert micros < 100_000
  end

  test "probe crash marks upstream down" do
    capture_log(fn ->
      e =
        start_instance([rails: {:http, "http://localhost:1"}],
          interval: 50,
          probe: fn _, _, _ -> raise "boom" end
        )

      wait_for(fn -> match?(%{rails: {:down, {:probe_exit, _}}}, Health.status(e)) end)
      assert Process.alive?(Process.whereis(Embassy.health_monitor_name(e)))
    end)
  end

  test "a probe that outlives the timeout is killed and marked down" do
    capture_log(fn ->
      e =
        start_instance([rails: {:http, "http://localhost:1"}],
          interval: 50,
          timeout: 100,
          probe: fn _, _, _ ->
            Process.sleep(5_000)
            :ok
          end
        )

      wait_for(fn -> Health.status(e) == %{rails: {:down, :timeout}} end, 500)
    end)
  end
end
