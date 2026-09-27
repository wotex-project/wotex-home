defmodule WotexHome.Firmware.MixProject do
  use Mix.Project

  @app :wotex_home_firmware

  def project do
    [
      app: @app,
      name: "WoTEx Home development",
      version: "0.1.0",
      author: "WoTEx Home",
      description: "Unqualified Raspberry Pi 4 development firmware",
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [extra_applications: [:logger, :runtime_tools], mod: {WotexHome.Firmware.Application, []}]
  end

  def cli, do: [preferred_targets: [run: :host, test: :host]]

  defp deps do
    [
      {:wotex_home, path: "../.."},
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:nerves_runtime, "~> 0.13.12"},
      {:nerves_system_rpi4, "~> 2.0.3", runtime: false, targets: :rpi4}
    ]
  end

  defp release do
    [
      overwrite: true,
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble, &strip_foreign_ex_maude_binaries/1],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp strip_foreign_ex_maude_binaries(release) do
    for priv <- Path.wildcard(Path.join(release.path, "lib/ex_maude-*/priv")),
        relative <- [
          "maude/bin/maude-darwin-arm64",
          "maude/bin/maude-darwin-x64",
          "maude/bin/maude-linux-x64",
          "maude_bridge"
        ] do
      case File.rm(Path.join(priv, relative)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Mix.raise("Cannot remove foreign ex_maude binary: #{reason}")
      end
    end

    release
  end
end
