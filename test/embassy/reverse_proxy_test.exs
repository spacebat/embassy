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
end
