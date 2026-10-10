defmodule Mix.Tasks.Woh.Native.Paired.Session.Smoke do
  @moduledoc "Checks independent paired scope correspondence and actual unsigned production factory refusal without a fabricated signing/session seal or SecItem."
  @shortdoc "Check paired session scope and unsigned production refusal"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root = Path.join("/private/tmp", "woh-paired-session-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "paired-session-smoke")
    directory = Path.join(root, "metadata")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      sources =
        ~w(NativeControllerPairingWire NativeControllerTLSClient NativeControllerAPIClient
        NativeControllerDomainClient NativeControllerAssociations NativeControllerAssociationStorage
        NativeControllerPairingCustody NativePairedKeychainCustodian NativePairedControllerSession
        SignedSetupPeer NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences
        NativePrivateDocuments LocalHealthClient NativeBrokerClient NativeSetupSocket
        NativeThingClient NativeRuleOperationWire NativeRuleClient NativeScheduleClient NativeScheduleWire
        NativePendingCodec NativePendingStorage NativePendingPairedCustody NativePendingRecoveryOperations
        NativePairedPendingRecoveryOperations NativePairedRecoveryCorrespondence)

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
          [
            Path.expand("native/macos/Tests/NativePairedControllerSessionSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 Path.expand("test/fixtures/controller_connections/native_associations_v1.json"),
                 directory
               ],
               16_384,
               15_000
             ),
           true <-
             String.trim(output) ==
               "native paired session scope, bounded owner and actual unsigned production refusal passed" do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native paired session smoke failed: #{reason}")
        _ -> Mix.raise("native paired session fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.paired.session.smoke")
end
