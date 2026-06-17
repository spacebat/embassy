defmodule Embassy.DualRoute.CaptureAdapterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Embassy.DualRoute.{Captured, CaptureAdapter}

  defp run(plug_fun, method \\ "GET", body \\ "") do
    template = conn(String.downcase(method) |> String.to_atom(), "/probe", body)
    capture_conn = CaptureAdapter.build_conn(template, body)
    capture_conn = plug_fun.(capture_conn)
    CaptureAdapter.captured(capture_conn)
  end

  test "captures a send_resp response" do
    captured =
      run(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(201, ~s({"ok":true}))
      end)

    assert %Captured{status: 201, body: ~s({"ok":true})} = captured
    assert {"content-type", "application/json"} in captured.headers
  end

  test "captures a chunked response by concatenating chunks" do
    captured =
      run(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

    assert %Captured{status: 200, body: "foobar"} = captured
  end

  test "serves the request body to the plug via read_body" do
    captured =
      run(
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, "echo:" <> body)
        end,
        "POST",
        "hello"
      )

    assert captured.body == "echo:hello"
  end
end
