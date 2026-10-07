defmodule Woh.Tool.MacosAppAssemble do
  @moduledoc false

  alias Woh.Tool.{
    Command,
    Json,
    MacosAppInventory,
    MacosAppSpdx,
    MacosNativeDeps,
    ReleaseInventory
  }

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @release "_build/prod/rel/wotex_home"
  @app "_build/macos/WotexHome.app"

  def assemble(project, release_path \\ @release) do
    project = Path.expand(project)
    release = Path.expand(release_path, project)
    native = Path.join(project, "native/macos")
    final = Path.join(project, @app)
    require_file!(Path.join(release, "bin/wotex_home"), "assemble the production release first")

    with {:ok, _} <- ReleaseInventory.verify(release),
         {:ok, revision} <- ReleaseInventory.source_revision(project),
         {:ok, inventory} <- Json.read(Path.join(release, ReleaseInventory.manifest()), 2_000_000) do
      ensure!(
        inventory["source_revision"] == revision,
        "release inventory source revision differs from current source"
      )

      build_project!(native)

      stage = final <> ".staging-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      module_cache = stage <> ".swift-cache"
      File.mkdir_p!(Path.dirname(final))

      try do
        File.mkdir!(module_cache)
        File.chmod!(module_cache, 0o700)
        build_bundle!(stage, native, release, revision, module_cache)
        validate_bundle!(stage, revision)
        File.rm_rf!(final)
        File.rename!(stage, final)
        {:ok, final}
      after
        File.rm_rf!(stage)
        File.rm_rf!(module_cache)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "macOS assembly file error: #{Exception.message(error)}"}
    error in File.CopyError -> {:error, "macOS assembly copy error: #{Exception.message(error)}"}
  end

  defp build_project!(native) do
    command!(
      "xcodegen",
      [
        "generate",
        "--spec",
        Path.join(native, "project.yml"),
        "--project",
        native
      ],
      30_000
    )

    ensure!(
      File.dir?(Path.join(native, "WotexHome.xcodeproj")),
      "XcodeGen did not produce the project"
    )
  end

  defp build_bundle!(app, native, release, revision, module_cache) do
    macos = Path.join(app, "Contents/MacOS")
    File.mkdir_p!(macos)
    File.write!(Path.join(app, "Contents/Info.plist"), info_plist(revision))
    helper = Path.join(app, "Contents/Library/LoginItems/WotexHomeAgent.app/Contents")
    File.mkdir_p!(Path.join(helper, "MacOS"))
    File.write!(Path.join(helper, "Info.plist"), helper_info_plist(revision))

    command!(
      "swiftc",
      [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        module_cache,
        "-target",
        "arm64-apple-macos15.0",
        "-framework",
        "SwiftUI",
        "-framework",
        "ServiceManagement",
        "-framework",
        "Security",
        "-framework",
        "LocalAuthentication",
        "-framework",
        "CryptoKit",
        Path.join(native, "Sources/WotexHomeApp.swift"),
        Path.join(native, "Sources/NativeHealthViewModel.swift"),
        Path.join(native, "Sources/LocalHealthClient.swift"),
        Path.join(native, "Sources/NativePendingCodec.swift"),
        Path.join(native, "Sources/NativePendingStorage.swift"),
        Path.join(native, "Sources/NativePendingCoordinator.swift"),
        Path.join(native, "Sources/HostMaintenancePanel.swift"),
        Path.join(native, "Sources/PortableProfilesPanel.swift"),
        Path.join(native, "Sources/SignedSetupPeer.swift"),
        Path.join(native, "Sources/NativeSetupWire.swift"),
        Path.join(native, "Sources/NativeCoreConnection.swift"),
        Path.join(native, "Sources/NativeNetworkPreferences.swift"),
        Path.join(native, "Sources/NativePrivateDocuments.swift"),
        Path.join(native, "Sources/NativeKeychainCustodian.swift"),
        Path.join(native, "Sources/NativeSetupSocket.swift"),
        Path.join(native, "Sources/NativeCredentialBroker.swift"),
        Path.join(native, "Sources/NativeAgentLifecycle.swift"),
        Path.join(native, "Sources/NativeBrokerClient.swift"),
        Path.join(native, "Sources/NativeSetupPanel.swift"),
        Path.join(native, "Sources/NativeNetworkInventory.swift"),
        Path.join(native, "Sources/NativeNetworkPanel.swift"),
        "-o",
        Path.join(macos, "WotexHome")
      ],
      120_000
    )

    command!(
      "swiftc",
      [
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        module_cache,
        "-target",
        "arm64-apple-macos15.0",
        "-framework",
        "Security",
        "-framework",
        "LocalAuthentication",
        "-framework",
        "CryptoKit",
        Path.join(native, "Agent/main.swift"),
        Path.join(native, "Sources/SignedSetupPeer.swift"),
        Path.join(native, "Sources/NativeSetupWire.swift"),
        Path.join(native, "Sources/NativeCoreConnection.swift"),
        Path.join(native, "Sources/NativeNetworkPreferences.swift"),
        Path.join(native, "Sources/NativePrivateDocuments.swift"),
        Path.join(native, "Sources/NativeKeychainCustodian.swift"),
        Path.join(native, "Sources/NativeSetupSocket.swift"),
        Path.join(native, "Sources/NativeCredentialBroker.swift"),
        Path.join(native, "Sources/NativeAgentLifecycle.swift"),
        "-o",
        Path.join(helper, "MacOS/WotexHomeAgent")
      ],
      120_000
    )

    agent = Path.join(app, "Contents/Library/LaunchAgents/org.wotex.home.agent.plist")
    File.mkdir_p!(Path.dirname(agent))
    File.cp!(Path.join(native, "LaunchAgents/org.wotex.home.agent.plist"), agent)

    ensure!(
      plist_value!(agent, "BundleProgram") ==
        "Contents/Library/LoginItems/WotexHomeAgent.app/Contents/MacOS/WotexHomeAgent",
      "agent plist points outside the bundled helper"
    )

    resources = Path.join(app, "Contents/Resources/WotexHomeRelease")
    File.mkdir_p!(Path.dirname(resources))
    File.cp_r!(release, resources)
    require_file!(Path.join(resources, "bin/wotex_home"), "release executable missing from app")

    ensure!(
      plist_value!(Path.join(app, "Contents/Info.plist"), "WotexHomeSourceRevision") == revision,
      "app source revision differs"
    )
  end

  defp validate_bundle!(app, revision) do
    with {:ok, native} <- MacosNativeDeps.check(app),
         {:ok, _} <- MacosAppSpdx.create(app),
         {:ok, _} <- MacosAppSpdx.verify(app),
         {:ok, _} <- MacosAppInventory.create(app, revision),
         {:ok, _} <- MacosAppInventory.verify(app) do
      Mix.shell().info("checked direct native loads for #{native["native_files"]} Mach-O files")
      :ok
    else
      {:error, reason} -> fail!(reason)
    end
  end

  defp info_plist(revision) do
    entries = [
      {"CFBundleDevelopmentRegion", "en"},
      {"CFBundleDisplayName", "WoTEx Home"},
      {"CFBundleExecutable", "WotexHome"},
      {"CFBundleIdentifier", "org.wotex.home"},
      {"CFBundleInfoDictionaryVersion", "6.0"},
      {"CFBundleName", "WotexHome"},
      {"CFBundlePackageType", "APPL"},
      {"CFBundleShortVersionString", "0.1.0"},
      {"CFBundleVersion", "1"},
      {"LSMinimumSystemVersion", "15.0"},
      {"NSPrincipalClass", "NSApplication"},
      {"NSLocalNetworkUsageDescription",
       "Home discovers and reads local devices only on the network you select."},
      {"WotexHomeSourceRevision", revision}
    ]

    plist(entries)
  end

  defp helper_info_plist(revision) do
    plist([
      {"CFBundleDevelopmentRegion", "en"},
      {"CFBundleExecutable", "WotexHomeAgent"},
      {"CFBundleIdentifier", "org.wotex.home.agent"},
      {"CFBundleInfoDictionaryVersion", "6.0"},
      {"CFBundleName", "WotexHomeAgent"},
      {"CFBundlePackageType", "APPL"},
      {"CFBundleShortVersionString", "0.1.0"},
      {"CFBundleVersion", "1"},
      {"LSMinimumSystemVersion", "15.0"},
      {"LSUIElement", true},
      {"NSLocalNetworkUsageDescription",
       "Home discovers and reads local devices only on the network you select."},
      {"WotexHomeSourceRevision", revision}
    ])
  end

  defp plist(entries) do
    values =
      Enum.map_join(entries, "\n", fn {key, value} ->
        encoded = if value == true, do: "<true/>", else: "<string>#{value}</string>"
        "    <key>#{key}</key>\n    #{encoded}"
      end)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <>
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " <>
      "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" <>
      "<plist version=\"1.0\">\n<dict>\n#{values}\n</dict>\n</plist>\n"
  end

  defp plist_value!(plist, key) do
    case Command.run("plutil", ["-extract", key, "raw", "-o", "-", plist], 4_096, 10_000) do
      {:ok, value} -> String.trim(value)
      {:error, _} -> fail!("invalid app plist value: #{key}")
    end
  end

  defp command!(executable, args, timeout_ms) do
    case Command.run(executable, args, 1_048_576, timeout_ms) do
      {:ok, _output} -> :ok
      {:error, reason} -> fail!("#{executable} failed: #{reason}")
    end
  end

  defp require_file!(path, reason) do
    ensure!(match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)), reason)
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Macos.App.Assemble do
  @moduledoc """
  Builds an unsigned macOS development app around an inventoried OTP release.

  Run `mix woh.macos.app.assemble [RELEASE_PATH]` from a clean committed source tree after
  creating the production release component report, SPDX document and final
  inventory. The task builds the SwiftUI app and helper, embeds the release,
  checks direct native loads, then creates and verifies the outer SPDX and
  inventory reports. The app is staged before it replaces the previous build.
  Assembly does not register a background agent, sign or notarize the app.
  """

  @shortdoc "Assemble the unsigned macOS development app"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]), do: assemble(nil)
  def run([release]), do: assemble(release)
  def run(_), do: Mix.raise("usage: mix woh.macos.app.assemble [RELEASE_PATH]")

  defp assemble(release) do
    result =
      if is_nil(release),
        do: Woh.Tool.MacosAppAssemble.assemble(File.cwd!()),
        else: Woh.Tool.MacosAppAssemble.assemble(File.cwd!(), release)

    case result do
      {:ok, app} -> Mix.shell().info("assembled unsigned development app: #{app}")
      {:error, reason} -> Mix.raise("macOS assembly failed: #{reason}")
    end
  end
end
