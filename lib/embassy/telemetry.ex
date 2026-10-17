if Code.ensure_loaded?(Telemetry.Metrics) do
  defmodule Embassy.Telemetry do
    @moduledoc """
    `Telemetry.Metrics` definitions over embassy events. Hand them to a
    reporter (e.g. `TelemetryMetricsPrometheus.Core`) alongside the host
    app's own metrics. Tags are low cardinality: a route label, never a
    request path, query, header or error reason.

    Requires the optional `:telemetry_metrics` dependency.

    See the README "Metrics and dashboards" section for wiring and
    example PromQL.
    """

    import Telemetry.Metrics

    @buckets [5, 10, 25, 50, 100, 250, 500, 1000, 5000]

    @spec metrics() :: [Telemetry.Metrics.t()]
    def metrics do
      [
        duration("embassy.proxy.duration",
          event_name: [:embassy, :proxy, :stop],
          measurement: :duration,
          tags: [:instance, :route, :role, :status]
        ),
        counter("embassy.proxy.exception.count",
          event_name: [:embassy, :proxy, :exception],
          tags: [:instance, :route, :role, :kind]
        ),
        counter("embassy.dual_route.dispatch.count",
          event_name: [:embassy, :dual_route, :dispatch],
          tags: [:instance, :route, :canonical, :served_by, :sampled]
        ),
        counter("embassy.dual_route.match.count",
          event_name: [:embassy, :dual_route, :match],
          tags: [:instance, :route]
        ),
        counter("embassy.dual_route.diff.count",
          event_name: [:embassy, :dual_route, :diff],
          tags: [:instance, :route]
        ),
        counter("embassy.dual_route.error.count",
          event_name: [:embassy, :dual_route, :error],
          tags: [:instance, :route]
        ),
        duration("embassy.dual_route.match.candidate_duration",
          event_name: [:embassy, :dual_route, :match],
          measurement: :candidate_duration,
          tags: [:instance, :route]
        ),
        duration("embassy.dual_route.diff.candidate_duration",
          event_name: [:embassy, :dual_route, :diff],
          measurement: :candidate_duration,
          tags: [:instance, :route]
        ),
        counter("embassy.upgrade.rejected.count",
          event_name: [:embassy, :upgrade, :rejected],
          tags: [:instance, :kind]
        ),
        last_value("embassy.upstream.up",
          event_name: [:embassy, :upstream, :check],
          measurement: :up,
          tags: [:instance, :upstream]
        ),
        duration("embassy.upstream.check.duration",
          event_name: [:embassy, :upstream, :check],
          measurement: :duration,
          tags: [:instance, :upstream]
        )
      ]
    end

    defp duration(name, opts) do
      distribution(
        name,
        opts ++ [unit: {:native, :millisecond}, reporter_options: [buckets: @buckets]]
      )
    end
  end
end
