# Runtime-specific split

Companion to `PLAN.md`. Captures the decision to split embassy itself
into a runtime-agnostic core plus per-runtime adapter packages, before
the first extraction commit happens — otherwise the next session will
move Rails-specific code into `embassy/lib/embassy/cable/` and have to
move it again immediately.

The cut happens in step 3 of `PLAN.md` (move modules), not after.

This document is the rationale; `PLAN.md` is the prescription. If they
disagree, prefer `PLAN.md` — it's the one that gets executed against.

Note: both `embassy` and `embassy_rails` are hex **libraries**, not
applications. See `CLAUDE.md` for what that implies (no app config, no
demo under `lib/priv/scripts`, tests don't boot a server). The
combined demo lives in `embassy_example`.

## The split

### `embassy` — runtime-agnostic core

- HTTP reverse proxy (UDS + HTTP transports)
- BodyCache plug
- DualRoute / strangler-fig plug (design doc Phase 6)
- Per-instance config + Registry plumbing
- The `Embassy` supervisor and public API shape
- Subprotocol-negotiating WS upgrade **machinery** — the generic
  primitive: read requested subprotocols, echo a configured one, hand
  off to a `WebSock` handler the consumer provides.

### `embassy_rails` — Rails / ActionCable / AnyCable specific

- `Cable.Connection` — the `Phoenix.Socket.Transport` impl that speaks
  AnyCable's command / transmission / stream semantics.
- `RPC` — the HTTP RPC client wired to `/_anycable/*` and AnyCable's
  status-code conventions (0=ERROR, 1=SUCCESS, 2=FAILURE).
- `BroadcastPlug` + `Broadcast` — AnyCable's `/_broadcast` envelope,
  the `stop_streams` field handling, the `actioncable-v1-json`
  subprotocol constant.
- Anything that knows the word "ActionCable".

### Future siblings

- `embassy_django` — Django Channels protocol
- `embassy_phpws` — PHP WebSocket runtimes (ratchetphp, etc.)
- `embassy_perlws` — Perl, if anyone asks
- `embassy_phoenix_compat` — even Phoenix Channels, for migrating off
  one Phoenix to another

Each depends on `embassy` for the reverse-proxy + WS-upgrade scaffolding
and provides its runtime's protocol adapter.

## The seam between core and adapter

`embassy`'s WS upgrade needs to be generic enough that `embassy_rails`
can drop its `Cable.Connection` into it as a `WebSock` handler, without
`embassy` itself knowing about subprotocols by name.

Proposed shape at upgrade time:

```elixir
Embassy.Upgrade.call(conn,
  handler: Embassy.Rails.Cable.Connection,
  init_arg: {instance_name, request_metadata},
  subprotocols: ["actioncable-v1-json"]
)
```

`Embassy.Upgrade` reads `sec-websocket-protocol`, picks the first
matching configured subprotocol, echoes it via `put_resp_header/3`,
then calls `WebSockAdapter.upgrade/4` with the handler. Same shape
works for Django Channels (`graphql-ws`, custom subprotocols, etc.) or
any other WS runtime.

## Config namespacing after the split

Today everything is under `:embassy, :cable, ...`. After the split:

- `embassy` cares about `:rpc` (the reverse-proxy targets), the
  registry name, etc. — but **not** ActionCable-shaped config.
- `embassy_rails` owns the cable config (RPC secret, broadcast key,
  AnyCable HTTP RPC paths, etc.).

The per-instance design from `PLAN.md` makes this composition clean:
each library owns its own `start_link/1` and its own instance, and they
compose at the consumer's supervision tree:

```elixir
children = [
  {Embassy,
     name: MyApp.Embassy,
     pubsub: MyApp.PubSub,
     finch: MyApp.Finch},
  {Embassy.Rails,
     name: MyApp.Embassy.Rails,
     embassy: MyApp.Embassy,
     rpc: [transport: {:uds, "/tmp/puma.sock"}, secret: "..."],
     broadcast: [source: :http, key: "..."]}
]
```

`Embassy.Rails` declares the `:embassy` dependency in its config so it
can look up the parent instance's PubSub / Finch / Registry. Or — if
simpler in practice — each adapter just takes its own `:pubsub` and
`:finch` and the consumer wires the same names twice. Decide when you
hit it.

## Demo apps after the split

- `embassy_example` — the renamed `emissary_example`. Holds the Rails
  app + the Phoenix consumer wiring up `Embassy`, `Embassy.Rails`, and
  an `Emissary.Supervisor` (for supervised Puma). The design doc
  `ANYCABLE_BRIDGE.md` lives here.
- `embassy` and `embassy_rails` themselves: **no demo apps**. They are
  hex libraries. Where they need a backend for tests, that's a `Plug`
  fixture inside `test/support/` returning canned responses — *not* a
  runnable app under `lib/` or `priv/`. This is how the embassy test
  suite stays free of any runtime dependency.

## Risk: over-extracting on a sample size of one

The reverse-proxy + WS-upgrade machinery is genuinely generic. The
BodyCache plug is genuinely generic. But the moment you find yourself
pulling something into `embassy` that only `embassy_rails` ever uses,
push it back out. The single biggest risk with this split is
over-generalising before a second adapter forces the abstraction to
prove itself.

Heuristic: if a piece of code in `embassy` has any string, constant,
status code, or protocol-name that's specific to ActionCable / AnyCable,
it belongs in `embassy_rails`. The seam in the WS upgrade is a good
worked example — `embassy` passes through subprotocols as opaque
strings; `embassy_rails` is the only thing that knows
`"actioncable-v1-json"`.

## Naming

- Top-level module for the Rails package: `Embassy.Rails` (not
  `EmbassyRails`). The dot-namespace is conventional for Elixir
  ecosystem packages and reads better at the call site.
- Sibling packages follow the same: `Embassy.Django`, `Embassy.PhpWs`,
  etc.
- Hex package names use underscores per hex convention:
  `embassy_rails`, `embassy_django`.
