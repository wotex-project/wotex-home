defmodule Woh.Tool.NativeKeychainPolicySmoke do
  @moduledoc false

  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-native-keychain-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "keychain-policy-smoke")

    try do
      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(directory, "swift-module-cache"),
        "-target",
        "arm64-apple-macos15.0",
        "-framework",
        "Security",
        "-framework",
        "LocalAuthentication",
        "-framework",
        "CryptoKit",
        Path.join(project, "native/macos/Sources/NativeSetupWire.swift"),
        Path.join(project, "native/macos/Sources/NativeTargetWire.swift"),
        Path.join(project, "native/macos/Sources/SignedSetupPeer.swift"),
        Path.join(project, "native/macos/Sources/NativeKeychainCustodian.swift"),
        Path.join(project, "native/macos/Tests/NativeKeychainPolicySmoke.swift"),
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, _} <- Command.run_diagnostic(executable, [], 16_384, 10_000),
           do: :ok
    after
      File.rm_rf!(directory)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Keychain.Policy.Smoke do
  @moduledoc """
  Checks native Keychain policy, MQTT credential grammar and unsigned refusal.

  Run from the repository root with an Apple Silicon macOS Swift 6 toolchain:

      mix woh.native.keychain.policy.smoke

  The task compiles the owning Swift sources for macOS 15 and runs bounded
  fixtures for role-scoped and source-digest-scoped accounts, exact access-group
  policy, non-synchronizing data-protection queries, noninteractive contexts and
  sanitized error classification. Inert identity dictionaries check policy;
  they cannot mint an actual signing or custody seal.

  MQTT cases independently exercise the Swift credential grammar, canonical
  document/bootstrap vectors, duplicate/noncanonical input refusals and secret
  description/reflection redaction. The actual unsigned custodian entry points
  are also invoked: both existing-item lookup and import must fail at their
  actual-self signing gate before any SecItem operation.

  Success reports the completed policy fixture; reported compiler or assertion
  failures raise `Mix.Error`. Positive installed signing and Keychain account
  custody are not executed here and remain separate acceptance work, along with
  physical device qualification.
  """

  @shortdoc "Check inert native Keychain policy"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeKeychainPolicySmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native Keychain inert query and error policy passed")
      {:error, reason} -> Mix.raise("native Keychain policy smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.keychain.policy.smoke")
end
