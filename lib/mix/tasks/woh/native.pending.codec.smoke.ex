defmodule Mix.Tasks.Woh.Native.Pending.Codec.Smoke do
  @moduledoc "Checks closed native pending-operation records without API, Keychain or file publication."
  @shortdoc "Check native pending operation codec"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  @impl Mix.Task
  def run([]) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-pending-codec-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "pending-codec-smoke")
    project = File.cwd!()

    try do
      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(directory, "cache"),
          "-target",
          "arm64-apple-macos15.0"
        ] ++
          Enum.map(
            ~w(LocalHealthClient NativeSetupWire NativePendingCodec),
            &Path.join(project, "native/macos/Sources/#{&1}.swift")
          ) ++
          [
            Path.join(project, "native/macos/Tests/NativePendingCodecSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run(executable, [], 16_384, 10_000),
           true <-
             String.contains?(
               output,
               "native pending codec independent closed vectors and bounds passed"
             ) do
        Mix.shell().info("native pending codec independent closed vectors and bounds passed")
      else
        {:error, reason} -> Mix.raise("native pending codec smoke failed: #{reason}")
        _ -> Mix.raise("native pending codec fixture did not complete")
      end
    after
      File.rm_rf!(directory)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.pending.codec.smoke")
end
