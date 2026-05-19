# Embassy — extraction plan

This directory will hold the `embassy` hex package: the
runtime-agnostic core of a Phoenix-as-front-door stack (reverse proxy,
WS upgrade primitive, per-instance config plumbing). The
ActionCable / AnyCable specifics get extracted into a sibling package,
`embassy_rails`, at the same time. Both come out of the Phoenix app
inside the sibling `../emissary_example` repo, which will be renamed
`embassy_example` once the extraction lands.

Embassy is a hex **library**, not an application — the demo app stays
in `embassy_example`. See `CLAUDE.md` for the full library-vs-app
distinction and what it implies for `config/`, tests, and `mix.exs`
shape.

This file is the brief for the next Claude session. The previous
session ran out of room before doing the extraction.

## The family in one paragraph

- `emissary` (already published at `0.4.0`, lives in `../emissary`) —
  subprocess supervision under OTP. Stays as-is; embassy does **not**
  depend on it.
- `embassy` (this repo) — runtime-agnostic front-door: reverse proxy,
  BodyCache, DualRoute (later), per-instance config, generic
  subprotocol-negotiating WS upgrade.
- `embassy_rails` (new sibling package, to live in
  `../embassy_rails/`) — Rails / ActionCable / AnyCable adapter. The
  `Cable.Connection` `Phoenix.Socket.Transport`, the HTTP RPC client
  bound to AnyCable's `/_anycable/*` paths, the `/_broadcast` plug.
- `embassy_example` (renamed from `emissary_example`) — the demo. Wires
  embassy + embassy_rails + emissary together to show what an
  end-to-end deployment looks like. Owns the design doc.
- `ambassador` (future) — autoscaler control plane with K8s RBAC. Out
  of scope.

See `RUNTIME_SPLIT.md` for the rationale behind splitting `embassy`
from `embassy_rails` *before* the first extraction commit, rather than
after.

## Read first

The full design history lives in:

```
../emissary_example/docs/ANYCABLE_BRIDGE.md
```

That's ~1100 lines covering the AnyCable protocol, the escalation
phases (1–7), every gotcha surfaced during the PoC, and the rationale
for the architecture choices. **Read it before starting any code work.**
Treat the extraction as implementing Phase 4 of that doc.

Also read:

- `RUNTIME_SPLIT.md` — embassy / embassy_rails split rationale and
  module sort
- `CLAUDE.md` (this directory) — project conventions, the
  library-vs-application distinction, the composition story with
  emissary
- `ECOSYSTEM.md` — speculative add-on packages (ratelimit, auth,
  resilience, etc.); informational, not committed work
- `../emissary/CLAUDE.md` and `../emissary/SUBPROCESS_PACKAGE.md` —
  context on the sibling subprocess package

## What embassy is (the runtime-agnostic core)

A Phoenix-compatible library that provides:

1. **HTTP reverse proxy** to a backend (UDS or HTTP), so a consumer's
   Phoenix endpoint can be the single front-of-house for any backend.
   Eventually grows a `DualRoute` plug for Scientist-style
   strangler-fig migration (design doc Phase 6).
2. **Generic WebSocket upgrade primitive** that negotiates a
   subprotocol (passed as opaque strings — embassy never names
   `"actioncable-v1-json"` or any other protocol) and hands off to a
   `WebSock` handler the consumer provides. `embassy_rails` plugs its
   `Cable.Connection` into this seam.
3. **Per-instance config + Registry plumbing**, so multiple sibling
   adapters (`embassy_rails`, future `embassy_django`, etc.) can share
   a parent `Embassy` instance for PubSub / Finch / Registry lookup.
4. **`BodyCache` plug** for routes where the body needs to be read by
   an embassy-family plug (e.g. broadcast plugs in adapter packages)
   and re-sent or consulted downstream.

Embassy ships **no** subprocess supervisor. When you want to run Rails
on the same node as Phoenix, you wire embassy's UDS target to an
emissary-supervised Puma. The libraries compose at the consumer level;
they don't depend on each other.

