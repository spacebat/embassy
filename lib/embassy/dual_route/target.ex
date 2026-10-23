defmodule Embassy.DualRoute.Target do
  @moduledoc """
  Resolves and runs a DualRoute target. A target is either a proxy to an
  upstream (`{:proxy, transport: ..., max_body_length: ...}`) or an
  in-process plug (`{:plug, module, plug_opts}`).

  `resolve/1` is called once at plug init (it pre-initialises plug opts).
  `run/5` runs the target in capture-only mode (shadow). `run_canonical/5`
  runs it and commits the response to the live conn.

  `ctx` carries the telemetry route label and role (`:canonical` or
  `:shadow`). Proxy targets emit `[:embassy, :proxy, *]` events with
  them; plug targets ignore it.
  """

  import Plug.Conn, only: [put_resp_header: 3, send_resp: 3]

  alias Embassy.DualRoute.{Captured, CaptureAdapter}
  alias Embassy.Proxy

  @default_max_body_length 50_000_000

  @type ctx :: %{route: String.t(), role: :canonical | :shadow}

  @type resolved ::
          {:proxy, %{transport: term(), max_body_length: non_neg_integer()}}
          | {:plug, module(), term()}

  @doc "Validate and pre-initialise a target spec."
  @spec resolve(tuple()) :: resolved()
  def resolve({:proxy, opts}) when is_list(opts) do
    transport = Keyword.fetch!(opts, :transport)
    max = Keyword.get(opts, :max_body_length, @default_max_body_length)
    {:proxy, %{transport: transport, max_body_length: max}}
  end

  def resolve({:plug, module, plug_opts}) when is_atom(module) do
    {:plug, module, module.init(plug_opts)}
  end

  @doc "Run the target without touching the live conn. Returns a Captured."
  @spec run(resolved(), Plug.Conn.t(), binary(), map(), ctx()) ::
          {:ok, Captured.t()} | {:error, term()}
  def run({:plug, module, opts}, conn, body, _snapshot, _ctx) do
    captured =
      conn
      |> CaptureAdapter.build_conn(body)
      |> module.call(opts)
      |> CaptureAdapter.captured()

    {:ok, captured}
  end

  def run({:proxy, %{transport: transport}}, conn, body, snapshot, ctx) do
    metadata = Proxy.event_metadata(conn, snapshot.name, transport, ctx.route, ctx.role)
    start_time = Proxy.emit_start(metadata)
    req = Proxy.build_request(conn, body, transport)

    case Proxy.forward(req, body, snapshot.finch, metadata, start_time) do
      {:ok, %Finch.Response{status: status, headers: headers, body: resp_body}} ->
        {:ok,
         %Captured{status: status, headers: Proxy.response_headers(headers), body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run the target and commit its response to the live conn. Returns the
  sent conn and the Captured. On a proxy upstream error it sends a 502
  (mirroring `Embassy.ReverseProxy`) and stashes the failure reason under
  `conn.private.embassy_proxy_error`.
  """
  @spec run_canonical(resolved(), Plug.Conn.t(), binary(), map(), ctx()) ::
          {Plug.Conn.t(), Captured.t()}
  def run_canonical({:plug, _, _} = target, conn, body, snapshot, ctx) do
    {:ok, captured} = run(target, conn, body, snapshot, ctx)
    {commit(conn, captured), captured}
  end

  def run_canonical({:proxy, _} = target, conn, body, snapshot, ctx) do
    case run(target, conn, body, snapshot, ctx) do
      {:ok, captured} ->
        {commit(conn, captured), captured}

      {:error, reason} ->
        captured = %Captured{status: 502, headers: [], body: "Bad gateway: upstream unreachable"}

        conn =
          conn
          |> put_resp_header("content-type", "text/plain")
          |> send_resp(502, captured.body)

        {%{conn | private: Map.put(conn.private, :embassy_proxy_error, reason)}, captured}
    end
  end

  # Replays a captured upstream response verbatim, as the proxy does.
  # sobelow_skip ["XSS.SendResp"]
  defp commit(conn, %Captured{status: status, headers: headers, body: body}) do
    conn
    |> Proxy.put_response_headers(headers)
    |> send_resp(status, body)
  end
end
