defmodule Embassy.DualRoute.Result do
  @moduledoc """
  The outcome of one DualRoute experiment, passed to telemetry metadata
  and to a `Embassy.DualRoute.Reporter`.

  `control_duration` and `candidate_duration` are in `:native` time
  units (the same units `[:embassy, :dual_route, :match | :diff]`
  telemetry reports); convert with
  `System.convert_time_unit(duration, :native, :microsecond)`.

  `route` is the low-cardinality label (the `:route` option, or the
  mount point); `request_path` is the concrete path of the request.
  """

  alias Embassy.DualRoute.Captured

  @enforce_keys [
    :route,
    :request_path,
    :method,
    :verdict,
    :comparator,
    :canonical,
    :control,
    :candidate
  ]
  defstruct [
    :route,
    :request_path,
    :method,
    :verdict,
    :comparator,
    :canonical,
    :control,
    :candidate,
    :diff,
    :control_duration,
    :candidate_duration,
    :sampled?
  ]

  @type t :: %__MODULE__{
          route: String.t(),
          request_path: String.t(),
          method: String.t(),
          verdict: :match | :diff,
          comparator: term(),
          canonical: :control | :candidate,
          control: Captured.t(),
          candidate: Captured.t(),
          diff: map() | nil,
          control_duration: integer() | nil,
          candidate_duration: integer() | nil,
          sampled?: boolean()
        }
end
