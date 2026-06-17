defmodule Embassy.ProxyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Embassy.Proxy

  test "build_request targets a UDS upstream with a unix_socket option" do
    conn =
      conn(:get, "/posts?page=2")
      |> Map.update!(:req_headers, &[{"host", "example.test"} | &1])

    req = Proxy.build_request(conn, "", {:uds, "/tmp/puma.sock"})

    assert req.method == "GET"
    assert req.path == "/posts"
    assert req.query == "page=2"
    assert req.unix_socket == "/tmp/puma.sock"
  end

  test "build_request targets an HTTP base URL" do
    conn = conn(:post, "/api", "body")
    req = Proxy.build_request(conn, "body", {:http, "http://up.internal:3000"})

    assert req.scheme == :http
    assert req.host == "up.internal"
    assert req.port == 3000
    assert req.path == "/api"
  end

  test "response_headers drops hop-by-hop headers and downcases names" do
    headers = [
      {"Content-Type", "application/json"},
      {"Connection", "close"},
      {"Transfer-Encoding", "chunked"}
    ]

    assert Proxy.response_headers(headers) == [{"content-type", "application/json"}]
  end
end
