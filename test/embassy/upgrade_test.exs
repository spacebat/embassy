defmodule Embassy.UpgradeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Embassy.Test.TelemetryCollector
  alias Embassy.Upgrade

  defmodule TestHandler do
    @moduledoc false
    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:ok, state}

    @impl WebSock
    def handle_in(_msg, state), do: {:ok, state}

    @impl WebSock
    def handle_info(_msg, state), do: {:ok, state}
  end

  defp opts(overrides \\ []) do
    base = [
      handler: TestHandler,
      init_arg: %{flag: :init},
      subprotocols: ["actioncable-v1-json"],
      instance: :test_instance
    ]

    Upgrade.init(Keyword.merge(base, overrides))
  end

  defp ws_conn(headers) do
    conn(:get, "/cable")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | &1])
    |> Plug.Conn.put_req_header("upgrade", "websocket")
    |> Plug.Conn.put_req_header("connection", "upgrade")
    |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> Plug.Conn.put_req_header("sec-websocket-version", "13")
    |> then(fn c ->
      Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    end)
  end

  describe "init/1" do
    test "raises when :handler is missing" do
      assert_raise KeyError, fn ->
        Upgrade.init(subprotocols: ["x"])
      end
    end

    test "raises when :subprotocols is missing" do
      assert_raise KeyError, fn ->
        Upgrade.init(handler: TestHandler)
      end
    end

    test "defaults timeout to 60_000" do
      assert %{timeout: 60_000} = Upgrade.init(handler: TestHandler, subprotocols: ["x"])
    end

    test "accepts a custom timeout" do
      assert %{timeout: 5_000} =
               Upgrade.init(handler: TestHandler, subprotocols: ["x"], timeout: 5_000)
    end
  end

  describe "call/2 — rejection paths" do
    test "responds 426 when no Upgrade header is present" do
      {:ok, collector} = TelemetryCollector.attach([[:embassy, :upgrade, :rejected]])

      conn = conn(:get, "/cable") |> Upgrade.call(opts())

      assert conn.status == 426
      assert conn.halted

      assert [{[:embassy, :upgrade, :rejected], _meas, meta}] =
               TelemetryCollector.events(collector)

      assert meta.kind == :not_an_upgrade
      assert meta.instance == :test_instance
      assert meta.requested_subprotocols == []
    end

    test "responds 426 when no configured subprotocol matches" do
      {:ok, collector} = TelemetryCollector.attach([[:embassy, :upgrade, :rejected]])

      conn =
        ws_conn([{"sec-websocket-protocol", "graphql-ws"}])
        |> Upgrade.call(opts())

      assert conn.status == 426
      assert conn.halted

      assert [{[:embassy, :upgrade, :rejected], _meas, meta}] =
               TelemetryCollector.events(collector)

      assert meta.kind == :no_subprotocol
      assert meta.requested_subprotocols == ["graphql-ws"]
    end

    test "rejection telemetry tolerates a nil instance" do
      {:ok, collector} = TelemetryCollector.attach([[:embassy, :upgrade, :rejected]])

      conn = conn(:get, "/cable") |> Upgrade.call(opts(instance: nil))

      assert conn.status == 426

      assert [{_, _, %{instance: nil}}] = TelemetryCollector.events(collector)
    end
  end

  describe "call/2 — upgrade path" do
    test "echoes the chosen subprotocol when a single configured option matches" do
      conn =
        ws_conn([{"sec-websocket-protocol", "actioncable-v1-json"}])
        |> Upgrade.call(opts())

      assert ["actioncable-v1-json"] =
               Plug.Conn.get_resp_header(conn, "sec-websocket-protocol")
    end

    test "picks the first configured subprotocol when multiple match (configured-list ordering wins)" do
      custom = opts(subprotocols: ["actioncable-v1-json", "graphql-ws"])

      conn =
        ws_conn([{"sec-websocket-protocol", "graphql-ws, actioncable-v1-json"}])
        |> Upgrade.call(custom)

      assert ["actioncable-v1-json"] =
               Plug.Conn.get_resp_header(conn, "sec-websocket-protocol")
    end

    test "configurable subprotocols list (graphql-ws use case)" do
      custom = opts(subprotocols: ["graphql-ws"])

      conn =
        ws_conn([{"sec-websocket-protocol", "graphql-ws"}])
        |> Upgrade.call(custom)

      assert ["graphql-ws"] = Plug.Conn.get_resp_header(conn, "sec-websocket-protocol")
    end
  end

  describe "websocket_upgrade?/1" do
    test "true when the upgrade header requests websocket" do
      assert Upgrade.websocket_upgrade?(
               conn(:get, "/")
               |> Plug.Conn.put_req_header("upgrade", "websocket")
             )
    end

    test "case-insensitive on the header value" do
      assert Upgrade.websocket_upgrade?(
               conn(:get, "/")
               |> Plug.Conn.put_req_header("upgrade", "WebSocket")
             )
    end

    test "false when no upgrade header is present" do
      refute Upgrade.websocket_upgrade?(conn(:get, "/"))
    end

    test "false for non-websocket upgrade values" do
      refute Upgrade.websocket_upgrade?(
               conn(:get, "/")
               |> Plug.Conn.put_req_header("upgrade", "h2c")
             )
    end
  end
end
