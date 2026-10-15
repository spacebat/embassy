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

  alias Embassy.{Config, Proxy}

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

    if websocket_upgrade?(conn) do
      handle_unsupported_upgrade(conn, metadata, start_time)
    else
      forward_request(conn, snapshot, transport, opts, metadata, start_time)
    end
  end

  defp websocket_upgrade?(conn) do
    conn.req_headers
    |> Enum.any?(fn
      {"upgrade", value} -> String.downcase(value) == "websocket"
      _ -> false
    end)
  end

  defp handle_unsupported_upgrade(conn, metadata, start_time) do
    Logger.warning(
      "Embassy.ReverseProxy: WebSocket upgrade not supported in this release. " <>
        "Use embassy_rails for ActionCable, or a future WS-forwarding release of embassy."
    )

    :telemetry.execute(
      [:embassy, :proxy, :exception],
      %{
        monotonic_time: System.monotonic_time(),
        duration: System.monotonic_time() - start_time
      },
      Map.put(metadata, :kind, :unsupported_upgrade)
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      426,
      "Upgrade Required: WebSocket upgrades not supported in this release of embassy."
    )
  end

  defp forward_request(conn, snapshot, transport, opts, metadata, start_time) do
    :telemetry.execute(
      [:embassy, :proxy, :start],
      %{monotonic_time: start_time},
      metadata
    )

    case read_request_body(conn, opts.max_body_length) do
      {:halt_too_large, conn} ->
        handle_body_too_large(conn, metadata, start_time, opts.max_body_length)

      {:halt_body_error, reason, conn} ->
        handle_body_read_error(conn, metadata, start_time, reason)

      {body, conn} ->
        dispatch_upstream(conn, snapshot, transport, body, metadata, start_time)
    end
  end

  defp handle_body_too_large(conn, metadata, start_time, limit) do
    Logger.warning("Embassy.ReverseProxy: request body exceeded max_body_length=#{limit}")

    :telemetry.execute(
      [:embassy, :proxy, :exception],
      %{
        monotonic_time: System.monotonic_time(),
        duration: System.monotonic_time() - start_time
      },
      Map.put(metadata, :kind, :body_too_large)
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(413, "Payload Too Large")
  end

  defp handle_body_read_error(conn, metadata, start_time, reason) do
    Logger.warning("Embassy.ReverseProxy: failed to read request body reason=#{inspect(reason)}")

    :telemetry.execute(
      [:embassy, :proxy, :exception],
      %{
        monotonic_time: System.monotonic_time(),
        duration: System.monotonic_time() - start_time
      },
      Map.merge(metadata, %{kind: :body_read_error, reason: reason})
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Bad Request: failed to read request body")
  end

  defp dispatch_upstream(conn, snapshot, transport, body, metadata, start_time) do
    req = Proxy.build_request(conn, body, transport)

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

  defp read_request_body(conn, max), do: Proxy.read_request_body(conn, max)

  # Relaying the upstream body verbatim is the proxy's job, not an XSS sink.
  # sobelow_skip ["XSS.SendResp"]
  defp copy_response(conn, %Finch.Response{status: status, headers: headers, body: body}) do
    conn
    |> merge_response_headers(headers)
    |> send_resp(status, body)
  end

  defp merge_response_headers(conn, headers) do
    Enum.reduce(Proxy.response_headers(headers), conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end
end
