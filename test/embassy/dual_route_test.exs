defmodule Embassy.DualRouteTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defmodule ControlPlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "control")
  end

  defmodule CandidatePlug do
    @behaviour Plug
    @impl true
    def init(opts), do: opts
    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "candidate")
  end

  setup do
    name = :"dr_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: Module.concat(name, Finch)})
    start_supervised!({Embassy, name: name, finch: Module.concat(name, Finch)})
    %{embassy: name}
  end

  defp base_opts(embassy, overrides) do
    [
      embassy: embassy,
      control: {:plug, ControlPlug, []},
      candidate: {:plug, CandidatePlug, []},
      comparator: :status_only
    ] ++ overrides
  end

  test "canonical :control returns the control response", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, canonical: :control))
    conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.status == 200
    assert conn.resp_body == "control"
  end

  test "canonical :candidate returns the candidate response", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, canonical: :candidate))
    conn = conn(:get, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.resp_body == "candidate"
  end

  test "a non-listed method runs only the canonical target", %{embassy: e} do
    opts = Embassy.DualRoute.init(base_opts(e, methods: ["GET"]))
    conn = conn(:post, "/posts") |> Embassy.DualRoute.call(opts)
    assert conn.resp_body == "control"
  end

  test "init requires a comparator", %{embassy: e} do
    assert_raise KeyError, fn ->
      Embassy.DualRoute.init(
        embassy: e,
        control: {:plug, ControlPlug, []},
        candidate: {:plug, CandidatePlug, []}
      )
    end
  end
end
