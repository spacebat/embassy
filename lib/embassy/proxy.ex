defmodule Embassy.Proxy do
  @moduledoc """
  Framework-agnostic HTTP forwarding helpers shared by
  `Embassy.ReverseProxy` and `Embassy.DualRoute`.

  Builds a `Finch.Request` from a `Plug.Conn` (UDS or HTTP transport),
  reads the request body (honouring `Embassy.BodyCache`), and filters
  hop-by-hop headers on responses.
  """

  import Plug.Conn, only: [read_body: 2]

  alias Embassy.BodyCache

  @hop_by_hop ~w(
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    transfer-encoding
    upgrade
  )

  @doc "Hop-by-hop header names (RFC 7230), lower-cased."
  @spec hop_by_hop() :: [String.t()]
  def hop_by_hop, do: @hop_by_hop

  @doc """
  Read the request body once, preferring an `Embassy.BodyCache`-stashed
  copy. Returns `{body, conn}` or a halt tuple when the body is too
  large or unreadable.
  """
  @spec read_request_body(Plug.Conn.t(), non_neg_integer()) ::
          {binary(), Plug.Conn.t()}
          | {:halt_too_large, Plug.Conn.t()}
          | {:halt_body_error, term(), Plug.Conn.t()}
  def read_request_body(conn, max) do
    case BodyCache.fetch(conn) do
      "" ->
        case read_body(conn, length: max) do
          {:ok, body, conn} -> {body, conn}
          {:more, _, conn} -> {:halt_too_large, conn}
          {:error, reason} -> {:halt_body_error, reason, conn}
        end

      cached ->
        {cached, conn}
    end
  end

  @doc "Build a `Finch.Request` forwarding `conn` (with `body`) to `transport`."
  @spec build_request(Plug.Conn.t(), binary(), {:uds, String.t()} | {:http, String.t()}) ::
          Finch.Request.t()
  def build_request(conn, body, transport) do
    {url, finch_opts} = transport_to_url_and_opts(conn, transport)
    headers = forward_headers(conn)
    Finch.build(conn.method, url, headers, body, finch_opts)
  end

  @doc "Filter hop-by-hop headers from a response header list and downcase names."
  @spec response_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def response_headers(headers) do
    Enum.flat_map(headers, fn {name, value} ->
      down = String.downcase(name)
      if down in @hop_by_hop, do: [], else: [{down, value}]
    end)
  end

  defp transport_to_url_and_opts(conn, {:uds, path}) do
    {url_from_conn(conn, "http://" <> conn_host(conn)), [unix_socket: path]}
  end

  defp transport_to_url_and_opts(conn, {:http, base_url}) do
    {url_from_conn(conn, base_url), []}
  end

  defp url_from_conn(conn, base) do
    qs = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    base <> conn.request_path <> qs
  end

  defp forward_headers(conn) do
    conn.req_headers
    |> Enum.reject(fn {name, _} -> name in @hop_by_hop end)
    |> add_or_append_xff(peer_address(conn))
    |> add_if_absent("x-forwarded-proto", Atom.to_string(conn.scheme))
    |> add_if_absent("x-forwarded-host", conn_host(conn))
  end

  defp add_or_append_xff(headers, peer) do
    case List.keyfind(headers, "x-forwarded-for", 0) do
      {"x-forwarded-for", existing} ->
        List.keystore(
          headers,
          "x-forwarded-for",
          0,
          {"x-forwarded-for", existing <> ", " <> peer}
        )

      nil ->
        [{"x-forwarded-for", peer} | headers]
    end
  end

  defp add_if_absent(headers, name, value) do
    case List.keyfind(headers, name, 0) do
      nil -> [{name, value} | headers]
      _ -> headers
    end
  end

  defp peer_address(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
    end
  end

  defp conn_host(conn) do
    case List.keyfind(conn.req_headers, "host", 0) do
      {"host", value} -> value
      _ -> conn.host
    end
  end
end
