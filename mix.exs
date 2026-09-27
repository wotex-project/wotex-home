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
        {:ex_maude, path: "vendor/ex_maude", env: :prod}
      ],
      releases: [wotex_home: [steps: [:assemble, &strip_unusable_native_backends/1, &include_maude_legal_inputs/1, &include_apache_license_inputs/1]]],
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [mod: {WotexHome.Application, []}, extra_applications: [:logger]]
  end

  defp strip_unusable_native_backends(release) do
    foreign_maude =
      case {:os.type(), to_string(:erlang.system_info(:system_architecture))} do
        {{:unix, :darwin}, "aarch64" <> _} ->
          ["maude/bin/maude-darwin-x64", "maude/bin/maude-linux-x64"]

        _ ->
          []
      end

    for priv <- Path.wildcard(Path.join(release.path, "lib/ex_maude-*/priv")),
        relative <- foreign_maude ++ ["maude_bridge"] do
      case File.rm(Path.join(priv, relative)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Mix.raise("Cannot remove unused native backend: #{reason}")
      end
    end

    release
  end

  defp include_maude_legal_inputs(release) do
    case Path.wildcard(Path.join(release.path, "lib/ex_maude-*/priv/maude")) do
      [directory] ->
        File.cp!(
          Path.join(__DIR__, "docs/provenance/license-inputs/maude-3.5.1-COPYING"),
          Path.join(directory, "COPYING")
        )

        File.cp!(
          Path.join(__DIR__, "vendor/ex_maude/THIRD_PARTY_NOTICES.md"),
          Path.join(directory, "THIRD_PARTY_NOTICES.md")
        )

      _ ->
        Mix.raise("Expected exactly one bundled Maude private directory")
    end

    release
  end

  defp include_apache_license_inputs(release) do
    source = Path.join(__DIR__, "docs/provenance/license-inputs/apache-2.0-LICENSE.txt")

    for package <- ["db_connection-2.10.2", "rustler_precompiled-0.9.0"] do
      directory = Path.join([release.path, "lib", package])

      if not File.dir?(directory),
        do: Mix.raise("Missing locked Apache package in release: #{package}")

      destination = Path.join(directory, "priv/LICENSE")
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end

    release
  end
end
