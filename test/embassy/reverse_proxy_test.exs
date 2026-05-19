defmodule Embassy.ReverseProxyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Embassy.Test.TelemetryCollector

  setup do
    start_supervised!({Finch, name: ReverseProxyTest.Finch})

    start_supervised!({Embassy, name: ReverseProxyTest.Instance, finch: ReverseProxyTest.Finch})

    bypass = Bypass.open()

    opts =
      Embassy.ReverseProxy.init(
        embassy: ReverseProxyTest.Instance,
        transport: {:http, "http://localhost:#{bypass.port}"}
      )

    {:ok, bypass: bypass, opts: opts}
  end

  test "GET round-trips status, body, and a passthrough header", %{
    bypass: bypass,
    opts: opts
  } do
    {:ok, collector} =
      TelemetryCollector.attach([
        [:embassy, :proxy, :start],
        [:embassy, :proxy, :stop]
      ])

    Bypass.expect_once(bypass, "GET", "/foo", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-custom", "yes")
      |> Plug.Conn.resp(200, "hello")
    end)

    conn = conn(:get, "/foo") |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 200
    assert conn.resp_body == "hello"
    assert {"x-custom", "yes"} in conn.resp_headers

    events = TelemetryCollector.events(collector)
    assert Enum.any?(events, fn {name, _, _} -> name == [:embassy, :proxy, :start] end)

    assert Enum.any?(events, fn {name, _, meta} ->
             name == [:embassy, :proxy, :stop] and meta.status == 200
           end)
  end

  test "POST forwards body bytes to upstream", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "POST", "/echo", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, body)
    end)

    conn =
      conn(:post, "/echo", "ping-pong")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 200
    assert conn.resp_body == "ping-pong"
  end

  test "POST uses cached body from Embassy.BodyCache when present", %{
    bypass: bypass,
    opts: opts
  } do
    Bypass.expect_once(bypass, "POST", "/echo", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, body)
    end)

    payload = "cached payload"

    conn =
      conn(:post, "/echo", payload)
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Plug.Conn.assign(:raw_body, [payload])
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 200
    assert conn.resp_body == payload
  end

  test "injects X-Forwarded-For with the peer IP when absent", %{
    bypass: bypass,
    opts: opts
  } do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")
      Plug.Conn.resp(conn, 200, Enum.join(xff, ","))
    end)

    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> Embassy.ReverseProxy.call(opts)

    assert conn.resp_body == "1.2.3.4"
  end

  test "appends to existing X-Forwarded-For to preserve the proxy chain", %{
    bypass: bypass,
    opts: opts
  } do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      [xff] = Plug.Conn.get_req_header(conn, "x-forwarded-for")
      Plug.Conn.resp(conn, 200, xff)
    end)

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "10.0.0.1")
      |> Map.put(:remote_ip, {1, 2, 3, 4})
      |> Embassy.ReverseProxy.call(opts)

    assert conn.resp_body == "10.0.0.1, 1.2.3.4"
  end

  test "preserves existing X-Forwarded-Proto and X-Forwarded-Host", %{
    bypass: bypass,
    opts: opts
  } do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      xfp = Plug.Conn.get_req_header(conn, "x-forwarded-proto") |> List.first()
      xfh = Plug.Conn.get_req_header(conn, "x-forwarded-host") |> List.first()
      Plug.Conn.resp(conn, 200, "#{xfp}|#{xfh}")
    end)

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Plug.Conn.put_req_header("x-forwarded-host", "edge.example.com")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.resp_body == "https|edge.example.com"
  end

  test "sets X-Forwarded-Proto and X-Forwarded-Host from conn when absent", %{
    bypass: bypass,
    opts: opts
  } do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      xfp = Plug.Conn.get_req_header(conn, "x-forwarded-proto") |> List.first()
      xfh = Plug.Conn.get_req_header(conn, "x-forwarded-host") |> List.first()
      Plug.Conn.resp(conn, 200, "#{xfp}|#{xfh}")
    end)

    conn =
      conn(:get, "/")
      |> Map.put(:scheme, :http)
      |> Map.put(:host, "consumer.example.com")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.resp_body == "http|consumer.example.com"
  end

  test "strips hop-by-hop headers from outbound request", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      conn_keepalive = Plug.Conn.get_req_header(conn, "connection")
      Plug.Conn.resp(conn, 200, Enum.join(conn_keepalive, ","))
    end)

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("connection", "close")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.resp_body == ""
  end

  test "strips hop-by-hop headers from inbound response", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.resp(200, "ok")
    end)

    conn = conn(:get, "/") |> Embassy.ReverseProxy.call(opts)

    refute List.keyfind(conn.resp_headers, "connection", 0)
  end

  test "upstream connection failure returns 502 and emits :exception telemetry", %{
    bypass: bypass,
    opts: opts
  } do
    {:ok, collector} =
      TelemetryCollector.attach([[:embassy, :proxy, :exception]])

    Bypass.down(bypass)

    conn = conn(:get, "/") |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 502
    assert conn.resp_body == "Bad gateway: upstream unreachable"

    events = TelemetryCollector.events(collector)
    assert [{[:embassy, :proxy, :exception], _measurements, meta}] = events
    assert meta.kind == :upstream_error
    assert meta.instance == ReverseProxyTest.Instance
  end
end
