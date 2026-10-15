# Embassy TODO

Tracked follow-up work. One bullet per item; move to the CHANGELOG when
done.

Context for the first two: in a Kubernetes deployment the upstreams are
Services, so Kubernetes does supervision, restarts, and scaling. Embassy's
job is to expose the signals Kubernetes can't see (traffic split during
the strangler-fig migration) so HPA/KEDA can scale on them. This replaces
the earlier idea of a separate `ambassador` control plane.

- **`Embassy.Telemetry.metrics/0`** — ship `Telemetry.Metrics` definitions
  over the events we already emit (`[:embassy, :proxy, :start | :stop |
  :exception]`, `[:embassy, :dual_route, ...]`, `[:embassy, :upgrade,
  :rejected]`) so a host app can hand them to its Prometheus reporter
  (e.g. `telemetry_metrics_prometheus_core` / PromEx) without writing its own.
  Key series: proxied request count and duration by `instance` / `status`,
  upstream error count, and DualRoute verdicts by route. Watch cardinality:
  proxy metadata carries `request_path`, which can't be a tag; the
  per-route traffic split needs a low-cardinality route name (the
  DualRoute route, or a matched route pattern added to the metadata). The
  "share of traffic still going to Rails" series is what an HPA would use
  to shrink the Rails Deployment as routes migrate. Make `telemetry_metrics`
  an optional dep.
- **Upstream readiness check** — a cheap function or Plug (e.g.
  `Embassy.Health.check/1` per instance) that the host app can wire into its
  Kubernetes readiness probe. It should report not-ready when the configured
  upstream (`http://rails.svc:3000` or a UDS) can't be reached, so a Phoenix
  pod isn't put into the Service before it can proxy. Cache the result
  briefly so a high probe rate doesn't hammer Rails, and keep it separate
  from liveness: an outage upstream must not restart the Phoenix pods.
