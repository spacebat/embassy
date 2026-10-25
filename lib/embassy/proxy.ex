defmodule Embassy.Proxy do
  @moduledoc """
  Framework-agnostic HTTP forwarding helpers shared by
  `Embassy.ReverseProxy` and `Embassy.DualRoute`.

  Builds a `Finch.Request` from a `Plug.Conn` (UDS or HTTP transport),
  reads the request body (honouring `Embassy.BodyCache`), filters
  hop-by-hop headers on responses, and emits the shared
  `[:embassy, :proxy, :start | :stop | :exception]` events.
  """

  import Plug.Conn, only: [read_body: 2]

  alias Embassy.BodyCache

  @default_receive_timeout 15_000

  @doc "Default upstream receive timeout in milliseconds."
  @spec default_receive_timeout() :: pos_integer()
  def default_receive_timeout, do: @default_receive_timeout

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

  @doc """
  Put upstream response headers on `conn`, hop-by-hop filtered. Each name
  upstream sends replaces any value already on the conn (such as Plug's
  default `cache-control`), and repeated headers such as `set-cookie` are
  all kept, in order.
  """
  @spec put_response_headers(Plug.Conn.t(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def put_response_headers(conn, headers) do
    headers = response_headers(headers)
    names = MapSet.new(headers, &elem(&1, 0))
    kept = Enum.reject(conn.resp_headers, fn {name, _} -> MapSet.member?(names, name) end)
    %{conn | resp_headers: kept ++ headers}
  end

  @doc """
  Low-cardinality route label for telemetry. An explicit `route` (atom or
  string) wins; otherwise the mount point from `conn.script_name`, so
  `forward "/posts", ...` gives `"/posts"` and an unmounted plug gives
  `"/"`.
  """
  @spec route_label(Plug.Conn.t(), String.t() | atom() | nil) :: String.t()
  def route_label(conn, nil), do: "/" <> Enum.join(conn.script_name, "/")
  def route_label(_conn, route) when is_atom(route), do: Atom.to_string(route)
  def route_label(_conn, route) when is_binary(route), do: route

  @doc "Metadata shared by every `[:embassy, :proxy, *]` event."
  @spec event_metadata(
          Plug.Conn.t(),
          atom(),
          term(),
          String.t(),
          :direct | :canonical | :shadow
        ) :: map()
  def event_metadata(conn, instance, transport, route, role) do
    %{
      instance: instance,
      method: conn.method,
      request_path: conn.request_path,
      transport: transport,
      route: route,
      role: role
    }
  end

  @doc "Emit `[:embassy, :proxy, :start]` and return the start time."
  @spec emit_start(map()) :: integer()
  def emit_start(metadata) do
    start_time = System.monotonic_time()
    :telemetry.execute([:embassy, :proxy, :start], %{monotonic_time: start_time}, metadata)
    start_time
  end

  @doc "Emit `[:embassy, :proxy, :exception]` with `kind` and any `extra` metadata."
  @spec emit_exception(map(), integer(), atom(), map()) :: :ok
  def emit_exception(metadata, start_time, kind, extra \\ %{}) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:embassy, :proxy, :exception],
      %{monotonic_time: now, duration: now - start_time},
      metadata |> Map.put(:kind, kind) |> Map.merge(extra)
    )
  end

  @doc """
  Send `req` through `finch`, emitting `:stop` on a response or an
  `:exception` of kind `:upstream_error` (with `reason`) on failure.

  Options: `:receive_timeout` (milliseconds, default `15_000`) is passed to
  `Finch.request/3`.
  """
  @spec forward(Finch.Request.t(), binary(), atom(), map(), integer(), keyword()) ::
          {:ok, Finch.Response.t()} | {:error, term()}
  def forward(req, body, finch, metadata, start_time, opts \\ []) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    case Finch.request(req, finch, receive_timeout: receive_timeout) do
      {:ok, %Finch.Response{} = resp} ->
        now = System.monotonic_time()

        :telemetry.execute(
          [:embassy, :proxy, :stop],
          %{
            monotonic_time: now,
            duration: now - start_time,
            request_body_bytes: byte_size(body),
            response_body_bytes: byte_size(resp.body)
          },
          Map.put(metadata, :status, resp.status)
        )

        {:ok, resp}

      {:error, reason} ->
        emit_exception(metadata, start_time, :upstream_error, %{reason: reason})
        {:error, reason}
    end
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
