defmodule WotexHome.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_home,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:exqlite, "~> 0.40.0"},
        {:ex_maude, path: "../ex_maude", env: :prod}
      ],
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [mod: {WotexHome.Application, []}, extra_applications: [:logger]]
  end
end
