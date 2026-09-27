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
      releases: [wotex_home: [steps: [:assemble, &strip_unusable_native_backends/1]]],
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
end
