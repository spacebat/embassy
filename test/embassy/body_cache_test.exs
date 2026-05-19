defmodule Embassy.BodyCacheTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "read_body/2 returns the body and stashes it on assigns" do
    conn =
      conn(:post, "/", "hello world")
      |> Plug.Conn.put_req_header("content-type", "text/plain")

    assert {:ok, "hello world", conn} = Embassy.BodyCache.read_body(conn, [])
    assert Embassy.BodyCache.fetch(conn) == "hello world"
  end

  test "read_body/2 with chunked input concatenates correctly via fetch/1" do
    big = String.duplicate("x", 5_000)

    conn =
      conn(:post, "/", big)
      |> Plug.Conn.put_req_header("content-type", "text/plain")

    assert {:ok, ^big, conn} = Embassy.BodyCache.read_body(conn, length: 100_000)
    assert Embassy.BodyCache.fetch(conn) == big
  end

  test "fetch/1 returns empty binary when no body has been cached" do
    conn = conn(:get, "/")
    assert Embassy.BodyCache.fetch(conn) == ""
  end
end
