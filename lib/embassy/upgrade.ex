defmodule Embassy.Upgrade do
  @moduledoc """
  Generic WebSocket-upgrade Plug.

  Negotiates a subprotocol from the client's `sec-websocket-protocol`
  header against a consumer-configured list. Embassy treats every
  subprotocol as an opaque string; it does not know about
  `"actioncable-v1-json"`, `"graphql-ws"`, or any other named
  protocol. Adapters such as `Embassy.Rails` plug their `WebSock`
  handler into this seam.

  ## Usage

      Embassy.Upgrade.call(conn, %{
        handler: SomeWebSockModule,
        init_arg: %{...consumer-owned state...},
        subprotocols: ["actioncable-v1-json"],
        instance: SomeAdapter.Instance
      })

  When used as a `Plug` (via `forward "/cable", Embassy.Upgrade, ...`)
  the keyword opts are normalised by `init/1`.

  ## Behaviour

  - If the request is not a WebSocket upgrade, responds 426 and emits
    `[:embassy, :upgrade, :rejected]` with `kind: :not_an_upgrade`.
  - If no configured subprotocol matches the client's offer, responds
    426 with `kind: :no_subprotocol`.
  - Otherwise echoes the chosen subprotocol via response header and
    calls `WebSockAdapter.upgrade/4` with the consumer's handler and
    `init_arg`.

  The first configured subprotocol that appears in the client's offer
  wins (configured-list ordering, not client-list ordering). Consumers
  pass `:instance` purely so rejection telemetry has a meaningful
  scope tag.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @default_timeout 60_000

  @impl Plug
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)

    %{
      handler: handler,
      init_arg: Keyword.get(opts, :init_arg),
      subprotocols: Keyword.fetch!(opts, :subprotocols),
      instance: Keyword.get(opts, :instance),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @impl Plug
  def call(conn, %{} = opts) do
    cond do
      not websocket_upgrade?(conn) ->
        reject(conn, opts.instance, :not_an_upgrade, [])

      true ->
        requested = requested_subprotocols(conn)

        case Enum.find(opts.subprotocols, &(&1 in requested)) do
          nil ->
            reject(conn, opts.instance, :no_subprotocol, requested)

          chosen ->
            conn
            |> put_resp_header("sec-websocket-protocol", chosen)
            |> WebSockAdapter.upgrade(opts.handler, opts.init_arg, timeout: opts.timeout)
            |> halt()
        end
    end
  end

  @doc """
  Returns true when the conn's `upgrade` header requests a WebSocket
  upgrade. Exposed for consumers that want to short-circuit non-WS
  traffic to a different plug (typically a reverse proxy).
  """
  def websocket_upgrade?(conn) do
    Enum.any?(conn.req_headers, fn
      {"upgrade", value} -> String.downcase(value) == "websocket"
      _ -> false
    end)
  end

  defp requested_subprotocols(conn) do
    conn
    |> get_req_header("sec-websocket-protocol")
    |> Enum.flat_map(&String.split(&1, ~r/\s*,\s*/, trim: true))
  end

  defp reject(conn, instance, kind, requested) do
    Logger.warning("Embassy.Upgrade: rejected upgrade (#{kind}); requested=#{inspect(requested)}")

    :telemetry.execute(
      [:embassy, :upgrade, :rejected],
      %{monotonic_time: System.monotonic_time()},
      %{instance: instance, kind: kind, requested_subprotocols: requested}
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(426, "Upgrade Required: WebSocket upgrade not accepted")
    |> halt()
  end
end
