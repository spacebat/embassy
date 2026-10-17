defmodule Embassy.TelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Embassy.Test.TelemetryCollector
  alias Telemetry.Metrics.{Counter, Distribution, LastValue}

  defmodule OkPlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  @expected %{
    "embassy.proxy.duration" =>
      {[:embassy, :proxy, :stop], [:instance, :route, :role, :status], Distribution},
    "embassy.proxy.exception.count" =>
      {[:embassy, :proxy, :exception], [:instance, :route, :role, :kind], Counter},
    "embassy.dual_route.dispatch.count" =>
      {[:embassy, :dual_route, :dispatch], [:instance, :route, :canonical, :served_by, :sampled],
       Counter},
    "embassy.dual_route.match.count" =>
      {[:embassy, :dual_route, :match], [:instance, :route], Counter},
    "embassy.dual_route.diff.count" =>
      {[:embassy, :dual_route, :diff], [:instance, :route], Counter},
    "embassy.dual_route.error.count" =>
      {[:embassy, :dual_route, :error], [:instance, :route], Counter},
    "embassy.dual_route.match.candidate_duration" =>
      {[:embassy, :dual_route, :match], [:instance, :route], Distribution},
    "embassy.dual_route.diff.candidate_duration" =>
      {[:embassy, :dual_route, :diff], [:instance, :route], Distribution},
    "embassy.upgrade.rejected.count" =>
      {[:embassy, :upgrade, :rejected], [:instance, :kind], Counter},
    "embassy.upstream.up" => {[:embassy, :upstream, :check], [:instance, :upstream], LastValue},
    "embassy.upstream.check.duration" =>
      {[:embassy, :upstream, :check], [:instance, :upstream], Distribution}
  }

  test "metrics/0 defines the documented series" do
    actual =
      Map.new(Embassy.Telemetry.metrics(), fn m ->
        {Enum.join(m.name, "."), {m.event_name, m.tags, m.__struct__}}
      end)

    assert actual == @expected
  end

  test "distributions use the documented buckets and unit" do
    for %Distribution{} = m <- Embassy.Telemetry.metrics() do
      assert m.reporter_options[:buckets] == [5, 10, 25, 50, 100, 250, 500, 1000, 5000]
      assert m.unit == :millisecond
    end
  end

  test "no metric tags request_path or reason" do
    for m <- Embassy.Telemetry.metrics() do
      assert m.tags -- [:request_path, :reason, :diff, :transport] == m.tags,
             "#{inspect(m.name)} has a forbidden tag"
    end
  end

  test "every tag is present in emitted metadata" do
    name = :"telemetry_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: Module.concat(name, Finch)})
    bypass = Bypass.open()
    Bypass.stub(bypass, "GET", "/posts", &Plug.Conn.resp(&1, 200, "ok"))
    Bypass.stub(bypass, "HEAD", "/", &Plug.Conn.resp(&1, 200, ""))
    upstream = {:http, "http://localhost:#{bypass.port}"}

    {:ok, collector} =
      @expected
      |> Map.values()
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> TelemetryCollector.attach()

    start_supervised!(
      {Embassy,
       name: name,
       finch: Module.concat(name, Finch),
       upstreams: [rails: upstream],
       health: [interval: 50]}
    )

    proxy = Embassy.ReverseProxy.init(embassy: name, transport: upstream)
    conn(:get, "/posts") |> Embassy.ReverseProxy.call(proxy)

    down = Embassy.ReverseProxy.init(embassy: name, transport: {:http, "http://localhost:1"})
    conn(:get, "/posts") |> Embassy.ReverseProxy.call(down)

    dual =
      Embassy.DualRoute.init(
        embassy: name,
        control: {:proxy, transport: upstream},
        candidate: {:plug, OkPlug, []},
        comparator: :status_only
      )

    conn(:get, "/posts") |> Embassy.DualRoute.call(dual)
    Process.sleep(200)

    events =
      collector
      |> TelemetryCollector.events()
      |> Enum.filter(fn {_, _, meta} -> meta.instance == name end)

    captured = MapSet.new(events, &elem(&1, 0))

    for event <- [
          [:embassy, :proxy, :stop],
          [:embassy, :proxy, :exception],
          [:embassy, :dual_route, :dispatch],
          [:embassy, :dual_route, :match],
          [:embassy, :upstream, :check]
        ] do
      assert event in captured, "expected #{inspect(event)} to fire"
    end

    for m <- Embassy.Telemetry.metrics(),
        {event, _, meta} <- events,
        event == m.event_name do
      assert m.tags -- Map.keys(meta) == [],
             "#{inspect(m.name)} tags missing from #{inspect(meta)}"
    end
  end
end
