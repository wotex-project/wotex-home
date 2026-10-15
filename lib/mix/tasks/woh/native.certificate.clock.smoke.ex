defmodule Mix.Tasks.Woh.Native.Certificate.Clock.Smoke do
  @moduledoc """
  Checks inert native certificate-clock documents and signed lease arithmetic.

  Run `mix woh.native.certificate.clock.smoke` on Apple Silicon macOS 15 or later
  with Swift 6. Independent OpenSSL signatures and integer interval/continuity
  vectors exercise the closed codec, scope joins and strict original deadlines.
  The task compiles with warnings rejected and removes its private compiler and
  executable directory on completion. It opens no Keychain, Store or network.

  This is pure software evidence. Production file ownership, source-aware TLS
  composition, installed issuer UTC accuracy and host qualification are separate.
  """

  @shortdoc "Check signed native clock documents and arithmetic"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root =
      Path.join("/private/tmp", "woh-certificate-clock-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    try do
      executable = Path.join(root, "clock-source")

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache")
        ] ++
          Enum.map(
            ~w(Sources/NativeControllerPairingWire.swift Sources/NativeCertificateClockSource.swift Tests/NativeCertificateClockSourceSmoke.swift),
            &Path.expand("native/macos/" <> &1)
          ) ++ ["-o", executable]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 Path.expand(
                   "test/fixtures/controller_connections/native_certificate_clock_v1.json"
                 )
               ],
               16_384,
               10_000
             ) do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native certificate clock smoke failed: #{reason}")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.certificate.clock.smoke")
end
