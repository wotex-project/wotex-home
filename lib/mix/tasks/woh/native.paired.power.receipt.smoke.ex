defmodule Mix.Tasks.Woh.Native.Paired.Power.Receipt.Smoke do
  @moduledoc """
  Checks recorded-controller power receipt routing and native Activity delivery.

  Run `mix woh.native.paired.power.receipt.smoke` without arguments on Apple
  Silicon macOS 15 or later with the Swift 6 toolchain. The task compiles the
  production native model/driver and shared receipt panel with warnings rejected;
  compiler, fixture and assertion failures fail the Mix task.

  Checks cover original association/receipt correspondence when another
  controller is selected, read-only scope, actual unsigned production-factory
  refusal, missing-clock refusal and explicit use of the last resolved original.
  The model probes found/not-found/failure/expired reads, duplicate-click refusal
  and late delivery after input, session or retained-reference changes. Matched
  paired reads must not fall back to local custody or mutate pending operations.

  The shared panel is rendered at 480 and 840 points wide. Inspect the retained
  `_build/native/paired-power-receipt-480.png` and
  `_build/native/paired-power-receipt-840.png`; temporary compiler and fixture
  directories are removed on completion.

  For actual TLS/Store receipt evidence, use
  `mix woh.native.paired.recovery.smoke --power-receipts`, documented by
  `Mix.Tasks.Woh.Native.Paired.Recovery.Smoke`. These metadata/model checks cannot
  create a successful signed session. Positive installed signing, Keychain,
  trusted certificate-clock and physical qualification remain separate gates.
  """

  @shortdoc "Check last paired power receipt routing"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  @impl Mix.Task
  def run([]) do
    root = Path.join("/private/tmp", "woh-paired-receipt-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    preview = Path.expand("_build/native")
    File.mkdir_p!(preview)

    try do
      sources =
        Path.wildcard(Path.expand("native/macos/Sources/*.swift"))
        |> Enum.reject(&(Path.basename(&1) == "WotexHomeApp.swift"))

      executable = Path.join(root, "fixture")

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
            Path.expand("native/macos/Tests/NativePairedPowerReceiptSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 180_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 root,
                 Path.expand("test/fixtures/controller_connections/native_associations_v1.json"),
                 Path.expand("test/fixtures/controller_connections/native_pending_v5.json"),
                 preview
               ],
               16_384,
               15_000
             ),
           do: Mix.shell().info(String.trim(output)),
           else: ({:error, reason} -> Mix.raise("paired power receipt smoke failed: #{reason}"))
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.paired.power.receipt.smoke")
end
