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
- **`Embassy.Upgrade`** — a generic WebSocket-upgrade `Plug`. It
  negotiates a subprotocol from the client's `sec-websocket-protocol`
  header against a consumer-configured list (treating every
  subprotocol as an opaque string) and hands off to a consumer-supplied
  `WebSock` handler. Runtime adapters such as `embassy_rails` plug their
  handler into this seam.
- **`Embassy`** supervisor + `Embassy.Config` — per-instance
  configuration plumbing so the library composes cleanly with other
  embassy-family adapters (`embassy_rails`, future siblings).
- `:telemetry` events at `[:embassy, :proxy, :start | :stop | :exception]`
  and `[:embassy, :upgrade, :rejected]`.

This release does *not* include streaming bodies, WebSocket frame
*forwarding* to an upstream, retries, or HTTP/2 to upstream — those are
scoped for later releases or sibling packages. (`Embassy.Upgrade`
*terminates* a WebSocket and delegates to a handler; it does not proxy
frames to a backend.) See `CHANGELOG.md` for the full scope.

## Installation

### With Igniter (recommended)

```sh
mix igniter.install embassy
```

This wires Embassy into your Phoenix app: adds `Finch` and `Embassy` to
your supervision tree, a reverse-proxy forward and a `/cable` WebSocket
upgrade to your router, and the `Embassy.BodyCache` body reader to your
endpoint's `Plug.Parsers`. It prompts for the instance name and backend
transport; pass `--name`, `--finch`, `--transport uds|http`, `--address`
to skip the prompts, or `--no-proxy` / `--no-cable` / `--no-parsers` to
omit a step. The `/cable` route is scaffolded with a placeholder handler
— supply a `WebSock` handler (or install `embassy_rails`) to activate it.

Prefer to wire it by hand? The manual steps follow.

### By hand

Add `:embassy` to your `mix.exs` deps:

```elixir
def deps do
  [
    {:embassy, "~> 0.3"}
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

## Terminating WebSockets

`Embassy.Upgrade` negotiates the WebSocket upgrade and hands the
connection to a `WebSock` handler you provide. Embassy itself ships no
handler — that is the runtime adapter's job (e.g. `embassy_rails`
supplies an ActionCable/AnyCable handler). Mount it ahead of the
catch-all proxy forward:

```elixir
# router.ex
scope "/" do
  pipe_through :api

  forward "/cable", Embassy.Upgrade,
    handler: MyApp.CableHandler,
    subprotocols: ["actioncable-v1-json"],
    instance: MyApp.Embassy

  forward "/", Embassy.ReverseProxy,
    embassy: MyApp.Embassy,
    transport: {:uds, "/tmp/puma.sock"}
end
```

`handler` is any module implementing the `WebSock` behaviour;
`subprotocols` is an opaque list matched (configured-list ordering
wins) against the client's offer; `instance` tags rejection telemetry.
Non-upgrade requests and unmatched subprotocols get a `426` plus an
`[:embassy, :upgrade, :rejected]` event.

## Strangler-fig migration with DualRoute

`Embassy.DualRoute` runs two backends for the same route - a `control`
and a `candidate` - returns one (the `canonical` side) to the client, and
runs the other as an asynchronous shadow it compares against. Use it to
migrate a route from a legacy backend to a native handler with zero
user-facing latency cost and a measurable diff rate.

```elixir
# router.ex
forward "/posts", Embassy.DualRoute,
  embassy: MyApp.Embassy,
  control:   {:proxy, transport: {:uds, "/tmp/puma.sock"}},
  candidate: {:plug, MyAppWeb.PostsController, []},
  canonical: :control,             # legacy wins; candidate shadows
  comparator: :json                # :status_only | :json | :html | :exact | fn/2
```

Start with `canonical: :control`. Watch `[:embassy, :dual_route, :diff]`
telemetry; when the diff rate hits zero, flip to `canonical: :candidate`
(the new handler now serves, the proxy shadows), then retire the dual
route. `methods` defaults to `["GET"]` for side-effect safety;
`sample_rate` (0.0..1.0) throttles shadow volume; a `reporter` module
implementing `Embassy.DualRoute.Reporter` can persist diffs.

## Metrics and dashboards

Embassy emits `:telemetry` events for every request it sends upstream,
every DualRoute dispatch and verdict, rejected upgrades, and upstream
health probes. `Embassy.Telemetry.metrics/0` turns them into
`Telemetry.Metrics` definitions for your reporter. It needs the optional
dependency:

```elixir
{:telemetry_metrics, "~> 1.0"}
```

```elixir
# lib/my_app_web/telemetry.ex
def metrics do
  Embassy.Telemetry.metrics() ++
    [
      # Phoenix's generator reports router dispatch as a `summary`, which
      # TelemetryMetricsPrometheus.Core drops. Add a counter for the
      # Rails-share denominator below. Route patterns are bounded.
      counter("phoenix.router_dispatch.stop.count", tags: [:route])
      # ... your own metrics
    ]
