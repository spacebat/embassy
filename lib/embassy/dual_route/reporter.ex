defmodule Embassy.DualRoute.Reporter do
  @moduledoc """
  Behaviour for persisting or forwarding DualRoute experiment results.

  Configure with `reporter: MyApp.DiffReporter` on `Embassy.DualRoute`.
  `report/1` is invoked inside the shadow task after comparison, so it
  never affects request latency. Raised errors are caught by DualRoute
  and turned into `[:embassy, :dual_route, :error]` telemetry.
  """

  alias Embassy.DualRoute.Result

  @callback report(Result.t()) :: :ok
end
