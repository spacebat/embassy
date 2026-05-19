defmodule Embassy.ReverseProxy do
  @moduledoc """
  Terminal `Plug` that forwards the current request to an upstream
  backend (UDS or HTTP), reads the full response, and copies it onto
  the conn.

  See the README for the full wiring example. See the v0.1 spec at
  `docs/superpowers/specs/2026-05-19-embassy-v0.1-design.md` for the
  design rationale, error handling matrix, and telemetry contract.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  alias Embassy.{BodyCache, Config}

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

  @default_max_body_length 50_000_000

  @impl Plug
  def init(opts) do
    embassy = Keyword.fetch!(opts, :embassy)
    transport = Keyword.fetch!(opts, :transport)
    max_body_length = Keyword.get(opts, :max_body_length, @default_max_body_length)

    %{
      embassy: embassy,
      transport: transport,
      max_body_length: max_body_length
    }
  end

  @impl Plug
  def call(conn, %{embassy: embassy, transport: transport} = opts) do
    snapshot = Config.snapshot(embassy)
    do_call(conn, snapshot, transport, opts)
  end

  defp do_call(conn, snapshot, transport, opts) do
    start_time = System.monotonic_time()

    metadata = %{
      instance: snapshot.name,
      method: conn.method,
      request_path: conn.request_path,
      transport: transport
    }

    :telemetry.execute(
      [:embassy, :proxy, :start],
      %{monotonic_time: start_time},
      metadata
    )

    {body, conn} = read_request_body(conn, opts.max_body_length)
    req = build_request(conn, body, transport)

    case Finch.request(req, snapshot.finch) do
      {:ok, %Finch.Response{} = resp} ->
        conn = copy_response(conn, resp)

        :telemetry.execute(
          [:embassy, :proxy, :stop],
          %{
            monotonic_time: System.monotonic_time(),
            duration: System.monotonic_time() - start_time,
            request_body_bytes: byte_size(body),
            response_body_bytes: byte_size(resp.body)
          },
          Map.put(metadata, :status, resp.status)
        )

        conn

      {:error, reason} ->
        Logger.error(
          "Embassy.ReverseProxy: upstream error transport=#{inspect(transport)} reason=#{inspect(reason)}"
        )

        :telemetry.execute(
          [:embassy, :proxy, :exception],
          %{
            monotonic_time: System.monotonic_time(),
            duration: System.monotonic_time() - start_time
          },
          Map.merge(metadata, %{kind: :upstream_error, reason: reason})
        )

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Bad gateway: upstream unreachable")
    end
  end

  defp read_request_body(conn, max) do
    case BodyCache.fetch(conn) do
      "" ->
        case read_body(conn, length: max) do
          {:ok, body, conn} -> {body, conn}
          {:more, _, conn} -> {:halt_too_large, conn}
        end

      cached ->
        {cached, conn}
    end
  end

  defp build_request(conn, body, transport) do
    {url, finch_opts} = transport_to_url_and_opts(conn, transport)
    headers = forward_headers(conn)
    Finch.build(conn.method, url, headers, body, finch_opts)
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
    Enum.reject(conn.req_headers, fn {name, _} -> name in @hop_by_hop end)
  end

  defp conn_host(conn) do
    case List.keyfind(conn.req_headers, "host", 0) do
      {"host", value} -> value
      _ -> conn.host
    end
  end

  defp copy_response(conn, %Finch.Response{status: status, headers: headers, body: body}) do
    conn
    |> merge_response_headers(headers)
    |> send_resp(status, body)
  end

  defp merge_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      if String.downcase(name) in @hop_by_hop do
        acc
      else
        put_resp_header(acc, String.downcase(name), value)
      end
    end)
  end
end
