defmodule Mix.Tasks.Woh.Native.Rule.Operation.Wire.Smoke do
  @moduledoc "Independent closed explicit-rule inputs and source vectors without authority or custody."
  @shortdoc "Check native explicit rule operation codec"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-rule-wire-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "rule-wire")

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
        "native/macos/Tests/NativeRuleOperationWireSmoke.swift",
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run(executable, [], 16_384, 10_000),
           true <-
             String.contains?(
               output,
               "native explicit rule independent records, digest and source vectors passed"
             ) do
        Mix.shell().info(
          "native explicit rule independent records, digest and source vectors passed"
        )
      else
        {:error, reason} -> Mix.raise("native explicit rule wire smoke failed: #{reason}")
        _ -> Mix.raise("native explicit rule wire fixture did not complete")
      end
    after
      File.rm_rf!(directory)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.rule.operation.wire.smoke")
end
