defmodule Mix.Tasks.Woh.Native.Certificate.Clock.Owner.Smoke do
  @moduledoc """
  Checks native clock file custody, volatile generations and retiring workers.

  Run `mix woh.native.certificate.clock.owner.smoke` without arguments as a
  non-root user on Apple Silicon macOS 15 or later with Swift 6. The task compiles
  production native sources and the owner fixture with warnings rejected, then
  runs the fixture. Compilation, execution or assertion failures fail the task.

  Real private files and synthetic signed answers exercise the separate unsealed
  file/generation seam in temporary custody. Checks cover immutable request and
  response publication, identical acceptance without renewing the original start,
  changed-answer conflicts, stale request digests, invalid-answer consumption and
  fresh challenges. Identical-byte policy/request/response, root and ancestor
  replacement, unsafe modes, hard links and symlinks must withdraw the generation;
  restoring the original file or mode cannot restore it. Unsafe initial policy,
  runtime mismatch and retained-directory capacity also refuse. Additional checks
  refuse a mutation ACL installed through chmod, a FIFO response without a writer
  and a contending root flock. A failed check after response publication may
  leave bytes present but must yield no sample.

  Generation checks exercise cumulative wall corrections, rollback, response/age
  expiry, explicit withdrawal and refusal by previously returned fixture clocks.
  A delayed source callback must account for time elapsed after observation.
  These unsealed generations cannot be installed in the production owner.

  Held real worker jobs check that timeout/cancellation returns while capacity
  remains occupied, including refusal by another owner's Begin. Capacity becomes
  available only after the original worker retires, and its late value is never
  delivered. Foreign retirement/invalidation tokens must neither free nor
  invalidate the active slot. A job cancelled before scheduling must not enter
  its worker.

  The parameterless production owner starts unavailable and its actual unsigned
  Begin gate refuses before private account custody. This is refusal evidence,
  not a successful production source or signing seal. The fixture reads no
  Keychain credential, opens no Home Store and contacts no device or issuer.
  Its private compiler, executable, cache and file roots are removed on success
  or failure.

  `Mix.Tasks.Woh.Native.Certificate.Clock.Smoke` covers the independent signature
  and interval vectors. Positive installed ownership/signing, qualified UTC and
  elapsed-clock accuracy, owner timer/wake behavior, full source-aware TLS
  composition and shared UI delivery require their separate evidence.
  """

  @shortdoc "Check native clock custody and operation ownership"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root =
      Path.join(
        "/private/tmp",
        "woh-certificate-clock-owner-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    try do
      executable = Path.join(root, "clock-owner")
      files = Path.join(root, "files")
      File.mkdir!(files)
      File.chmod!(files, 0o700)

      sources =
        Path.wildcard(Path.expand("native/macos/Sources/*.swift"))
        |> Enum.reject(&(Path.basename(&1) == "WotexHomeApp.swift"))

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
          Enum.flat_map(
            ~w(SwiftUI AppKit Security LocalAuthentication CryptoKit ServiceManagement),
            &["-framework", &1]
          ) ++
          sources ++
          [
            Path.expand("native/macos/Tests/NativeCertificateClockOwnerSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 180_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 files,
                 Path.expand(
                   "test/fixtures/controller_connections/native_certificate_clock_v1.json"
                 )
               ],
               16_384,
               15_000
             ) do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native clock owner smoke failed: #{reason}")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.certificate.clock.owner.smoke")
end
