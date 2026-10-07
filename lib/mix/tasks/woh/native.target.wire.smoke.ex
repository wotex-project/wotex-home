defmodule Mix.Tasks.Woh.Native.Target.Wire.Smoke do
  @moduledoc "Independent native target codec and original receipt vectors; no OS signing, Keychain or grant."
  @shortdoc "Check original native target wire vectors"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    project = File.cwd!()

    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-target-wire-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "target-wire")

    try do
      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(directory, "cache"),
        "-target",
        "arm64-apple-macos15.0",
        Path.join(project, "native/macos/Sources/NativeSetupWire.swift"),
        Path.join(project, "native/macos/Sources/NativeTargetWire.swift"),
        Path.join(project, "native/macos/Tests/NativeTargetWireSmoke.swift"),
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, _} <- Command.run(executable, [], 16_384, 10_000) do
        Mix.shell().info("native target independent wire and original receipt vectors passed")
      else
        {:error, reason} -> Mix.raise("native target wire smoke failed: #{reason}")
      end
    after
      File.rm_rf!(directory)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.target.wire.smoke")
end
