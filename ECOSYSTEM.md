# Embassy ecosystem — candidate packages

Companion to `PLAN.md` and `RUNTIME_SPLIT.md`. Brainstorm of what
else might belong in the embassy family beyond the core extraction and
the per-runtime adapters.

## The deciding criterion

Does this benefit from sitting in the same process as the strangler-fig
migration and the reverse proxy?

- **Yes** → belongs in the embassy ecosystem (own package or core).
- **No, just wants to be at-the-edge** → upstream concern (Cloudflare,
  nginx, ingress controller). Don't reimplement.

The unique value of an embassy-native version of any of these is that
it can see decrypted bodies, knows the per-route shadow/canonical
state, and shares config + telemetry with the rest of the front-door
stack. Edge tools can't do any of that.

A second cut: does it need **persistent per-instance state** (counters,
breaker state, JWT cache, rule compilation)?

- **Yes** → earns its own hex package with its own supervisor.
- **No, one-shot validation or header munging** → just a plug the
  consumer composes directly. No package needed.

## Strong candidates

### `embassy_ratelimit`

Per-IP / per-API-key / per-route limits with sliding windows. BEAM's
concurrency primitives are purpose-built for distributed counters
(`:atomics`, ETS, `:counters`). `hammer` and `ex_rated` exist as
building blocks; embassy's value-add is a curated integration with
per-route policies in the same per-instance config shape as the rest
of the ecosystem.

Per-route policy example:
```elixir
{Embassy.RateLimit,
   name: MyApp.RateLimit,
   embassy: MyApp.Embassy,
   policies: [
     {"/api/login", per_ip: {5, :minute}, per_user: {20, :hour}},
     {"/api/*",     per_api_key: {1000, :minute}}
   ]}
```

Strangler-fig bonus: limits apply uniformly to legacy and new
endpoints during migration without needing to touch either backend's
code.

### `embassy_auth`

OIDC / JWT / SAML termination at the front door. Validates tokens
once, passes identity downstream as a signed header
(`X-Embassy-User: <id>` with HMAC signature so backends can trust it).

The strangler-fig payoff is large: lets you unify auth across legacy
Rails routes and new Phoenix routes without changing either backend's
auth code. Particularly valuable when migrating off a legacy auth
system — point the new auth provider at embassy, leave the backends
alone, flip cutover when ready.

Composition with `Embassy.Rails`: the AnyCable RPC `env` payload
includes headers, so the Rails `Connection#connect` callback gets the
embassy-signed identity header for free. Rails just trusts it (after
verifying the signature, which `embassy_rails` would handle).

### `embassy_resilience`

Circuit breakers + retries per upstream backend. Once you're
reverse-proxying to multiple targets (Puma for legacy, Falcon for
cable, a new Phoenix handler for migrated routes, a stub during
canary), per-backend fail-fast is essential. `fuse` is the natural
building block.

Per-backend config example:
```elixir
{Embassy.Resilience,
   name: MyApp.Resilience,
   embassy: MyApp.Embassy,
   breakers: [
     {:puma,   threshold: {5, 30_000}, refresh: 60_000},
     {:falcon, threshold: {10, 10_000}, refresh: 30_000}
   ],
   retries: [
     {:get, max_attempts: 3, backoff: {:exponential, 100, 2}}
   ]}
```

Idempotency awareness is the killer feature: retry GETs, never retry
POSTs unless the consumer explicitly tags the route as idempotent.

### `embassy_trace`

Distributed-tracing injection (W3C `traceparent`, span generation,
propagation to the backend via headers). Embassy is the single
chokepoint that can **guarantee** every request gets traced regardless
of which backend handles it.

This might belong in core rather than a separate package — it's small
(a Plug that creates a span around the request, injects `traceparent`
into the proxied request, closes the span on response) and the value
is universal. Decide based on whether the OpenTelemetry deps feel too
heavy for the core package's footprint.

## Ambitious but worth flagging — `embassy_waf`

A serious WAF (OWASP Core Rule Set grade) is a multi-month project
where getting it wrong creates **false confidence** — worse than no
WAF. The implementation isn't the hard part; it's keeping rule
coverage up to date with new attack patterns over years.

But an embassy-native WAF has genuinely novel value vs an edge WAF:

- **Sees decrypted bodies** (edge WAFs only see URLs and headers
  unless you do TLS termination at the edge, which has its own
  tradeoffs).
- **Knows the migration state** — can apply stricter rules to
  unmigrated legacy endpoints, looser rules to known-safe new ones.
