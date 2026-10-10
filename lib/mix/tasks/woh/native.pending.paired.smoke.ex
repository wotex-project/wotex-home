defmodule Mix.Tasks.Woh.Native.Pending.Paired.Smoke do
  @moduledoc "Checks public paired pending originals, actual private publication/races/restart and local recovery refusal without Keychain or API activity."
  @shortdoc "Check original paired pending custody"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root = Path.join("/private/tmp", "woh-paired-pending-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "paired-pending")

    try do
      sources =
        ~w(LocalHealthClient SignedSetupPeer NativeSetupSocket NativeBrokerClient NativeSetupWire NativeTargetWire
        NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativeRuleOperationWire NativeRuleClient NativeScheduleWire
        NativeScheduleClient NativePendingCodec NativePendingStorage NativePendingCoordinator NativePendingRecoveryOperations
        NativeControllerPairingWire NativeControllerAssociations NativePendingPairedCustody NativePendingPanel)

      sources = Enum.uniq(sources ++ Woh.Tool.NativePairedRecoverySources.names())

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(root, "cache"),
          "-target",
          "arm64-apple-macos15.0"
        ] ++
          Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
          [Path.expand("native/macos/Tests/NativePendingPairedSmoke.swift"), "-o", executable]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 Path.expand("test/fixtures/controller_connections/native_pending_v5.json"),
                 Path.expand("test/fixtures/controller_connections/native_associations_v1.json"),
                 root
               ],
               16_384,
               30_000
             ),
           true <-
             String.trim(output) ==
               "native paired pending independent codec, original joins, private CAS, restart, races and local recovery refusal passed" do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native paired pending smoke failed: #{reason}")
        _ -> Mix.raise("native paired pending fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.pending.paired.smoke")
end
