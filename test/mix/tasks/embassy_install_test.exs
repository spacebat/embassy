defmodule Mix.Tasks.Embassy.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.Embassy.Install

  describe "info/2" do
    test "declares the option schema" do
      info = Install.info([], nil)

      assert info.schema[:name] == :string
      assert info.schema[:finch] == :string
      assert info.schema[:transport] == :string
      assert info.schema[:address] == :string
      assert info.schema[:proxy] == :boolean
      assert info.schema[:cable] == :boolean
      assert info.schema[:parsers] == :boolean
    end
  end

  describe "smoke" do
    test "runs on a phoenix project without raising" do
      phx_test_project()
      |> Igniter.compose_task("embassy.install", [
        "--yes",
        "--transport",
        "uds",
        "--address",
        "/tmp/puma.sock"
      ])
      |> apply_igniter!()
    end
  end

  describe "supervision tree" do
    setup do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("embassy.install", [
          "--yes",
          "--name",
          "Test.Embassy",
          "--finch",
          "Test.Finch",
          "--transport",
          "uds",
          "--address",
          "/tmp/puma.sock"
        ])

      %{igniter: igniter}
    end

    test "adds Finch and Embassy to the application children", %{igniter: igniter} do
      igniter
      |> assert_has_patch("lib/test/application.ex", """
      + |      {Finch, [name: Test.Finch]},
      """)
      |> assert_has_patch("lib/test/application.ex", """
      + |      {Embassy, [name: Test.Embassy, finch: Test.Finch]}
      """)
    end

    test "is idempotent on a second run" do
      twice =
        phx_test_project()
        |> Igniter.compose_task("embassy.install", [
          "--yes",
          "--name",
          "Test.Embassy",
          "--finch",
          "Test.Finch",
          "--transport",
          "uds",
          "--address",
          "/tmp/puma.sock"
        ])
        |> apply_igniter!()
        |> Igniter.compose_task("embassy.install", [
          "--yes",
          "--name",
          "Test.Embassy",
          "--finch",
          "Test.Finch",
          "--transport",
          "uds",
          "--address",
          "/tmp/puma.sock"
        ])

      assert_unchanged(twice, "lib/test/application.ex")
    end
  end

  describe "router forwards" do
    defp install(args) do
      phx_test_project()
      |> Igniter.compose_task("embassy.install", base_args() ++ args)
    end

    defp base_args do
      [
        "--yes",
        "--name",
        "Test.Embassy",
        "--finch",
        "Test.Finch",
        "--transport",
        "uds",
        "--address",
        "/tmp/puma.sock"
      ]
    end

    test "adds the reverse-proxy forward with the chosen transport" do
      install([])
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/", Embassy.ReverseProxy, embassy: Test.Embassy, transport: {:uds, "/tmp/puma.sock"})
      """)
    end

    test "adds the /cable upgrade forward and a handler notice" do
      install([])
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/cable", Embassy.Upgrade,
      """)
      |> assert_has_notice(&(&1 =~ ~r/WebSock handler/))
    end

    test "--no-proxy suppresses only the proxy forward" do
      igniter = install(["--no-proxy"])
      refute String.contains?(rendered(igniter, "lib/test_web/router.ex"), "Embassy.ReverseProxy")
      assert String.contains?(rendered(igniter, "lib/test_web/router.ex"), "Embassy.Upgrade")
    end

    test "--no-cable suppresses only the cable forward" do
      igniter = install(["--no-cable"])
      assert String.contains?(rendered(igniter, "lib/test_web/router.ex"), "Embassy.ReverseProxy")
      refute String.contains?(rendered(igniter, "lib/test_web/router.ex"), "Embassy.Upgrade")
    end

    test "--no-proxy --no-cable leaves the router untouched" do
      assert_unchanged(install(["--no-proxy", "--no-cable"]), "lib/test_web/router.ex")
    end
  end

  describe "body parser" do
    test "adds the BodyCache body_reader to the endpoint Plug.Parsers" do
      phx_test_project()
      |> Igniter.compose_task("embassy.install", [
        "--yes",
        "--name",
        "Test.Embassy",
        "--finch",
        "Test.Finch",
        "--transport",
        "uds",
        "--address",
        "/tmp/puma.sock"
      ])
      |> assert_has_patch("lib/test_web/endpoint.ex", """
      + |    body_reader: {Embassy.BodyCache, :read_body, []}
      """)
    end

    test "--no-parsers leaves the endpoint untouched" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("embassy.install", [
          "--yes",
          "--no-parsers",
          "--name",
          "Test.Embassy",
          "--finch",
          "Test.Finch",
          "--transport",
          "uds",
          "--address",
          "/tmp/puma.sock"
        ])

      assert_unchanged(igniter, "lib/test_web/endpoint.ex")
    end

    test "emits a notice when no Plug.Parsers call is found" do
      # `phx_test_project(files: ...)` does not survive `igniter.phx.install`
      # regenerating the endpoint, so replace the endpoint after the project
      # exists to get one WITHOUT a `plug Plug.Parsers` call.
      bare_endpoint = """
      defmodule TestWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :test

        plug TestWeb.Router
      end
      """

      igniter =
        phx_test_project()
        |> Igniter.create_or_update_file("lib/test_web/endpoint.ex", bare_endpoint, fn source ->
          Rewrite.Source.update(source, :content, bare_endpoint)
        end)
        |> apply_igniter!()
        |> Igniter.compose_task("embassy.install", [
          "--yes",
          "--name",
          "Test.Embassy",
          "--finch",
          "Test.Finch",
          "--transport",
          "uds",
          "--address",
          "/tmp/puma.sock"
        ])

      assert_has_notice(igniter, &(&1 =~ ~r/Embassy.BodyCache/))
    end
  end

  describe "full install" do
    test "wires every step in one run" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("embassy.install", [
          "--yes",
          "--name",
          "Test.Embassy",
          "--finch",
          "Test.Finch",
          "--transport",
          "http",
          "--address",
          "http://localhost:3000"
        ])

      igniter
      |> assert_has_patch("lib/test/application.ex", """
      + |      {Embassy, [name: Test.Embassy, finch: Test.Finch]}
      """)
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/", Embassy.ReverseProxy,
      + |      embassy: Test.Embassy,
      + |      transport: {:http, "http://localhost:3000"}
      + |    )
      """)
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/cable", Embassy.Upgrade,
      """)
      |> assert_has_patch("lib/test_web/endpoint.ex", """
      + |    body_reader: {Embassy.BodyCache, :read_body, []}
      """)
    end
  end

  # Renders the post-run content of a file from a composed igniter, for
  # substring assertions where a full patch block is overkill.
  defp rendered(igniter, path) do
    igniter
    |> apply_igniter!()
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
