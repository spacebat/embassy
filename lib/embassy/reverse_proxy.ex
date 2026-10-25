defmodule Embassy.ReverseProxy do
  @moduledoc """
  Terminal `Plug` that forwards the current request to an upstream
  backend (UDS or HTTP), reads the full response, and copies it onto
  the conn.

  See the README for the full wiring example and the "Metrics and
  dashboards" section.

  ## Options

    * `:embassy` (required) — the `Embassy` instance name.
    * `:transport` (required) — `{:uds, path}` or `{:http, base_url}`.
    * `:max_body_length` — request body limit in bytes (default
      `50_000_000`); larger bodies get a 413.
    * `:receive_timeout` — milliseconds to wait on the upstream, passed to
      `Finch.request/3` (default `15_000`). An upstream that stays silent
      longer yields the `:upstream_error` path (502).
    * `:route` — telemetry route label (string or atom). Defaults to the
      mount point from `conn.script_name`, `"/"` when unmounted.
      Set it explicitly under a `Plug.Router` `forward` with dynamic
      segments, whose concrete values would otherwise become the label.

  ## Telemetry

    * `[:embassy, :proxy, :start]` — `%{monotonic_time}`.
    * `[:embassy, :proxy, :stop]` — `%{monotonic_time, duration,
      request_body_bytes, response_body_bytes}`, metadata adds `status`.
    * `[:embassy, :proxy, :exception]` — `%{monotonic_time, duration}`,
      metadata adds `kind` (`:unsupported_upgrade`, `:body_too_large`,
      `:body_read_error`, `:upstream_error`) and, for the last two,
      `reason`.

  Metadata on all three: `instance`, `method`, `request_path`,
  `transport`, `route`, and `role` (`:direct` here; `Embassy.DualRoute`
  proxy targets emit `:canonical` or `:shadow`). `request_path` is for
  handlers, never a metric tag.
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
      max_body_length: max_body_length,
      receive_timeout: Keyword.get(opts, :receive_timeout, Proxy.default_receive_timeout()),
      route: Keyword.get(opts, :route)
    }
  end

  @impl Plug
  def call(conn, %{embassy: embassy, transport: transport} = opts) do
    snapshot = Config.snapshot(embassy)
    do_call(conn, snapshot, transport, opts)
  end

  defp do_call(conn, snapshot, transport, opts) do
    route = Proxy.route_label(conn, opts.route)
    metadata = Proxy.event_metadata(conn, snapshot.name, transport, route, :direct)

    if websocket_upgrade?(conn) do
      handle_unsupported_upgrade(conn, metadata, System.monotonic_time())
    else
      forward_request(conn, snapshot, transport, opts, metadata)
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

    Proxy.emit_exception(metadata, start_time, :unsupported_upgrade)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      426,
      "Upgrade Required: WebSocket upgrades not supported in this release of embassy."
    )
  end

  defp forward_request(conn, snapshot, transport, opts, metadata) do
    start_time = Proxy.emit_start(metadata)

    case read_request_body(conn, opts.max_body_length) do
      {:halt_too_large, conn} ->
        handle_body_too_large(conn, metadata, start_time, opts.max_body_length)

      {:halt_body_error, reason, conn} ->
        handle_body_read_error(conn, metadata, start_time, reason)

      {body, conn} ->
        dispatch_upstream(conn, snapshot, transport, body, metadata, start_time, opts)
    end
  end

  defp handle_body_too_large(conn, metadata, start_time, limit) do
    Logger.warning("Embassy.ReverseProxy: request body exceeded max_body_length=#{limit}")

    Proxy.emit_exception(metadata, start_time, :body_too_large)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(413, "Payload Too Large")
  end

  defp handle_body_read_error(conn, metadata, start_time, reason) do
    Logger.warning("Embassy.ReverseProxy: failed to read request body reason=#{inspect(reason)}")

    Proxy.emit_exception(metadata, start_time, :body_read_error, %{reason: reason})

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Bad Request: failed to read request body")
  end

  defp dispatch_upstream(conn, snapshot, transport, body, metadata, start_time, opts) do
    req = Proxy.build_request(conn, body, transport)

    case Proxy.forward(req, body, snapshot.finch, metadata, start_time,
           receive_timeout: opts.receive_timeout
         ) do
      {:ok, resp} ->
        copy_response(conn, resp)

      {:error, reason} ->
        Logger.error(
          "Embassy.ReverseProxy: upstream error transport=#{inspect(transport)} reason=#{inspect(reason)}"
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
    |> Proxy.put_response_headers(headers)
    |> send_resp(status, body)
  end
end
