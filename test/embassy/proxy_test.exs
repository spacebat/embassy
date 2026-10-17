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

  describe "route_label/2" do
    test "route defaults to the mount point" do
      conn = %{conn(:get, "/posts/1") | script_name: ["posts"], path_info: ["1"]}
      assert Proxy.route_label(conn, nil) == "/posts"

      conn = %{conn(:get, "/api/v1/x") | script_name: ["api", "v1"], path_info: ["x"]}
      assert Proxy.route_label(conn, nil) == "/api/v1"
    end

    test "route defaults to \"/\" with empty script_name" do
      assert Proxy.route_label(conn(:get, "/x"), nil) == "/"
    end

    test "explicit route wins" do
      conn = %{conn(:get, "/posts/1") | script_name: ["posts"]}
      assert Proxy.route_label(conn, :legacy) == "legacy"
      assert Proxy.route_label(conn, "rails") == "rails"
    end
  end
end
