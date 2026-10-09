defmodule Mix.Tasks.Woh.Native.Controller.Pairing.Wire.Smoke do
  @moduledoc "Checks independent native pairing syntax and exact correspondence without TLS or provisioning."
  @shortdoc "Check native controller invitation/bootstrap records"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root = Path.join("/private/tmp", "woh-pairing-wire-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "pairing-wire-smoke")

    try do
      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(root, "cache"),
        "-target",
        "arm64-apple-macos15.0",
        Path.expand("native/macos/Sources/NativeControllerPairingWire.swift"),
        Path.expand("native/macos/Tests/NativeControllerPairingWireSmoke.swift"),
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [Path.expand("test/fixtures/controller_connections/wire_vectors.json")],
               16_384,
               10_000
             ),
           true <-
             String.contains?(
               output,
               "native controller pairing 28 records, 158 refusals, 18 exact correspondence cases and bounded frames passed"
             ) do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native controller pairing wire smoke failed: #{reason}")
        _ -> Mix.raise("native controller pairing wire fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.pairing.wire.smoke")
end