## What embassy_rails is (the AnyCable adapter)

A sibling hex package, in its own repo `../embassy_rails/`, owning
everything ActionCable / AnyCable specific:

- `Embassy.Rails.Cable.Connection` — `Phoenix.Socket.Transport` impl
  speaking AnyCable's command / transmission / stream semantics.
- `Embassy.Rails.RPC` — HTTP RPC client wired to `/_anycable/*` paths
  and AnyCable's status-code conventions (0=ERROR, 1=SUCCESS,
  2=FAILURE).
- `Embassy.Rails.Broadcast` + `Embassy.Rails.BroadcastPlug` —
  AnyCable's `/_broadcast` envelope, `stop_streams` handling, the
  `actioncable-v1-json` subprotocol constant.
- `Embassy.Rails.Cable` — topic prefix helpers (`"cable:"` + stream
  name).

`embassy_rails` declares an `:embassy` instance in its config so it can
look up the parent's PubSub / Finch / Registry.

## What stays in emissary_example (renamed embassy_example)

The renamed `embassy_example` keeps:

- The whole `rails_app/` — none of the libraries care about the Rails
  app; it's just one consumer.
- The Phoenix app (`phoenix_app/`), stripped down to a thin consumer
  that wires `{Embassy, ...}`, `{Embassy.Rails, ...}`, and an
  `Emissary.Supervisor` for supervised Puma into its supervision tree.
  Most of `phoenix_app/lib/.../cable/*` moves out into `embassy` or
  `embassy_rails`.
- The smoke scripts (`scripts/cable_smoke.rb`, `scripts/cable_phase2.rb`)
  and demo views.
- `docs/ANYCABLE_BRIDGE.md` — the design doc travels with the example
  because it documents the integration end-to-end, not any one
  library's internals.

## Modules to move

Source → destination. Module prefix changes:
`EmissaryExampleWeb.Cable.*` → `Embassy.*` or `Embassy.Rails.*`.

### Into `embassy/` (this repo)

| Source (in `emissary_example/phoenix_app/`) | Destination |
|---|---|
| `lib/emissary_example_web/cable/upgrade.ex` (generic upgrade primitive) | `lib/embassy/upgrade.ex` |
| `lib/emissary_example_web/cable/config.ex` (generic parts only) | `lib/embassy/config.ex` (reworked, see below) |
| `lib/emissary_example_web/plugs/body_cache.ex` | `lib/embassy/plugs/body_cache.ex` |
| `lib/emissary_example_web/plugs/uds_proxy.ex` (or wherever the reverse proxy lives) | `lib/embassy/reverse_proxy.ex` |

### Into `embassy_rails/` (separate repo)

| Source | Destination |
|---|---|
| `lib/emissary_example_web/cable.ex` | `lib/embassy/rails/cable.ex` |
| `lib/emissary_example_web/cable/config.ex` (cable-specific parts) | `lib/embassy/rails/config.ex` |
| `lib/emissary_example_web/cable/connection.ex` | `lib/embassy/rails/cable/connection.ex` |
| `lib/emissary_example_web/cable/upgrade.ex` (AnyCable subprotocol wiring) | folded into the consumer's call to `Embassy.Upgrade`; `embassy_rails` exposes the `"actioncable-v1-json"` constant |
| `lib/emissary_example_web/cable/rpc.ex` | `lib/embassy/rails/rpc.ex` |
| `lib/emissary_example_web/cable/broadcast.ex` | `lib/embassy/rails/broadcast.ex` |
| `lib/emissary_example_web/controllers/broadcast_controller.ex` | `lib/embassy/rails/broadcast_plug.ex` (converted to a Plug, see below) |

Heuristic for ambiguous cases: if a piece of code mentions any
ActionCable / AnyCable string, constant, status code, or protocol
name, it belongs in `embassy_rails`. If it could meaningfully be
reused by a hypothetical `embassy_django`, it belongs in `embassy`.

