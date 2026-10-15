defmodule Mix.Tasks.Woh.Native.Certificate.Clock.Smoke do
  @moduledoc """
  Checks signed native certificate-clock documents and conservative time arithmetic.

  Run `mix woh.native.certificate.clock.smoke` without arguments on Apple Silicon
  macOS 15 or later with Swift 6. The task compiles the owning Swift codec/lease
  and fixture with warnings rejected, then runs the fixture. Compilation,
  execution or assertion failures fail the Mix task.

  It consumes the committed public vectors in
  `test/fixtures/controller_connections/native_certificate_clock_v1.json`,
  generated independently with Python/OpenSSL. The invocation does not regenerate
  signatures or contact an issuer. Six signed vectors check Ed25519 verification,
  canonical document round trips and exact integer intervals, including delayed
  responses, ceiling-rounded drift, UTC underflow and upper-range refusal.

  Refusal checks mutate policy, request and signed-record fields, keys and
  signatures; reject malformed/expanded JSON, unsupported native values and
  noncanonical base64; and check strict original response/age deadlines and
  negative or reversed elapsed coordinates. Isolated continuity comparisons
  check drift/discontinuity tolerances and a cumulative-correction counterexample.
  They do not exercise a live source owner's rolling/original anchors, timer,
  wake notification or permanent withdrawal.

  The private temporary compiler, executable and cache directory is removed on
  success or failure. The fixture opens no Keychain, Home Store or network and
  installs no clock source. Passing these pure checks establishes neither a
  production signing/custody seal nor trusted current UTC. Actual private-file
  ownership, source-aware TLS/UI composition, issuer UTC/elapsed-clock accuracy
  and installed host qualification require their separate evidence.
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
