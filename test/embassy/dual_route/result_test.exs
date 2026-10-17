defmodule Embassy.DualRoute.ResultTest do
  use ExUnit.Case, async: true

  alias Embassy.DualRoute.{Captured, Reporter, Result}

  defmodule SendReporter do
    @behaviour Reporter
    @impl true
    def report(%Result{} = result) do
      send(self(), {:reported, result.verdict})
      :ok
    end
  end

  test "Result holds the experiment outcome and SendReporter receives it" do
    result = %Result{
      route: "posts",
      request_path: "/posts/1",
      method: "GET",
      verdict: :diff,
      comparator: :json,
      canonical: :control,
      control: %Captured{status: 200, headers: [], body: "a"},
      candidate: %Captured{status: 200, headers: [], body: "b"},
      diff: %{reason: :json_body},
      control_duration: 10,
      candidate_duration: 12,
      sampled?: true
    }

    assert :ok = SendReporter.report(result)
    assert_received {:reported, :diff}
  end

  test "Result requires request_path" do
    assert_raise ArgumentError, ~r/request_path/, fn ->
      struct!(Result,
        route: "posts",
        method: "GET",
        verdict: :match,
        comparator: :exact,
        canonical: :control,
        control: nil,
        candidate: nil
      )
    end
  end
end
