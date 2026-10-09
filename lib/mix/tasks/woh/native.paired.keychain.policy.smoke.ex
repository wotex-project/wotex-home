defmodule Mix.Tasks.Woh.Native.Paired.Keychain.Policy.Smoke do
  @moduledoc "Checks independent inert paired Keychain queries and actual unsigned signing refusal; never creates a seal or calls SecItem."
  @shortdoc "Check paired Keychain policy and unsigned custody refusal"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root = Path.join("/private/tmp", "woh-paired-keychain-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "paired-keychain-policy")

    try do
      sources =
        ~w(NativeControllerPairingWire NativeControllerTLSClient NativeControllerAssociations
        NativeControllerPairingCustody NativePairedKeychainCustodian SignedSetupPeer NativeSetupWire NativeTargetWire)

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
            Path.expand("native/macos/Tests/NativePairedKeychainPolicySmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [Path.expand("test/fixtures/controller_connections/native_associations_v1.json")],
               16_384,
               10_000
             ),
           true <-
             String.trim(output) ==
               "native paired Keychain inert policy and actual unsigned custody refusal passed" do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native paired Keychain policy smoke failed: #{reason}")
        _ -> Mix.raise("native paired Keychain policy fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.paired.keychain.policy.smoke")
end
