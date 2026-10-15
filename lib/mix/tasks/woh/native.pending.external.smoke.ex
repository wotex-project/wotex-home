defmodule Mix.Tasks.Woh.Native.Pending.External.Smoke do
  @moduledoc """
  Checks complete external-profile originals in the private native journal.

  Run from the repository root with an Apple Silicon macOS Swift 6 toolchain:

      mix woh.native.pending.external.smoke

  The task compiles production Swift for macOS 15 against frozen independent v9
  journal roots. Checks exercise private publication, old-version upgrades,
  CAS conflicts, process restart and concurrent writers. Instrumented capture
  and recovery entry points check existing-only custody failures and missing
  paired associations without obtaining credentials or starting transport.
  Failed recovery preserves the exact journal snapshot.

  Paired external originals support lookup, exact retry and explicit absence
  acknowledgement; cancellation and unknown-outcome acknowledgement remain
  invalid. This task checks journal correspondence and refusal paths. The
  complementary `Mix.Tasks.Woh.Native.Paired.External.Smoke` task exercises actual
  paired TLS consumption and the unsigned production session-factory boundary.

  Fixtures use disposable account directories and public synthetic metadata.
  Passing checks establish software custody, not installed signing, physical
  qualification or target-storage power-loss survival.
  """

  use Mix.Task
  alias Woh.Tool.{Command, NativeFixture, NativePairedRecoverySources}
  @requirements ["loadpaths"]
  @shortdoc "Check external-profile pending originals and private custody"

  def run([]) do
    root = Path.join("/private/tmp", "woh-pending-external-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "pending-external")

    sources =
      Enum.uniq(["NativePendingCoordinator" | NativePairedRecoverySources.names()]) --
        ["LocalHealthClient"]

    try do
      with :ok <-
             NativeFixture.compile(
               File.cwd!(),
               "NativePendingExternalSmoke.swift",
               executable,
               sources
             ),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 Path.expand("test/fixtures/profiles/native-pending-external-profiles.json"),
                 root
               ],
               16_384,
               30_000
             ),
           true <-
             String.contains?(
               output,
               "external pending 182 valid/276 invalid vectors, private CAS, restart, races and custody guards passed"
             ) do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("external pending smoke failed: #{reason}")
        _ -> Mix.raise("external pending fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.pending.external.smoke")
end
