defmodule WotexUDP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/wotex-project/wotex"

  def project do
    [
      app: :wotex_udp,
      name: "Wotex UDP",
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      description: "Bounded caller-owned UDP datagram transport",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: "https://wotex.io",
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :missing_return, :underspecs, :extra_return]
      ]
    ]
  end

  def application, do: [extra_applications: []]

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.lcov": :test,
        "test.cover": :test,
        check: :test
      ]
    ]
  end

  defp deps do
    [
      {:benchee, "~> 1.5", only: :dev, runtime: false},
      {:benchee_markdown, "~> 0.3.4", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :docs], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "wotex_udp",
      licenses: ["Apache-2.0"],
      maintainers: ["Tobias Bohwalli <hi@futhr.io>"],
      links: %{"GitHub" => @source_url},
      files: ~w(.formatter.exs CHANGELOG.md LICENSE NOTICE README.md usage-rules.md lib mix.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras:
        [
          {"README.md", title: "Overview"},
          {"../../docs/packages/wotex-udp/specs/WUD.01-datagram-transport.md",
           title: "Datagram transport"},
          {"CHANGELOG.md", title: "Changelog"},
          {"LICENSE", title: "License"},
          {"NOTICE", title: "Notices"}
        ] ++ Path.wildcard("bench/output/*.md"),
      source_ref: "wotex-udp-v#{@version}",
      source_url: @source_url,
      formatters: ["html", "markdown", "epub"]
    ]
  end
end
