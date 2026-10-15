defmodule Mix.Tasks.Woh.Native.Mqtt.Setup.Smoke do
  @moduledoc """
  Checks and renders explicit local MQTT setup with inert operation metadata.

  Run `mix woh.native.mqtt.setup.smoke` on Apple Silicon macOS. The Swift 6
  fixture covers selection, explicit preparation/import/publication, duplicate
  clicks, busy/session fences, late replies and identical uncertain retry. It
  renders prepared and uncertain panels under `_build/native/`. Inert drafts
  cannot authorize live operations. No Keychain operation or signing success
  is synthesized; actual foreground files/producer checks belong to
  `mix woh.native.mqtt.provision.smoke` and installed custody remains separate.
  """

  @shortdoc "Check and render native MQTT setup"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command
  @impl Mix.Task
  def run([]) do
    root = Path.join("/private/tmp", "woh-mqtt-setup-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    preview = Path.expand("_build/native")
    File.mkdir_p!(preview)

    try do
      sources =
        ~w(NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments SignedSetupPeer NativeKeychainCustodian NativeAuthoringFiles NativeMQTTProvisioning NativeMQTTSetupPanel)

      executable = Path.join(root, "fixture")

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache")
        ] ++
          Enum.flat_map(
            ~w(SwiftUI AppKit Security LocalAuthentication CryptoKit),
            &["-framework", &1]
          ) ++
          Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
          [Path.expand("native/macos/Tests/NativeMQTTSetupSmoke.swift"), "-o", executable]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90000),
           {:ok, output} <- Command.run_diagnostic(executable, [preview], 16384, 15000),
           do: Mix.shell().info(String.trim(output)),
           else: ({:error, reason} -> Mix.raise("native MQTT setup smoke failed: #{reason}"))
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.mqtt.setup.smoke")
end