## Three design shifts during extraction

These are the substantive code changes — not just renames. Each is
called out so the next session can review-and-confirm before touching
files.

### 1. Per-instance config, not `Application.get_env`

Today, `Cable.Config` reads `Application.get_env(:emissary_example, :cable, [])`.
That's fine when the app *is* its own config namespace, but a library
can't claim a global env key.

Target: the consumer supervises one `Embassy` instance and one
`Embassy.Rails` instance, passing config in each child spec. Lookup is
by instance name.

```elixir
# Consumer's application.ex:
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

Internally, each library is a supervisor that stashes its config under
a registry keyed by instance name. `Embassy.Config.snapshot(name)` and
`Embassy.Rails.Config.snapshot(name)` return the maps.

Every module that currently calls `Cable.Config.snapshot/0` needs to
know which instance it belongs to. Two patterns:

- **Plugs**: take the instance name in `init/1`, stash on conn assigns.
- **Per-WS `Cable.Connection`**: the connection state already exists;
  add an `:embassy` / `:embassy_rails` field and pass through from the
  upgrade plug.

This applies symmetrically to both packages.

### 2. Neither package owns Finch or PubSub

The consumer passes them in by name to the parent `Embassy` instance,
and `Embassy.Rails` looks them up via its `:embassy` reference. Two
reasons:

- A consumer almost always already has a Finch and a PubSub for their
  own use; making them stand up additional ones is unfriendly.
- Per-instance config naturally extends to "use my Finch, use my
  PubSub" without either library babysitting.

`Embassy.start_link/1` validates that `:finch` and `:pubsub` are
present and reachable; `Embassy.Rails.start_link/1` validates that the
named `:embassy` is reachable.

### 3. `BroadcastController` → `Embassy.Rails.BroadcastPlug`

The controller pattern requires `use MyAppWeb, :controller`, which
yanks in the host app's web module. That's a hard dependency
`embassy_rails` shouldn't have. The controller is ~50 lines and
already plug-shaped under the macro — convert to a vanilla Plug:

```elixir
# Consumer's router.ex:
scope "/" do
  pipe_through :api
  post "/_broadcast", Embassy.Rails.BroadcastPlug, name: MyApp.Embassy.Rails
end
```

`call/2` reads the parsed body (still via `Embassy.BodyCache` for raw
access), verifies the bearer, fans entries through
`Embassy.Rails.Broadcast.dispatch/2`.

## Target package layout (this repo)

```
embassy/
├── lib/
│   ├── embassy.ex                  # parent supervisor, start_link/1, public API
│   ├── embassy/
│   │   ├── application.ex          # minimal; no global state started here
│   │   ├── config.ex               # per-instance config accessor
│   │   ├── upgrade.ex              # generic subprotocol-negotiating WS upgrade plug
│   │   ├── reverse_proxy.ex        # UDS/HTTP reverse-proxy plug
│   │   ├── dual_route.ex           # later — Scientist-style strangler-fig (Phase 6)
│   │   └── plugs/
│   │       └── body_cache.ex
├── test/
│   ├── embassy_test.exs
│   ├── embassy/
│   │   ├── upgrade_test.exs        # subprotocol negotiation, handler dispatch
│   │   ├── reverse_proxy_test.exs  # against Bypass with HTTP transport
│   │   └── body_cache_test.exs
│   └── test_helper.exs
├── .formatter.exs
├── .gitignore
├── CHANGELOG.md
├── LICENSE                          # MIT
├── README.md                        # public API + 5-minute install
├── mix.exs                          # hex package metadata complete from v0.1.0
└── PLAN.md                          # this file (delete after extraction is done)
```

`embassy_rails/` gets its own repo and its own analogous layout. Write
its plan once embassy v0.1 is in shape; don't try to build both in
parallel before either has compiled cleanly.

## Dependencies

### `embassy/mix.exs`

```elixir
defp deps do
  [
    {:plug, "~> 1.16"},
    {:websock, "~> 0.5"},
    {:websock_adapter, "~> 0.5"},
    {:finch, "~> 0.19"},
    {:jason, "~> 1.4"},
    {:bypass, "~> 2.1", only: :test},
    {:ex_doc, "~> 0.34", only: :dev, runtime: false}
  ]
