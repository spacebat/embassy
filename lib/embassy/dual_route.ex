defmodule Embassy.DualRoute do
  @moduledoc """
  Scientist-style strangler-fig plug. Returns one backend's response (the
  canonical side) while running the other as an asynchronous shadow,
  comparing them and reporting the result.

  See the README "Strangler-fig migration with DualRoute" section for the
  full model. Both `control` and `candidate` are target specs:
  `{:proxy, transport: ...}` or `{:plug, Module, opts}`.

  ## Options

  `:embassy`, `:control`, `:candidate` and `:comparator` are required.
  `:canonical` (`:control` | `:candidate`, default `:control`),
  `:methods` (default `["GET"]`), `:sample_rate` (default `1.0`),
  `:shadow_timeout` in ms (default `5_000`), `:reporter`,
  `:max_body_length` (default `50_000_000`), and `:route`, the telemetry
  route label (string or atom; defaults to the mount point from
  `conn.script_name`). Set `:route` when mounting with `get`/`post`
  rather than `forward`: without a mount point every such route is
  labelled `"/"`. Also set it under a dynamic `Plug.Router` `forward`.

  ## Telemetry

    * `[:embassy, :dual_route, :dispatch]` — once per request served
      (not on a 413/400 body rejection). `%{monotonic_time}`; metadata
      `instance`, `route`, `method`, `canonical`, `served_by`
      (`:proxy | :plug`, the canonical target's kind) and `sampled`.
    * `[:embassy, :dual_route, :match | :diff]` — `%{control_duration,
      candidate_duration}`; metadata `instance`, `route`, `request_path`,
      `method`, `canonical`, `comparator`, `status`, `diff`.
    * `[:embassy, :dual_route, :error]` — shadow or reporter failure;
      metadata `instance`, `route`, `request_path`, `method`, `reason`.

  `route` is the label; `request_path` is the concrete path. Proxy
  targets also emit `[:embassy, :proxy, *]` events (see
  `Embassy.ReverseProxy`) with `role: :canonical` or `role: :shadow`.
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
      max_body_length: Keyword.get(opts, :max_body_length, @default_max_body_length),
      route: Keyword.get(opts, :route)
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
    route = Proxy.route_label(conn, opts.route)
    sampled = experiment?(conn, opts)
    emit_dispatch(conn, route, sampled, opts)

    if sampled do
      run_experiment(conn, body, route, snapshot, opts)
    else
      {conn, _captured} =
        Target.run_canonical(canonical_target(opts), conn, body, snapshot, ctx(route, :canonical))

      conn
    end
  end

  defp emit_dispatch(conn, route, sampled, opts) do
    :telemetry.execute(
      [:embassy, :dual_route, :dispatch],
      %{monotonic_time: System.monotonic_time()},
      %{
        instance: opts.embassy,
        route: route,
        method: conn.method,
        canonical: opts.canonical,
        served_by: elem(canonical_target(opts), 0),
        sampled: sampled
      }
    )
  end

  defp ctx(route, role), do: %{route: route, role: role}

  defp experiment?(conn, opts) do
    String.upcase(conn.method) in opts.methods and :rand.uniform() <= opts.sample_rate
  end

  defp run_experiment(conn, body, route, snapshot, opts) do
    canonical_start = System.monotonic_time()

    {conn, canonical_captured} =
      Target.run_canonical(canonical_target(opts), conn, body, snapshot, ctx(route, :canonical))

    canonical_duration = System.monotonic_time() - canonical_start

    request = capture_request(conn, body, route)

    Task.Supervisor.start_child(snapshot.task_supervisor, fn ->
      run_shadow(request, canonical_captured, canonical_duration, snapshot, opts)
    end)

    conn
  end

  # The shadow task receives a minimal copy of the request (no live
  # adapter), so it can rebuild a conn for a plug target or a Finch
  # request for a proxy target without touching the original socket.
  defp capture_request(conn, body, route) do
    %{
      route: route,
      method: conn.method,
      request_path: conn.request_path,
      query_string: conn.query_string,
      req_headers: conn.req_headers,
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      remote_ip: conn.remote_ip,
      body: body
    }
  end

  defp run_shadow(request, canonical_captured, canonical_duration, snapshot, opts) do
    shadow_conn = rebuild_conn(request)

    case run_with_timeout(
           fn ->
             Target.run(
               shadow_target(opts),
               shadow_conn,
               request.body,
               snapshot,
               ctx(request.route, :shadow)
             )
           end,
           snapshot,
           opts
         ) do
      {:ok, shadow_captured, shadow_duration} ->
        compare_and_report(
          canonical_captured,
          canonical_duration,
          shadow_captured,
          shadow_duration,
          request,
          opts
        )

      {:timeout, start} ->
        emit_shadow_timeout(shadow_target(opts), shadow_conn, request.route, snapshot, start)
        emit_error(request, opts, :shadow_timeout)

      {:error, reason} ->
        emit_error(request, opts, reason)
    end
  rescue
    e -> emit_error(request, opts, {:exception, e})
  catch
    kind, reason -> emit_error(request, opts, {kind, reason})
  end

  defp shadow_target(%{canonical: :candidate} = opts), do: opts.control
  defp shadow_target(opts), do: opts.candidate

  defp run_with_timeout(fun, snapshot, opts) do
    task = Task.Supervisor.async_nolink(snapshot.task_supervisor, fun)
    start = System.monotonic_time()

    case Task.yield(task, opts.shadow_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, captured}} -> {:ok, captured, System.monotonic_time() - start}
      {:ok, {:error, reason}} -> {:error, {:target_error, reason}}
      {:exit, reason} -> {:error, {:shadow_exit, reason}}
      nil -> {:timeout, start}
    end
  end

  # A proxy shadow killed at the deadline emitted `:start` but nothing
  # else; close the pair so starts and stops/exceptions balance.
  defp emit_shadow_timeout({:proxy, %{transport: transport}}, conn, route, snapshot, start) do
    conn
    |> Proxy.event_metadata(snapshot.name, transport, route, :shadow)
    |> Proxy.emit_exception(start, :shadow_timeout)
  end

  defp emit_shadow_timeout(_plug, _conn, _route, _snapshot, _start), do: :ok

  # `adapter` is a deliberate placeholder, never invoked: for a plug
  # target `Target.run/5` swaps in `CaptureAdapter` before calling the
  # plug, and for a proxy target only the request fields are read to
  # build the Finch request. Keep it that way - touching the adapter
  # here before the swap would surface inside the shadow as an :error.
  defp rebuild_conn(request) do
    %Plug.Conn{
      method: request.method,
      request_path: request.request_path,
      path_info: split_path(request.request_path),
      query_string: request.query_string,
      req_headers: request.req_headers,
      scheme: request.scheme,
      host: request.host,
      port: request.port,
      remote_ip: request.remote_ip,
      adapter: {Plug.MissingAdapter, nil},
      owner: self()
    }
  end

  defp split_path(path) do
    path |> String.split("/", trim: true)
  end

  defp compare_and_report(
         canonical_captured,
         canonical_duration,
         shadow_captured,
         shadow_duration,
         request,
         opts
       ) do
    {control, candidate, control_duration, candidate_duration} =
      orient(
        opts.canonical,
        canonical_captured,
        canonical_duration,
        shadow_captured,
        shadow_duration
      )

    verdict_detail = Embassy.DualRoute.Comparator.compare(opts.comparator, control, candidate)
    {verdict, diff} = split_verdict(verdict_detail)

    result = %Embassy.DualRoute.Result{
      route: request.route,
      request_path: request.request_path,
      method: request.method,
      verdict: verdict,
      comparator: opts.comparator,
      canonical: opts.canonical,
      control: control,
      candidate: candidate,
      diff: diff,
      control_duration: control_duration,
      candidate_duration: candidate_duration,
      sampled?: true
    }

    :telemetry.execute(
      [:embassy, :dual_route, verdict],
      %{control_duration: control_duration, candidate_duration: candidate_duration},
      %{
        instance: opts.embassy,
        route: result.route,
        request_path: result.request_path,
        method: result.method,
        canonical: opts.canonical,
        comparator: opts.comparator,
        status: {control.status, candidate.status},
        diff: diff
      }
    )

    run_reporter(result, opts)
  end

  defp orient(:control, canon, canon_dur, shadow, shadow_dur),
    do: {canon, shadow, canon_dur, shadow_dur}

  defp orient(:candidate, canon, canon_dur, shadow, shadow_dur),
    do: {shadow, canon, shadow_dur, canon_dur}

  defp split_verdict(:match), do: {:match, nil}
  defp split_verdict({:diff, detail}), do: {:diff, detail}

  defp run_reporter(_result, %{reporter: nil}), do: :ok

  defp run_reporter(result, %{reporter: reporter} = opts) do
    reporter.report(result)
  rescue
    e ->
      emit_error(
        %{route: result.route, method: result.method, request_path: result.request_path},
        opts,
        {:reporter_error, e}
      )
  end

  defp emit_error(request, opts, reason) do
    :telemetry.execute(
      [:embassy, :dual_route, :error],
      %{monotonic_time: System.monotonic_time()},
      %{
        instance: opts.embassy,
        route: request.route,
        request_path: request.request_path,
        method: request.method,
        reason: reason
      }
    )

    :ok
  end

  defp canonical_target(%{canonical: :candidate} = opts), do: opts.candidate
  defp canonical_target(opts), do: opts.control

  defp send_plain(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end
end
