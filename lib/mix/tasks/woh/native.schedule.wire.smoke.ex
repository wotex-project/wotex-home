defmodule Mix.Tasks.Woh.Native.Schedule.Wire.Smoke do
  @moduledoc "Independent bounded native schedule source and original-operation correspondence."
  @shortdoc "Check native schedule input codec"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-schedule-wire-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "schedule-wire")

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
        "native/macos/Sources/NativeRuleOperationWire.swift",
        "native/macos/Sources/NativeScheduleWire.swift",
        "native/macos/Tests/NativeScheduleWireSmoke.swift",
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <-
             Command.run(
               executable,
               ["test/fixtures/schedules/native_wire_vectors.json"],
               16_384,
               10_000
             ),
           true <-
             String.contains?(
               output,
               "native schedule independent 15 records and 61 refusals passed"
             ) do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native schedule wire smoke failed: #{reason}")
        _ -> Mix.raise("native schedule wire fixture did not complete")
      end
    after
      File.rm_rf!(directory)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.schedule.wire.smoke")
end
