# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(no unreleased changes)

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
