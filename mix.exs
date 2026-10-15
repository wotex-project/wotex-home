defmodule WotexHome.MixProject do
  @moduledoc false

  use Mix.Project

  @ex_maude_version "0.5.0"
  @wotex_udp_ref "dde1837f03f88a847ba5a0ec4479711a5ff1cf96"
  @profiles_ref "687a5cd70267fa47dbfb36e28eccad6ef2964fdf"
  @booking_ref "25ad04548c01e5a24c5505acfbe063550d3efaa0"

  def project do
    [
      app: :wotex_home,
      name: "WoTEx Home",
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "WotexHome",
        extras: ["README.md" | Path.wildcard("docs/**/*.md")]
      ],
      releases: [
        wotex_home: [
          steps: [
            :assemble,
            &prepare_public_registry/1,
            &strip_unusable_native_backends/1,
            &bundle_linux_native/1,
            &include_maude_legal_inputs/1,
            &include_apache_license_inputs/1,
            &include_wotex_udp_legal_inputs/1,
            &include_producer_legal_inputs/1,
            &package_linux_service/1
          ]
        ]
      ],
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [mod: {WotexHome.Application, []}, extra_applications: [:logger]]
  end

  def source_pins,
    do: %{
      wotex_udp: @wotex_udp_ref,
      wotex: @profiles_ref,
      wotex_runtime: @profiles_ref,
      wotex_profiles: @profiles_ref,
      wotex_binding_mqtt: @profiles_ref,
      ex_booking: @booking_ref
    }

  def producer_package_paths,
    do: %{
      wotex: "packages/wotex",
      wotex_runtime: "packages/wotex-runtime",
      wotex_profiles: "packages/wotex-profiles",
      wotex_binding_mqtt: "packages/wotex-binding-mqtt"
    }

  defp deps do
    [
      {:exqlite, "~> 0.42.0"},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:bumblebee, "~> 0.8.0", only: :dev, runtime: false},
      {:exla, "~> 1.0", only: :dev, runtime: false},
      {:yaml_elixir, "~> 2.12", runtime: false},
      local_or_hex(:ex_maude, "../ex_maude", @ex_maude_version, env: :prod),
      producer_dep(:wotex, "wotex"),
      producer_dep(:wotex_runtime, "wotex-runtime"),
      producer_dep(:wotex_profiles, "wotex-profiles"),
      producer_dep(:wotex_binding_mqtt, "wotex-binding-mqtt"),
      local_or_git(
        :ex_booking,
        "../ex_booking",
        [git: "https://github.com/futhr/ex_booking.git", ref: @booking_ref],
        env: :prod
      ),
      local_or_git(
        :wotex_udp,
        "../wotex/packages/wotex-udp",
        [
          git: "https://github.com/wotex-project/wotex.git",
          ref: @wotex_udp_ref,
          sparse: "packages/wotex-udp"
        ],
        env: :prod
      )
    ]
  end

  defp producer_dep(app, directory) do
    local_or_git(
      app,
      "../wotex/packages/" <> directory,
      [
        git: "https://github.com/wotex-project/wotex.git",
        ref: @profiles_ref,
        sparse: "packages/" <> directory
      ],
      env: :prod,
      override: true
    )
  end

  defp local_or_hex(app, local_path, version, common_opts) do
    local_mixfile = Path.expand(Path.join(local_path, "mix.exs"), __DIR__)

    if System.get_env("WOTEX_HOME_PATH_DEPS") == "1" and
         System.get_env("WOTEX_HOME_GIT_DEPS") != "1" and File.regular?(local_mixfile) do
      {app, [path: local_path] ++ common_opts}
    else
      {app, "== #{version}", common_opts}
    end
  end

  defp local_or_git(app, local_path, git_opts, common_opts) do
    local_mixfile = Path.expand(Path.join(local_path, "mix.exs"), __DIR__)

    if System.get_env("WOTEX_HOME_PATH_DEPS") == "1" and
         System.get_env("WOTEX_HOME_GIT_DEPS") != "1" and File.regular?(local_mixfile) do
      {app, [path: local_path] ++ common_opts}
    else
      {app, git_opts ++ common_opts}
    end
  end

  defp strip_unusable_native_backends(release) do
    # Mix loads this project before Home compilation. The release hook runs
    # afterward, when its freshly compiled helper is available.
    with {:ok, profile} <- apply(Woh.Tool.ReleaseNativeBackends, :profile, []),
         :ok <- apply(Woh.Tool.ReleaseNativeBackends, :prune, [release.path, profile]) do
      release
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp prepare_public_registry(release) do
    case apply(Woh.Tool.LifxRegistry, :prepare_release, [release.path]) do
      {:ok, _} -> release
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp bundle_linux_native(release) do
    case apply(Woh.Tool.ReleaseNativeBackends, :profile, []) do
      {:ok, :darwin_arm64} ->
        release

      {:ok, :linux_arm64} ->
        case apply(Woh.Tool.LinuxNativeBundle, :assemble, [release.path, __DIR__]) do
          {:ok, count} ->
            Mix.shell().info(
              "Bundled and verified #{count} Linux ELF files; license review remains unresolved."
            )

            release

          {:error, reason} ->
            Mix.raise(reason)
        end

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp package_linux_service(release) do
    case apply(Woh.Tool.ReleaseNativeBackends, :profile, []) do
      {:ok, :darwin_arm64} ->
        release

      {:ok, :linux_arm64} ->
        with {:ok, revision} <- apply(Woh.Tool.ReleaseInventory, :source_revision, [__DIR__]),
             :ok <- apply(Woh.Tool.LinuxInstallFiles, :assemble, [release.path]),
             {:ok, _} <- apply(Woh.Tool.LinuxServicePackage, :assemble, [release.path, revision]) do
          Mix.shell().info("Packaged inert Linux service configuration; no service registered.")
          release
        else
          {:error, reason} -> Mix.raise(reason)
        end

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp include_maude_legal_inputs(release) do
    case Path.wildcard(Path.join(release.path, "lib/ex_maude-*/priv/maude")) do
      [directory] ->
        File.cp!(
          Path.join(__DIR__, "docs/provenance/license-inputs/maude-3.5.1-COPYING"),
          Path.join(directory, "COPYING")
        )

        File.cp!(
          Path.join(__DIR__, "docs/provenance/license-inputs/ex-maude-THIRD_PARTY_NOTICES.md"),
          Path.join(directory, "THIRD_PARTY_NOTICES.md")
        )

      _ ->
        Mix.raise("Expected exactly one bundled Maude private directory")
    end

    release
  end

  defp include_apache_license_inputs(release) do
    source = Path.join(__DIR__, "docs/provenance/license-inputs/apache-2.0-LICENSE.txt")

    for package <- ["db_connection-2.10.2", "rustler_precompiled-0.10.0"] do
      directory = Path.join([release.path, "lib", package])

      if not File.dir?(directory),
        do: Mix.raise("Missing locked Apache package in release: #{package}")

      destination = Path.join(directory, "priv/LICENSE")
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end

    release
  end

  defp include_wotex_udp_legal_inputs(release) do
    case Path.wildcard(Path.join(release.path, "lib/wotex_udp-*")) do
      [application] ->
        copy_wotex_udp_legal_inputs(application)

      _ ->
        Mix.raise("Expected exactly one bundled WoTEx UDP application")
    end

    release
  end

  defp include_producer_legal_inputs(release) do
    for {app, package} <- producer_package_paths() do
      [application] = Path.wildcard(Path.join(release.path, "lib/#{app}-*"))

      for name <- ~w(LICENSE NOTICE) do
        source = Path.join([__DIR__, "deps", Atom.to_string(app), package, name])
        destination = Path.join([application, "priv", name])
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(source, destination)
      end
    end

    release
  end

  defp copy_wotex_udp_legal_inputs(application) do
    destination = Path.join(application, "priv")
    File.mkdir_p!(destination)

    for filename <- ["LICENSE", "NOTICE"] do
      File.cp!(
        Path.join(__DIR__, "docs/provenance/license-inputs/wotex-udp-#{filename}"),
        Path.join(destination, filename)
      )
    end
  end
end