end
```

No `:phoenix` dep — the WS upgrade primitive uses `:websock_adapter`
directly, and the proxy is a plain Plug. No `:phoenix_pubsub` — that
lives in `embassy_rails` (where broadcasts happen). No emissary dep.
No dialyxir.

### `embassy_rails/mix.exs` (sketch, for reference only)

```elixir
defp deps do
  [
    {:embassy, "~> 0.1"},        # path-dep during development
    {:phoenix, "~> 1.8"},        # for Phoenix.Socket.Transport
    {:phoenix_pubsub, "~> 2.1"},
    {:jason, "~> 1.4"},
    {:bypass, "~> 2.1", only: :test},
    {:ex_doc, "~> 0.34", only: :dev, runtime: false}
  ]
end
```

## Migration steps

These are the steps for *this repo*. `embassy_rails` gets its own
migration plan once embassy itself is in shape.

1. **Skeleton already done** — `mix new embassy --sup` has run. Fill in
   `mix.exs` (package metadata for hex, version `0.1.0-dev`, deps
   above). Make sure `.gitignore`, `.formatter.exs`, `LICENSE` (MIT),
   barebones `README.md`, empty `CHANGELOG.md` are present.
2. **First commit on `main`** — skeleton + planning docs only. Then
   branch off `feature/extract-core` for the actual extraction work.
3. **Move modules** — copy the four embassy-bound files listed above,
   rewrite namespaces to `Embassy.*`. Don't rework config yet; just
   get them compiling against a temporary `Application.get_env(:embassy, ...)`
   placeholder.
4. **Rework config to per-instance** — implement `Embassy` as a
   supervisor that takes `:name`, `:pubsub`, `:finch`; stashes the
   snapshot under a Registry started inside its own supervision tree.
   Update every call site. This is the biggest single chunk of churn —
   do it before tests so tests exercise the final shape.
5. **Tests** — at minimum:
   - `Embassy` supervisor starts cleanly with a minimal config; fails
     loudly when `:pubsub` or `:finch` is missing.
   - `Upgrade` negotiates a configured subprotocol; echoes the matched
     one via `put_resp_header/3`; rejects when no overlap.
   - `Upgrade` dispatches to the configured `WebSock` handler with the
     supplied init arg.
   - `ReverseProxy` round-trips against `Bypass` for HTTP transport;
     preserves Host header; strips hop-by-hop headers per RFC 7230 §6.1.
   - `BodyCache` makes the raw body available without breaking
     downstream parsing.
   No Rails dependency. No integration test in the embassy repo — the
   integration story is `embassy_example`'s job (and the
   AnyCable-specific tests are `embassy_rails`'s job).
6. **Polish** — moduledocs on every public module, `@spec` on every
   public function. Set up `ex_doc` config in `mix.exs`. Hex package
   metadata complete enough to `mix hex.build --unpack` cleanly.
7. **README** — public API surface, install snippet, minimal wiring
   example, links to `RUNTIME_SPLIT.md` (why the split exists) and
   `../emissary_example/docs/ANYCABLE_BRIDGE.md` (the design history).
8. **Merge feature branch to main** — user doesn't use GitHub PRs
   locally; `git merge --no-ff` is fine, or fast-forward for a linear
   history.
9. **Start `embassy_rails` in its own repo** — separate from embassy
   itself. The plan for that repo follows the same shape (skeleton,
   feature branch, move modules, per-instance config, tests, polish).
10. **Switch to `emissary_example`** — rename to `embassy_example`
    (`git mv` if it's a git repo; the user initialised it fresh in a
    previous session, so it is). Add path-deps on both
    `{:embassy, path: "../embassy"}` and
    `{:embassy_rails, path: "../embassy_rails"}`. Delete the now-moved
    modules. Update `application.ex` to use the new `{Embassy, ...}`
    and `{Embassy.Rails, ...}` child specs. Update `dev.exs` /
    `router.ex` / `endpoint.ex` accordingly.
11. **Run smokes** — `scripts/cable_smoke.rb` and
    `scripts/cable_phase2.rb` must still pass without modification.
    They speak HTTP/WS, so they don't care about the internal refactor.
12. **Commit on a feature branch off main** in the embassy_example
    repo, per the project CLAUDE.md convention.
13. **Tag `embassy v0.1.0` and `embassy_rails v0.1.0`** once the demo
    passes end-to-end.

## Constraints from the project

From `CLAUDE.md`, `../emissary/CLAUDE.md`, and the user's stated
preferences:

- This is a **library, not an application** — see `CLAUDE.md` for the
  full implications (no app config, no Phoenix endpoint, no demo here,
  tests don't boot a server, hex metadata complete from day one).
- Branch off `main` for actual extraction work; don't commit directly
  to main except for the initial skeleton + planning docs.
- **No authorship attribution** in commit messages (no Co-Authored-By,
  no Claude trailer). The user is explicit about this.
- Elixir 1.19+; user is moving to 1.20 soon. Don't backport, don't
  hedge with `Version.compare/2` guards.
- **No dialyxir.**
- No emojis in code, comments, or commit messages.
- The user controls when commits happen — propose, don't execute,
  unless explicitly asked to commit.
- **Don't add `{:emissary, ...}` to `mix.exs`.** Embassy and emissary
  are independent peers that compose only at the consumer level.

## Open questions to settle when you start

Each of these is low-stakes but worth deciding intentionally rather
than picking on the fly:

- **`Embassy.Upgrade` vs `Embassy.Plug.Upgrade`?** Suggest the former
  (flatter namespace). Same logic for the eventual
  `Embassy.Rails.BroadcastPlug` vs `Embassy.Rails.Plug.Broadcast`.
- **Does `Embassy` need a `child_spec/1` only, or both `start_link/1`
  and `child_spec/1`?** Suggest both, with `child_spec/1` being the
  primary public API since 99% of consumers will use it via their
  supervision tree.
- **Where does `Embassy.Registry` get started?** Inside the `Embassy`
  supervisor itself (so it's automatic when the consumer adds the
  child spec) — fewer things for the consumer to remember.
- **Should `Embassy.ReverseProxy` be a separate publishable concern?**
  Logically distinct from anything WS-related. For v0.1 keep it in
  embassy; if a consumer surfaces who only wants the proxy, consider
  splitting. Don't preemptively split.
- **How does `Embassy.Rails` find the parent `Embassy` instance?**
  Either via an `:embassy` key in its config (suggested), or by each
  adapter independently taking `:pubsub` and `:finch` and the consumer
  wiring the same names twice. Decide when you hit it.

## What to do when this plan is wrong

You'll find things this plan got wrong. That's expected — it was
written before any of the extraction happened, by an LLM in a session
that was running low on context. Prefer to:

- Read the actual code in `../emissary_example/phoenix_app/lib/`
  before trusting the file list in this plan.
- Read `../emissary_example/docs/ANYCABLE_BRIDGE.md` for the *why*
  behind each module's existence.
- Read `RUNTIME_SPLIT.md` for the *why* behind the embassy /
  embassy_rails split.
- Ask the user when in doubt — they have the full context of the
  earlier sessions even if you don't.

## After extraction

Delete this `PLAN.md` and replace it with the real `README.md`
content. The plan is one-shot scaffolding; once embassy v0.1 is
shipping, future direction belongs in `CHANGELOG.md`, `ECOSYSTEM.md`,
the design doc (in `embassy_example`), and (eventually) `ROADMAP.md`
if it earns its keep.

`RUNTIME_SPLIT.md` can also be deleted once both `embassy` and
`embassy_rails` are extracted and the split is reflected in their
respective READMEs.