- **Can apply different rules to shadowed vs canonical traffic** —
  block on canonical, log-only on shadow, so DualRoute traffic
  doesn't double-trigger alerts.
- **Per-route rule scoping** that matches the rest of embassy's
  config shape.

Recommended phasing:

1. **Phase 1**: `embassy_modsec` — wrap ModSecurity as a sidecar
   process. Embassy proxies through it. Battle-tested rules,
   minimal code in our repo. Gives users a real WAF immediately.
2. **Phase 2**: `embassy_waf` — native Elixir rules engine. Start
   with the 20 most-common OWASP CRS rules ported as compile-time
   pattern matches. Add a learning/log-only mode for safe rollout.
3. **Phase 3**: Per-route policies, shadow-aware blocking, full
   integration with telemetry / ambassador.

Not v0.1. Not v0.2. **Probably year-two material** unless someone
shows up with strong domain expertise and time to invest.

## Don't bother

These look like they belong in the front-door stack but are
better-served upstream:

- **Static asset serving** — Phoenix already does this. If you want
  CDN-style caching, use a CDN.
- **Compression** (gzip, brotli, zstd) — every reverse proxy does
  this. Plug already supports it. Not an embassy concern.
- **ETag / conditional GET handling** — Plug handles it. The
  backend should set proper cache headers; embassy just forwards.
- **Image optimization on-the-fly** — too specialized; use Imgproxy
  or similar dedicated service.
- **Bot detection, geoblocking, captcha challenges** — outsource to
  Cloudflare / Akamai / Fastly. The data and ML required to do this
  well isn't in our wheelhouse.
- **Response caching** (Varnish-style) — Varnish exists, is excellent,
  and runs as a sidecar. Don't reimplement.
- **GraphQL ↔ REST translation** — wrong abstraction level for a
  front-door package. Belongs in an application-layer library.

## Possibly worth it later

These could fit but aren't obvious wins yet — wait for a real
consumer to ask before building:

- **`embassy_canary`** — gradual traffic shifting by percentage /
  header / cookie. DualRoute (Phase 6) handles the "compare two
  backends" case; canary handles "shift more traffic over time."
  Different enough to maybe be its own package.
- **`embassy_audit`** — structured audit logging for sensitive
  endpoints, with redaction policies. Compliance-driven; only
  matters in regulated industries.
- **`embassy_cors`** — centralized CORS policy management. Plug
  already has `Corsica`; embassy's value-add would be per-route
  policies in the standard config shape. Probably a thin shim.
- **`embassy_csp`** — Content Security Policy header injection
  with nonce generation. Could compose with the strangler-fig
  migration to apply different CSP to legacy vs new routes.
- **`embassy_mtls`** — mutual TLS termination at the front door.
  Usually done at the ingress layer (Envoy / Istio); only worth
  building if Phoenix-native mTLS gives meaningful ergonomics
  wins.

## Naming convention

All packages: `embassy_<thing>` for the hex name, `Embassy.<Thing>`
for the top-level module. Matches the `embassy_rails` →
`Embassy.Rails` pattern from `RUNTIME_SPLIT.md`.

Adapters (per-runtime) vs add-ons (per-concern):
- Adapters: `embassy_rails`, `embassy_django`, `embassy_phpws`
- Add-ons: `embassy_ratelimit`, `embassy_auth`, `embassy_resilience`,
  `embassy_trace`, `embassy_waf`

The autoscaler control plane stays out of this family — it's
**ambassador**, not `embassy_autoscaler`. The diplomatic-corps
metaphor is doing real work: ambassador has cluster-write authority
that the rest of the embassy ecosystem deliberately doesn't.

## What to build first

Suggested rough order, optimising for "smallest thing that unlocks
real-world use":

1. `embassy` v0.1 + `embassy_rails` v0.1 — per `PLAN.md` and
   `RUNTIME_SPLIT.md`. The MVP.
2. `embassy_trace` — small, universal, unlocks observability story.
   Maybe folds into core.
3. `embassy_ratelimit` — high-value, modest scope.
4. `embassy_auth` — high-value for strangler-fig users; biggest
   single ergonomics win after the core.
5. `embassy_resilience` — needed once a second backend appears
   in the routing table.
6. **ambassador** — once telemetry from the above is stable enough
   to make scaling decisions on.
7. `embassy_modsec` then `embassy_waf` — much later, when the
   ecosystem has its own users asking for it.
