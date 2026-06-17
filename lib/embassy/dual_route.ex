defmodule Embassy.DualRoute do
  @moduledoc """
  Scientist-style strangler-fig plug. Returns one backend's response (the
  canonical side) while running the other as an asynchronous shadow,
  comparing them and reporting the result.

  See the README "Strangler-fig migration with DualRoute" section and
  the design spec for the full model. Both `control` and `candidate` are
  target specs: `{:proxy, transport: ...}` or `{:plug, Module, opts}`.
  """

  @behaviour Plug

  alias Embassy.{Config, Proxy}
  alias Embassy.DualRoute.Target

  @default_max_body_length 50_000_000

  @impl Plug
  def init(opts) do
    %{
      embassy: Keyword.fetch!(opts, :embassy),
      control: Target.resolve(Keyword.fetch!(opts, :control)),
      candidate: Target.resolve(Keyword.fetch!(opts, :candidate)),
      canonical: Keyword.get(opts, :canonical, :control),
      comparator: Keyword.fetch!(opts, :comparator),
      methods: opts |> Keyword.get(:methods, ["GET"]) |> Enum.map(&String.upcase/1),
      sample_rate: Keyword.get(opts, :sample_rate, 1.0),
      shadow_timeout: Keyword.get(opts, :shadow_timeout, 5_000),
      reporter: Keyword.get(opts, :reporter),
      max_body_length: Keyword.get(opts, :max_body_length, @default_max_body_length)
    }
  end

  @impl Plug
  def call(conn, opts) do
    snapshot = Config.snapshot(opts.embassy)

    case Proxy.read_request_body(conn, opts.max_body_length) do
      {:halt_too_large, conn} ->
        send_plain(conn, 413, "Payload Too Large")

      {:halt_body_error, _reason, conn} ->
        send_plain(conn, 400, "Bad Request: failed to read request body")

      {body, conn} ->
        dispatch(conn, body, snapshot, opts)
    end
  end

  defp dispatch(conn, body, snapshot, opts) do
    if experiment?(conn, opts) do
      run_experiment(conn, body, snapshot, opts)
    else
      {conn, _captured} = Target.run_canonical(canonical_target(opts), conn, body, snapshot)
      conn
    end
  end

  defp experiment?(conn, opts) do
    String.upcase(conn.method) in opts.methods and :rand.uniform() <= opts.sample_rate
  end

  defp run_experiment(conn, body, snapshot, opts) do
    {conn, _canonical_captured} =
      Target.run_canonical(canonical_target(opts), conn, body, snapshot)

    # Shadow pipeline added in Task 8.
    conn
  end

  defp canonical_target(%{canonical: :candidate} = opts), do: opts.candidate
  defp canonical_target(opts), do: opts.control

  defp send_plain(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end
end
