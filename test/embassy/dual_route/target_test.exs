defmodule Embassy.DualRoute.TargetTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Embassy.DualRoute.{Captured, Target}

  defmodule EchoPlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, opts) do
      status = Keyword.get(opts, :status, 200)
      Plug.Conn.send_resp(conn, status, "from-plug")
    end
  end

  setup do
    snapshot = %{name: :t, finch: TargetTestFinch, task_supervisor: :unused}
    start_supervised!({Finch, name: TargetTestFinch})
    bypass = Bypass.open()
    %{snapshot: snapshot, bypass: bypass}
  end

  describe "plug target" do
    test "run/4 captures the plug response without sending to the real conn", %{snapshot: s} do
      resolved = Target.resolve({:plug, EchoPlug, status: 202})
      conn = conn(:get, "/x")
      assert {:ok, %Captured{status: 202, body: "from-plug"}} = Target.run(resolved, conn, "", s)
      assert conn.state == :unset
    end

    test "run_canonical/4 commits the plug response to the real conn", %{snapshot: s} do
      resolved = Target.resolve({:plug, EchoPlug, status: 200})
      {conn, captured} = Target.run_canonical(resolved, conn(:get, "/x"), "", s)
      assert conn.state == :sent
      assert conn.status == 200
      assert conn.resp_body == "from-plug"
      assert %Captured{status: 200, body: "from-plug"} = captured
    end
  end

  describe "proxy target" do
    test "run/4 forwards via Finch and captures the upstream response", %{
      snapshot: s,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/x", fn conn ->
        Plug.Conn.resp(conn, 200, "from-upstream")
      end)

      resolved = Target.resolve({:proxy, transport: {:http, "http://localhost:#{bypass.port}"}})
      conn = update_in(conn(:get, "/x").req_headers, &[{"host", "localhost"} | &1])

      assert {:ok, %Captured{status: 200, body: "from-upstream"}} =
               Target.run(resolved, conn, "", s)
    end

    test "run_canonical/4 copies the upstream response onto the real conn", %{
      snapshot: s,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/x", fn conn -> Plug.Conn.resp(conn, 200, "up") end)
      resolved = Target.resolve({:proxy, transport: {:http, "http://localhost:#{bypass.port}"}})
      conn = update_in(conn(:get, "/x").req_headers, &[{"host", "localhost"} | &1])
      {conn, captured} = Target.run_canonical(resolved, conn, "", s)
      assert conn.state == :sent
      assert conn.resp_body == "up"
      assert captured.body == "up"
    end
  end
end
