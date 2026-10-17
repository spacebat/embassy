# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Route labels on proxy and DualRoute telemetry. `Embassy.ReverseProxy`
  and `Embassy.DualRoute` take a `:route` option; without it the label is
  the mount point from `conn.script_name` (`"/"` when unmounted).
- `[:embassy, :proxy, *]` events now carry `route` and `role`
  (`:direct`, `:canonical`, `:shadow`), and DualRoute proxy targets emit
  them too, so proxied traffic is visible in both migration styles.
- `[:embassy, :dual_route, :dispatch]`, once per request a DualRoute
  serves, with `canonical`, `served_by` (`:proxy | :plug`) and `sampled`.
- `Embassy.Health`: opt-in per-instance upstream monitor (`:upstreams`
  and `:health` options on `Embassy`), `[:embassy, :upstream, :check]`
  events, transition logging, `status/1` and `check/3`. A probe that
  outlives `:timeout` is killed and recorded as down. Not a readiness
  check.
- `Embassy.Telemetry.metrics/0`, `Telemetry.Metrics` definitions over
  embassy events, behind the optional `telemetry_metrics` dependency.
- README "Metrics and dashboards" section with PromQL.

### Changed

- **Breaking:** DualRoute telemetry `route` and
  `Embassy.DualRoute.Result.route` are now the route label; the request
  path moved to a new `request_path` key, and `Result` requires it.
- **Breaking:** `Embassy.DualRoute.Target.run/5` and `run_canonical/5`
  take a fifth argument, a `%{route, role}` context (they were arity 4).
- `Embassy.ReverseProxy` emits `:stop` once the upstream responds,
  before the response is sent to the client.

## [0.3.0] - 2026-10-18

### Added

- `Embassy.DualRoute`, a Scientist-style strangler-fig plug. Returns one
  backend's response (the `canonical` side) while running the other as an
  async shadow under a per-instance `Task.Supervisor`, compares them with
  a named or custom comparator (`:status_only`, `:json`, `:html`,
  `:exact`), and reports via `[:embassy, :dual_route, :match | :diff |
  :error]` telemetry and an optional `Embassy.DualRoute.Reporter`. Both
  sides are uniform target specs: `{:proxy, transport: ...}` or
  `{:plug, Module, opts}`.
- `Embassy.Proxy`, shared HTTP-forwarding helpers extracted from
  `Embassy.ReverseProxy`.
- Each `Embassy` instance now starts a `Task.Supervisor` (surfaced on the
  config snapshot as `task_supervisor`).

## [0.2.0] - 2026-06-16

### Added

- `mix embassy.install` Igniter task that wires Embassy into a Phoenix
  app (supervision tree, router forwards, `/cable` upgrade, body
  reader), composably via `--no-proxy` / `--no-cable` / `--no-parsers`.
  The task module is guarded with `Code.ensure_loaded?/1` so the package
  still compiles without the optional `:igniter` dependency (the task
  becomes a stub that raises a helpful error), letting igniter-free
  path-dep consumers build embassy.
- `Embassy.Upgrade` generic WebSocket-upgrade Plug. Negotiates an
  opaque-string subprotocol from the client's `sec-websocket-protocol`
  header against a consumer-configured list and hands off to a
  consumer-supplied `WebSock` handler. Embassy never names a specific
  subprotocol; adapters like `embassy_rails` plug in their handler and
  the protocol constant.
- `Embassy.Upgrade.websocket_upgrade?/1` helper for consumers that
  want to short-circuit non-WS traffic to a different plug.
- `:telemetry` events: `[:embassy, :upgrade, :rejected]` with meta
  `%{instance, kind, requested_subprotocols}` where `kind` is one of
  `:not_an_upgrade | :no_subprotocol`.

### Changed

- New dep: `:websock_adapter ~> 0.5`.

## [0.1.0] - 2026-05-19

### Added

- `Embassy` supervisor and `child_spec/1` for consumer-tree mounting.
- `Embassy.Config` per-instance snapshot accessor backed by Registry meta.
- `Embassy.ReverseProxy` terminal plug supporting UDS and HTTP transports,
  with RFC 7230 hop-by-hop header handling and canonical X-Forwarded-*
  injection.
- `Embassy.BodyCache` `Plug.Parsers` `:body_reader` companion.
- `:telemetry` events: `[:embassy, :proxy, :start | :stop | :exception]`.
- 400 + `:body_read_error` telemetry on client body read failures.
