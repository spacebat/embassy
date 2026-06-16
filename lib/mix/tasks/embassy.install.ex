if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.Embassy.Install do
    @shortdoc "Wires Embassy into a Phoenix application"
    @moduledoc """
    Installs Embassy: supervision tree, router forwards, body parser, and
    the `/cable` WebSocket upgrade.

    Full wiring runs by default. Opt out per step with `--no-proxy`,
    `--no-cable`, `--no-parsers`. Provide `--name`, `--finch`,
    `--transport uds|http`, and `--address` to skip the prompts; `--yes`
    takes defaults non-interactively.
    """

    use Igniter.Mix.Task

    @example "mix igniter.install embassy"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :embassy,
        example: @example,
        schema: [
          name: :string,
          finch: :string,
          transport: :string,
          address: :string,
          proxy: :boolean,
          cable: :boolean,
          parsers: :boolean,
          yes: :boolean
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      {igniter, opts} = resolve_opts(igniter)

      igniter
      |> add_supervision_tree(opts)
      |> add_router_forwards(opts)
      |> add_body_parsers(opts)
    end

    # --- option resolution -------------------------------------------------

    defp resolve_opts(igniter) do
      options = igniter.args.options
      yes? = Keyword.get(options, :yes, false)
      prefix = Igniter.Project.Module.module_name_prefix(igniter)

      {igniter, router} =
        Igniter.Libs.Phoenix.select_router(igniter, "Which router should Embassy mount into?")

      {igniter, endpoint} =
        Igniter.Libs.Phoenix.select_endpoint(igniter, router, "Which endpoint owns that router?")

      transport = resolve(options, :transport, "uds", "Transport (uds/http)", yes?)
      address = resolve(options, :address, default_address(transport), "Backend address", yes?)

      name =
        parse_module(
          resolve(options, :name, default_name(prefix, "Embassy"), "Embassy instance name", yes?)
        )

      finch =
        parse_module(
          resolve(options, :finch, default_name(prefix, "Finch"), "Finch instance name", yes?)
        )

      opts = %{
        prefix: prefix,
        router: router,
        endpoint: endpoint,
        name: name,
        finch: finch,
        transport_tuple: transport_tuple(transport, address),
        proxy?: Keyword.get(options, :proxy, true),
        cable?: Keyword.get(options, :cable, true),
        parsers?: Keyword.get(options, :parsers, true)
      }

      {igniter, opts}
    end

    defp resolve(options, key, default, label, yes?) do
      case Keyword.get(options, key) do
        nil -> if yes?, do: default, else: prompt_default(label, default)
        value -> value
      end
    end

    defp prompt_default(label, default) do
      case String.trim(Mix.shell().prompt("#{label} [#{default}]: ")) do
        "" -> default
        value -> value
      end
    end

    defp default_name(prefix, suffix), do: inspect(Module.concat(prefix, suffix))
    defp default_address("http"), do: "http://localhost:4001"
    defp default_address(_uds), do: "/tmp/backend.sock"

    defp parse_module(string), do: Module.concat([string])

    defp transport_tuple("http", address), do: "{:http, #{inspect(address)}}"
    defp transport_tuple(_uds, address), do: "{:uds, #{inspect(address)}}"

    # --- supervision tree -------------------------------------------------

    defp add_supervision_tree(igniter, opts) do
      # Place Finch and Embassy ahead of the endpoint so the proxy backend and
      # the WS terminator are ready before the endpoint starts accepting
      # connections. Igniter 0.8.0's `:after` placement predicate did not
      # reliably position children just before the endpoint, so we rely on
      # add_new_child's default front-insertion instead.
      #
      # Each call inserts at the front, so add Embassy first and Finch second to
      # leave Finch ahead of Embassy (Embassy uses Finch as its HTTP client).
      igniter
      |> Igniter.Project.Application.add_new_child({Embassy, name: opts.name, finch: opts.finch})
      |> Igniter.Project.Application.add_new_child({Finch, name: opts.finch})
    end

    defp add_router_forwards(igniter, opts) do
      forwards =
        [
          if(opts.cable?, do: cable_forward(opts)),
          if(opts.proxy?, do: proxy_forward(opts))
        ]
        |> Enum.reject(&is_nil/1)

      case forwards do
        [] ->
          igniter

        forwards ->
          igniter
          |> Igniter.Libs.Phoenix.add_scope("/", Enum.join(forwards, "\n\n"), router: opts.router)
          |> maybe_cable_notice(opts)
      end
    end

    defp proxy_forward(opts) do
      """
      forward "/", Embassy.ReverseProxy,
        embassy: #{inspect(opts.name)},
        transport: #{opts.transport_tuple}
      """
      |> String.trim_trailing()
    end

    defp cable_forward(opts) do
      """
      forward "/cable", Embassy.Upgrade,
        handler: #{cable_handler(opts)},
        subprotocols: ["actioncable-v1-json"],
        instance: #{inspect(opts.name)}
      """
      |> String.trim_trailing()
    end

    defp maybe_cable_notice(igniter, %{cable?: true} = opts) do
      Igniter.add_notice(igniter, """
      Embassy mounted a /cable WebSocket upgrade pointing at
      #{cable_handler(opts)}. Embassy ships no
      WebSock handler -- supply one (or install embassy_rails for
      ActionCable/AnyCable) before the route will accept connections.
      """)
    end

    defp maybe_cable_notice(igniter, _opts), do: igniter

    defp cable_handler(opts), do: inspect(Module.concat(opts.prefix, CableHandler))

    # --- body parser wiring -----------------------------------------------

    @body_reader "{Embassy.BodyCache, :read_body, []}"

    defp add_body_parsers(igniter, %{parsers?: false}), do: igniter

    defp add_body_parsers(igniter, opts) do
      if has_plug_parsers?(igniter, opts.endpoint) do
        set_body_reader(igniter, opts.endpoint)
      else
        body_reader_notice(igniter)
      end
    end

    # Read-only probe: does the endpoint contain a `plug Plug.Parsers` call we
    # can safely patch? We check before attempting the edit so the no-match case
    # falls through to a paste-this-in notice instead of mangling anything.
    defp has_plug_parsers?(igniter, endpoint) do
      case Igniter.Project.Module.find_module(igniter, endpoint) do
        {:ok, {_igniter, _source, zipper}} ->
          match?({:ok, _}, move_to_parsers(zipper))

        {:error, _igniter} ->
          false
      end
    end

    defp set_body_reader(igniter, endpoint) do
      # has_plug_parsers?/2 already confirmed the module is findable with a
      # do-block, so find_and_update_module/3 cannot return {:error, _} here.
      {:ok, igniter} =
        Igniter.Project.Module.find_and_update_module(igniter, endpoint, fn zipper ->
          with {:ok, zipper} <- move_to_parsers(zipper),
               {:ok, zipper} <- Igniter.Code.Function.move_to_nth_argument(zipper, 1) do
            Igniter.Code.Keyword.set_keyword_key(
              zipper,
              :body_reader,
              Sourceror.parse_string!(@body_reader),
              fn z -> {:ok, z} end
            )
          end
        end)

      igniter
    end

    defp move_to_parsers(zipper) do
      Igniter.Code.Function.move_to_function_call(zipper, :plug, 2, fn call ->
        Igniter.Code.Function.argument_equals?(call, 0, Plug.Parsers)
      end)
    end

    defp body_reader_notice(igniter) do
      Igniter.add_notice(igniter, """
      Could not find a `plug Plug.Parsers` call in your endpoint to patch.
      Add the body reader manually so the proxy can forward parsed bodies:

          plug Plug.Parsers,
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            json_decoder: Jason,
            body_reader: #{@body_reader}
      """)
    end
  end
else
  defmodule Mix.Tasks.Embassy.Install do
    @shortdoc "Wires Embassy into a Phoenix application (requires igniter)"
    @moduledoc false
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      The embassy.install task requires the optional :igniter dependency.
      Add it to your deps and run mix deps.get:

          {:igniter, "~> 0.6", only: [:dev, :test]}
      """)
    end
  end
end
