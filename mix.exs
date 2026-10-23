defmodule Embassy.MixProject do
  use Mix.Project

  @source_url "https://github.com/spacebat/embassy"
  @version "0.4.2"

  def project do
    [
      app: :embassy,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      hex: [
        # cowlib is only pulled in by bypass (test-only) and has no fixed
        # release yet; library consumers resolve their own cowlib.
        ignore_advisories: ["EEF-CVE-2026-43966"]
      ],
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix ci` is what GitHub Actions runs. Dialyzer is deliberately not in it;
  # run `mix dialyzer` by hand.
  defp aliases do
    [
      ci: [
        "deps.unlock --check-unused",
        "hex.audit",
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo",
        "sobelow --skip --exit",
        "test --warnings-as-errors"
      ]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:finch, "~> 0.19"},
      {:websock_adapter, "~> 0.5"},
      {:igniter, "~> 0.6", optional: true},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Phoenix-side reverse proxy and per-instance config harness for " <>
      "running Phoenix as the front door to a backend web application."
  end

  defp package do
    [
      maintainers: ["Andrew Kirkpatrick"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
