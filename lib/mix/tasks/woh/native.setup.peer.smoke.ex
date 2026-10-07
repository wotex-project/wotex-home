defmodule Woh.Tool.NativeSetupPeerSmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-native-peer-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "peer-smoke")

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
        Path.join(project, "native/macos/Sources/SignedSetupPeer.swift"),
        Path.join(project, "native/macos/Tests/SignedSetupPeerSmoke.swift"),
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, _} <- Command.run(executable, [], 16_384, 10_000) do
        :ok
      end
    after
      File.rm_rf!(directory)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Setup.Peer.Smoke do
  @moduledoc """
  Checks the closed native signing policy and real unsigned socket refusal.

  This compiles the Swift 6/macOS 15 fixture with warnings as errors. It does not
  sign a pair, access Keychain, register a service or establish installed proof.
  """
  @shortdoc "Check signed setup policy and unsigned refusal"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeSetupPeerSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native setup peer policy and unsigned refusal passed")
      {:error, reason} -> Mix.raise("native setup peer smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.setup.peer.smoke")
end
