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

    events = own_events(collector)
    assert Enum.any?(events, fn {name, _, _} -> name == [:embassy, :proxy, :start] end)

    assert Enum.any?(events, fn {name, _, meta} ->
             name == [:embassy, :proxy, :stop] and meta.status == 200
           end)
  end

  test "keeps repeated response headers such as set-cookie", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "GET", "/login", fn conn ->
      conn
      |> Plug.Conn.prepend_resp_headers([{"set-cookie", "a=1"}, {"set-cookie", "b=2"}])
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.resp(200, "ok")
    end)

    conn = conn(:get, "/login") |> Embassy.ReverseProxy.call(opts)

    # Bypass's Cowboy may reorder repeated headers on the wire; both must arrive.
    assert conn |> Plug.Conn.get_resp_header("set-cookie") |> Enum.sort() == ["a=1", "b=2"]
    # Upstream's value replaces Plug's default rather than adding a second one.
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
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

    events = own_events(collector)
    assert [{[:embassy, :proxy, :exception], _measurements, meta}] = events
    assert meta.kind == :upstream_error
    assert meta.instance == ReverseProxyTest.Instance
  end

  describe ":receive_timeout" do
    setup %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/slow", fn conn ->
        Process.sleep(600)
        Plug.Conn.resp(conn, 200, "late")
      end)

      :ok
    end

    defp proxy_opts(bypass, extra) do
      Embassy.ReverseProxy.init(
        [
          embassy: ReverseProxyTest.Instance,
          transport: {:http, "http://localhost:#{bypass.port}"}
        ] ++ extra
      )
    end

    test "an upstream slower than the timeout takes the :upstream_error path" do
      port = Embassy.Test.SilentServer.start()
      {:ok, collector} = TelemetryCollector.attach([[:embassy, :proxy, :exception]])

      opts =
        Embassy.ReverseProxy.init(
          embassy: ReverseProxyTest.Instance,
          transport: {:http, "http://127.0.0.1:#{port}"},
          receive_timeout: 200
        )

      # The silent server never replies, so only the option can end this
      # within 2 s: the 15 s default would hold the request far longer.
      # (A Bypass stub can't be used here: it exits the test when the client
      # hangs up mid-handler.)
      {micros, conn} =
        :timer.tc(fn -> conn(:get, "/slow") |> Embassy.ReverseProxy.call(opts) end)

      assert conn.status == 502
      assert micros < 2_000_000
      assert [{_, _, %{kind: :upstream_error}}] = own_events(collector)
    end

    test "an upstream within the timeout succeeds", %{bypass: bypass} do
      conn =
        conn(:get, "/slow")
        |> Embassy.ReverseProxy.call(proxy_opts(bypass, receive_timeout: 5_000))

      assert conn.status == 200
      assert conn.resp_body == "late"
    end

    test "defaults to 15 seconds", %{bypass: bypass} do
      assert %{receive_timeout: 15_000} = proxy_opts(bypass, [])
      assert Embassy.Proxy.default_receive_timeout() == 15_000
    end
  end

  test "WebSocket upgrade request short-circuits to 426 with telemetry", %{opts: opts} do
    {:ok, collector} =
      TelemetryCollector.attach([[:embassy, :proxy, :exception]])

    conn =
      conn(:get, "/cable")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("connection", "upgrade")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 426
    assert conn.resp_body =~ "WebSocket"

    events = own_events(collector)
    assert [{[:embassy, :proxy, :exception], _measurements, meta}] = events
    assert meta.kind == :unsupported_upgrade
  end

  test "request body exceeding max_body_length returns 413 with telemetry", %{
    bypass: bypass
  } do
    {:ok, collector} =
      TelemetryCollector.attach([[:embassy, :proxy, :exception]])

    opts =
      Embassy.ReverseProxy.init(
        embassy: ReverseProxyTest.Instance,
        transport: {:http, "http://localhost:#{bypass.port}"},
        max_body_length: 10
      )

    body = String.duplicate("x", 1_000)

    conn =
      conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 413
    assert conn.resp_body =~ "Payload"

    events = own_events(collector)
    assert [{[:embassy, :proxy, :exception], _measurements, meta}] = events
    assert meta.kind == :body_too_large
  end

  test "UDS transport is plumbed to Finch (unreachable socket -> 502)", %{} do
    bogus = "/tmp/embassy_test_no_such_socket_#{System.unique_integer([:positive])}.sock"

    opts =
      Embassy.ReverseProxy.init(
        embassy: ReverseProxyTest.Instance,
        transport: {:uds, bogus}
      )

    conn = conn(:get, "/") |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 502
  end

  test "register_before_send callback fires on the 200 path", %{bypass: bypass, opts: opts} do
    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)

    tag = :erlang.unique_integer()

    conn =
      conn(:get, "/")
      |> Plug.Conn.register_before_send(fn c ->
        Plug.Conn.put_resp_header(c, "x-augmented", "#{tag}")
      end)
      |> Embassy.ReverseProxy.call(opts)

    assert {"x-augmented", _} = List.keyfind(conn.resp_headers, "x-augmented", 0)
  end

  test "register_before_send callback fires on the 502 path", %{bypass: bypass, opts: opts} do
    Bypass.down(bypass)

    conn =
      conn(:get, "/")
      |> Plug.Conn.register_before_send(fn c ->
        Plug.Conn.put_resp_header(c, "x-augmented", "yes")
      end)
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 502
    assert {"x-augmented", "yes"} in conn.resp_headers
  end

  test "register_before_send callback fires on the 426 path", %{opts: opts} do
    conn =
      conn(:get, "/cable")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.register_before_send(fn c ->
        Plug.Conn.put_resp_header(c, "x-augmented", "yes")
      end)
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 426
    assert {"x-augmented", "yes"} in conn.resp_headers
  end

  test "register_before_send callback fires on the 413 path", %{bypass: bypass} do
    opts =
      Embassy.ReverseProxy.init(
        embassy: ReverseProxyTest.Instance,
        transport: {:http, "http://localhost:#{bypass.port}"},
        max_body_length: 10
      )

    body = String.duplicate("x", 1_000)

    conn =
      conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Plug.Conn.register_before_send(fn c ->
        Plug.Conn.put_resp_header(c, "x-augmented", "yes")
      end)
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 413
    assert {"x-augmented", "yes"} in conn.resp_headers
  end

  test "client body read error returns 400 with :body_read_error telemetry", %{bypass: bypass} do
    {:ok, collector} =
      TelemetryCollector.attach([[:embassy, :proxy, :exception]])

    opts =
      Embassy.ReverseProxy.init(
        embassy: ReverseProxyTest.Instance,
        transport: {:http, "http://localhost:#{bypass.port}"}
      )

    # Build a conn whose body adapter will return {:error, reason} on read.
    # Plug.Test's Plug.Adapters.Test.Conn supports a body adapter; we can
    # simulate failure by stuffing an :error-returning function into the conn.
    # The cleanest test-only path: stash a sentinel chunk that makes read_body
    # raise, or use Plug.Conn.put_private to inject. Simplest approach:
    # set conn.adapter to a tiny module returning {:error, :test}.

    {adapter_mod, adapter_state} = conn(:post, "/", "ignored").adapter

    failing_adapter = {Embassy.Test.FailingReadAdapter, adapter_state}

    conn =
      conn(:post, "/", "ignored")
      |> Map.put(:adapter, failing_adapter)
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Embassy.ReverseProxy.call(opts)

    assert conn.status == 400
    assert conn.resp_body =~ "Bad Request"

    events = own_events(collector)
    assert [{[:embassy, :proxy, :exception], _measurements, meta}] = events
    assert meta.kind == :body_read_error

    _ = adapter_mod
  end

  describe "route and role metadata" do
    test "stop metadata carries route and role", %{bypass: bypass} do
      {:ok, collector} =
        TelemetryCollector.attach([[:embassy, :proxy, :start], [:embassy, :proxy, :stop]])

      Bypass.expect_once(bypass, "GET", "/foo", &Plug.Conn.resp(&1, 200, "ok"))

      opts =
        Embassy.ReverseProxy.init(
          embassy: ReverseProxyTest.Instance,
          transport: {:http, "http://localhost:#{bypass.port}"},
          route: :legacy
        )

      conn(:get, "/foo") |> Embassy.ReverseProxy.call(opts)

      assert [
               {[:embassy, :proxy, :start], _, start_meta},
               {[:embassy, :proxy, :stop], _, stop_meta}
             ] = own_events(collector)

      assert %{route: "legacy", role: :direct} = start_meta
      assert %{route: "legacy", role: :direct, status: 200, request_path: "/foo"} = stop_meta
    end

    test "route defaults from script_name", %{bypass: bypass, opts: opts} do
      {:ok, collector} = TelemetryCollector.attach([[:embassy, :proxy, :stop]])

      Bypass.expect_once(bypass, "GET", "/posts/1", &Plug.Conn.resp(&1, 200, "ok"))

      %{conn(:get, "/posts/1") | script_name: ["posts"], path_info: ["1"]}
      |> Embassy.ReverseProxy.call(opts)

      assert [{_, _, meta}] = own_events(collector)
      assert meta.route == "/posts"
    end

    test "upstream error exception carries route and role", %{bypass: bypass, opts: opts} do
      {:ok, collector} = TelemetryCollector.attach([[:embassy, :proxy, :exception]])

      Bypass.down(bypass)
      conn(:get, "/") |> Embassy.ReverseProxy.call(opts)

      assert [{_, _, meta}] = own_events(collector)
      assert %{kind: :upstream_error, route: "/", role: :direct} = meta
    end
  end

  # Telemetry handlers are global; async modules emit proxy events too.
  defp own_events(collector) do
    collector
    |> TelemetryCollector.events()
    |> Enum.filter(fn {_, _, meta} -> meta.instance == ReverseProxyTest.Instance end)
  end
end
