# Embassy

Phoenix-side reverse proxy and per-instance config harness for running
Phoenix as the front door to a backend web application.

Embassy provides:

- **`Embassy.ReverseProxy`** — a terminal `Plug` that forwards the
  current request to an upstream backend over a Unix domain socket or
  an HTTP URL, with canonical `X-Forwarded-*` injection and RFC 7230
  hop-by-hop header handling.
- **`Embassy.BodyCache`** — a `Plug.Parsers` `:body_reader` companion
  so the parser doesn't eat the raw body before the proxy can forward
  it.
- **`Embassy`** supervisor + `Embassy.Config` — per-instance
  configuration plumbing so the library composes cleanly with other
  embassy-family adapters (`embassy_rails`, future siblings).
- `:telemetry` events at `[:embassy, :proxy, :start | :stop | :exception]`.

This release does *not* include streaming bodies, WebSocket
forwarding, retries, or HTTP/2 to upstream — those are scoped for
later releases or sibling packages. See `CHANGELOG.md` for the v0.1
scope.

## Installation

Add `:embassy` to your `mix.exs` deps:

```elixir
def deps do
  [
    {:embassy, "~> 0.1"}
  ]
end
```

## Quick wiring example

```elixir
# application.ex
children = [
  {Finch, name: MyApp.Finch},
  {Embassy, name: MyApp.Embassy, finch: MyApp.Finch},
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :one_for_one)
```

```elixir
# endpoint.ex (only on routes that proxy POST/PUT with parsed bodies)
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Jason,
  body_reader: {Embassy.BodyCache, :read_body, []}
```

```elixir
# router.ex
scope "/" do
  pipe_through :api

  forward "/", Embassy.ReverseProxy,
    embassy: MyApp.Embassy,
    transport: {:uds, "/tmp/puma.sock"}
end
```

For an HTTP backend instead of UDS:

```elixir
forward "/", Embassy.ReverseProxy,
  embassy: MyApp.Embassy,
  transport: {:http, "http://upstream.internal:3000"}
```

## Augmentation

Embassy doesn't introduce hook abstractions — `Plug` already has them:

- **Request side:** put any plug *before* `Embassy.ReverseProxy` in your
  pipeline. Auth, rate-limiting, request-ID injection, header rewriting.
- **Response side:** use `Plug.Conn.register_before_send/2` from an
  earlier plug to mutate the response. Embassy fires these callbacks on
  every path it sends a response on — 200, 426, 502, 413.
- **Observation:** attach a `:telemetry` handler for
  `[:embassy, :proxy, :*]`.

## Composition with `emissary`

Embassy and `emissary` are independent libraries that compose at the
consumer level. For a single-node Rails-behind-Phoenix deploy:

```elixir
children = [
  {Finch, name: MyApp.Finch},
  {Embassy, name: MyApp.Embassy, finch: MyApp.Finch},
  {Emissary.Supervisor, name: MyApp.Emissary, workers: [
    [name: :puma, mode: :persistent, protocol: :raw, runner: "priv/start_puma.sh"]
  ]},
  MyAppWeb.Endpoint
]
```

Emissary supervises Puma; embassy reverse-proxies to the UDS Puma is
listening on.

## Status

v0.1.0-dev. Not yet published to Hex.

## License

MIT. See `LICENSE`.
