# Embassy

A Phoenix-side ActionCable / AnyCable bridge and reverse proxy, being
extracted into its own hex package from the Phoenix app inside
`../emissary_example`. The `emissary_example` repo will be renamed
`embassy_example` once the extraction lands.

## The family

These are independent hex packages that compose at the consumer level.
None of them depends on another.

- **`emissary`** (`../emissary`) — subprocess supervision under OTP.
  Already published as `emissary 0.4.0`. Runs Ruby / Python / shell
  workers in transient or persistent (UDS daemon) mode. Stays as-is;
  embassy does **not** absorb it, replace it, or take a dep on it.
- **`embassy`** (this repo) — Phoenix-as-front-door. WS terminator
  speaking AnyCable HTTP RPC + reverse proxy (UDS / HTTP) + eventual
  strangler-fig DualRoute plug. Runtime-agnostic core.
- **`embassy_rails`** — Rails / ActionCable / AnyCable-specific
  adapter. Planned sibling package; see `RUNTIME_SPLIT.md` for why
  the split happens at extraction time, not after.
- **`ambassador`** (future) — autoscaler control plane with K8s RBAC.
  Out of scope for now.

The naming arc: **emissary** is the messenger (carries the subprocess),
**embassy** is the building that hosts them (Phoenix as front-of-house),
**ambassador** is the senior diplomat with authority (cluster-write
RBAC). The metaphor does real work — keep it consistent.

## How embassy and emissary compose

They are complementary, not overlapping. A typical single-node deploy
uses both:

- emissary supervises a Puma master under OTP, binding it to a Unix
  domain socket. `kill_group` ensures the whole Rails cluster dies with
  Phoenix.
- embassy reverse-proxies HTTP requests to that same UDS, and
  terminates `/cable` WebSockets, delegating ActionCable protocol
  decisions to Rails via HTTP RPC over the same socket.

Other compositions are equally valid: emissary alone (no Phoenix front
door), embassy pointing at a remote Rails service over HTTP (no
emissary), or either with a different runtime. The packages are
deliberately decoupled so consumers pick what they need.

`embassy_example` will demonstrate both libraries cooperating; embassy
itself ships with a tiny stub-backend demo so its test suite has no
runtime dependency.

## This repo is a library, not an application

Embassy ships as a hex package. The only actual application is the
eventual `embassy_example` (the renamed `emissary_example`). That
distinction shapes a lot of defaults:

- **No `config/dev.exs`, `config/runtime.exs`, or app-specific env
  config.** Configuration is per-instance, passed in by the consumer
  via the `{Embassy, ...}` child spec. Never `Application.get_env(:embassy, ...)`.
- **No Phoenix endpoint, router, or `Phoenix.PubSub` instance lives
  here.** The consumer owns those; embassy plugs and supervisors mount
  into their tree.
- **No Finch instance, no Registry, no top-level Application module
  doing real work.** The `mix new --sup` Application scaffold may stay
  for any library-internal supervised state (e.g. an `Embassy.Registry`
  started under embassy's own supervisor inside the consumer's tree),
  but it should not start anything globally.
- **No demo, example, or runnable app under `lib/`, `priv/`, or
  `scripts/`.** Demos belong in `embassy_example`.
- **Tests don't boot a Phoenix server.** They exercise plugs, the WS
  upgrade primitive, and the supervisor in isolation with `Bypass` or
  test PubSub. No Rails dep, no end-to-end integration test in this
  repo — that's `embassy_example`'s job.
- **`mix.exs` carries full hex package metadata** (`:description`,
  `:package`, `:source_url`, `:docs`). Treat it as publishable from
  day one, even at `0.1.0-dev`.

When in doubt: if a piece of code or config only makes sense once
something is *running*, it probably belongs in `embassy_example`, not
here.

## Status

Skeleton only. The actual extraction has not started yet. This repo
currently contains the planning docs (`PLAN.md`, `RUNTIME_SPLIT.md`,
`ECOSYSTEM.md`) plus `mix new --sup` scaffolding.

## Read first

- `PLAN.md` — extraction brief, target package layout, module move
  table, migration steps
- `RUNTIME_SPLIT.md` — the embassy / embassy_rails split; the cut
  happens during the move, not after
- `ECOSYSTEM.md` — speculative add-on packages (ratelimit, auth,
  resilience, trace, etc.); informational, not committed work
- `../emissary_example/docs/ANYCABLE_BRIDGE.md` — ~1100-line design
  history covering the AnyCable protocol, escalation phases 1–7, and
  the rationale behind every architecture choice. **Read it before any
  code work.**
- `../emissary/SUBPROCESS_PACKAGE.md` and `../emissary/CLAUDE.md` —
  context on the sibling package; useful when reasoning about the
  composition seam.

## Project conventions

- Branch off `main` for extraction work. Initial skeleton commits go on
  `main`; everything else lives on `feature/*` branches.
- **No authorship attribution in commits.** No `Co-Authored-By`
  trailers, no Claude attribution. The user is explicit about this.
- Elixir 1.19+; user is moving to 1.20 soon. Don't backport, don't hedge
  with `Version.compare/2` guards.
- **No dialyxir.**
- No emojis anywhere — code, comments, commit messages, docs.
- The user controls when commits happen. Propose, don't execute, unless
  explicitly asked.
- Don't add `{:emissary, ...}` to `mix.exs`. If you ever feel the urge
  to, something has gone wrong with the composition story — stop and
  raise it.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
