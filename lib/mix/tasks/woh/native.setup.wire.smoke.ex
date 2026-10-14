defmodule Woh.Tool.NativeSetupWireSmoke do
  @moduledoc false

  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-native-wire-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "wire-smoke")

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
        Path.join(project, "native/macos/Sources/NativeSetupWire.swift"),
        Path.join(project, "native/macos/Sources/NativeTargetWire.swift"),
        Path.join(project, "native/macos/Tests/NativeSetupWireSmoke.swift"),
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

defmodule Mix.Tasks.Woh.Native.Setup.Wire.Smoke do
  @moduledoc """
  Check closed native setup wire vectors.

  Run `mix woh.native.setup.wire.smoke` on the supported macOS toolchain. The
  task compiles and runs the owning bounded Swift fixtures, reporting
  compilation, exchange or assertion failures through Mix.

  Checks independent closed native core/broker records; performs no
  authentication or Keychain access.

  The result is executable software evidence for the tested boundary.
  Installed signing, private account custody and physical device qualification
  require their separate acceptance evidence.
  """

  @shortdoc "Check closed native setup wire vectors"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeSetupWireSmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native setup independent wire and rejection vectors passed")
      {:error, reason} -> Mix.raise("native setup wire smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.setup.wire.smoke")
end
