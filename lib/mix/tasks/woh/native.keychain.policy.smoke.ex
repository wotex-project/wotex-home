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
        Path.join(project, "native/macos/Sources/SignedSetupPeer.swift"),
        Path.join(project, "native/macos/Sources/NativeKeychainCustodian.swift"),
        Path.join(project, "native/macos/Tests/NativeKeychainPolicySmoke.swift"),
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, _} <- Command.run(executable, [], 16_384, 10_000),
           do: :ok
    after
      File.rm_rf!(directory)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Keychain.Policy.Smoke do
  @moduledoc "Checks inert private Keychain query/error policy; never calls SecItem or synthesizes a signing seal."
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