end
```

Tags are low cardinality: `instance`, a route label, `role`, `status`,
`kind`, `upstream`, and the DualRoute `canonical` / `served_by` /
`sampled`. Never a request path or error reason.

### Route labels

`Embassy.ReverseProxy` and `Embassy.DualRoute` take a `:route` option (a
string or atom). Without it the label is the mount point:
`forward "/posts", ...` gives `"/posts"`, the catch-all `forward "/"`
gives `"/"`.

The default only works for a static `forward`, the one place Phoenix sets
`conn.script_name`. Set `:route` yourself when:

- **DualRoute is mounted with a verb macro** (`get "/posts/:id",
  Embassy.DualRoute, ...`). There is no mount point, so every such
  experiment would be labelled `"/"` and merge with the catch-all proxy.
- **You use a `Plug.Router` `forward` with dynamic segments**
  (`forward "/users/:id", ...`). Those segments land in `script_name` as
  concrete values, so the default label would carry user IDs and explode
  metric cardinality.

Proxy events carry a `role`: `:direct` from `Embassy.ReverseProxy`,
`:canonical` from a DualRoute proxy target whose response the client
gets, `:shadow` from one run as the comparison shadow. Requests Rails
served for clients are the ones with `role != shadow`, whichever
migration style you use.

### PromQL

Written for `TelemetryMetricsPrometheus.Core` name mangling (dots become
underscores, distributions add `_bucket` / `_sum` / `_count`). Other
reporters name things differently.

Share of client requests still served by Rails, router-wide. Works for
both router precedence (native routes first, catch-all proxy) and
DualRoute. Exclude `/cable` and any health or metrics routes from the
denominator:

```promql
sum(rate(embassy_proxy_duration_count{role!="shadow"}[5m]))
/
sum(rate(phoenix_router_dispatch_stop_count{route!~"/cable.*|/health.*|/metrics"}[5m]))
```

DualRoute routes, by who serves them (`proxy` is still Rails):

```promql
sum by (route, served_by) (rate(embassy_dual_route_dispatch_count[5m]))
```

p95 proxy latency by route (ms):

```promql
histogram_quantile(0.95,
  sum by (route, le) (rate(embassy_proxy_duration_bucket{role!="shadow"}[5m])))
```

Upstream errors by kind:

```promql
sum by (kind) (rate(embassy_proxy_exception_count[5m]))
```

Upstream up (needs `:upstreams`, below):

```promql
embassy_upstream_up
```

DualRoute diff rate by route:

```promql
sum by (route) (rate(embassy_dual_route_diff_count[5m]))
/
(sum by (route) (rate(embassy_dual_route_diff_count[5m]))
 + sum by (route) (rate(embassy_dual_route_match_count[5m])))
```

### Upstream health

Give the instance its upstreams and it probes them:

```elixir
{Embassy,
 name: MyApp.Embassy,
 finch: MyApp.Finch,
 upstreams: [rails: {:uds, "/tmp/puma.sock"}],
 health: [interval: 5_000, timeout: 1_000]}
```

Each upstream gets `HEAD /` every `interval` ms. Any HTTP response is up;
a connection error or timeout is down. Results go to the
`embassy_upstream_up` gauge and `Embassy.Health.status(MyApp.Embassy)`
(`%{rails: :up}`), and a transition logs once (a warning going down, an
info line coming back).

This is **not** a readiness check. Once some routes are served by
Phoenix, a Rails outage should not take Phoenix pods out of the Service,
so embassy never wires upstream health into readiness or liveness. If
you want that anyway, call `Embassy.Health.status/1` from your own
readiness endpoint.

## Augmentation

Embassy doesn't introduce hook abstractions — `Plug` already has them:

- **Request side:** put any plug *before* `Embassy.ReverseProxy` in your
  pipeline. Auth, rate-limiting, request-ID injection, header rewriting.
- **Response side:** use `Plug.Conn.register_before_send/2` from an
  earlier plug to mutate the response. Embassy fires these callbacks on
  every path it sends a response on — 200, 426, 502, 413.
- **Observation:** attach a `:telemetry` handler for
  `[:embassy, :proxy, :*]`.

## Composition with `attache`

Embassy and `attache` are independent libraries that compose at the
consumer level. For a single-node Rails-behind-Phoenix deploy:

```elixir
children = [
  {Finch, name: MyApp.Finch},
  {Embassy, name: MyApp.Embassy, finch: MyApp.Finch},
  {Attache.Supervisor, workers: [
    [name: :puma, mode: :persistent, protocol: :raw, runner: "priv/start_puma.sh"]
  ]},
  MyAppWeb.Endpoint
]
```

Attache supervises Puma; embassy reverse-proxies to the UDS Puma is
listening on.

## Status

v0.3.0. Not yet published to Hex.

## License

MIT. See `LICENSE`.
