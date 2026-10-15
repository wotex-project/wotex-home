defmodule Mix.Tasks.Woh.Native.Certificate.Clock.Panel.Smoke do
  @moduledoc """
  Checks shared Setup clock controls, late completions and panel rendering.

  Run `mix woh.native.certificate.clock.panel.smoke` without arguments on Apple
  Silicon macOS 15 or later with Swift 6. The task compiles production Swift
  sources except the app entry point, with warnings rejected, then runs the panel
  fixture. Compilation, execution, assertion or preview-copy failures fail the task.

  Controlled presentation actions/status exercise passive construction, Begin and
  Import work guards, duplicate suppression and explicit Withdraw. Import must
  retain its original absolute path and request digest. Input/selection changes
  or withdrawal during a held action invalidate its generation and discard late
  completion. Polling must also refuse stale positive metadata after action
  invalidation. An idle accepted source is preserved across selection changes.
  Supplied retiring status keeps Begin disabled until that status clears, and
  polling observes supplied expiry/withdrawal changes. These presentation values
  cannot provide the production driver's clock, even when status is qualified.

  Shared application checks exercise production binding and actual unsigned
  Begin refusal. Clock setup requires a loaded safe journal and no shared busy
  work: an unloaded/unsafe journal or held Health read blocks Begin. The fixture also
  retains a public paired-power original in an actual private journal, then
  admits Begin through to the unsigned gate without changing that exact snapshot.
  Retained originals permit clock renewal; ordinary session changes remain
  blocked. This is setup admission/refusal evidence, not successful renewal or
  an installed source. Separate file/generation and actual worker checks belong
  to `Mix.Tasks.Woh.Native.Certificate.Clock.Owner.Smoke`.

  The fixture renders the shared clock panel at 380 and 780 points wide, with
  bounded fitting height. On success, inspect
  `_build/native/certificate-clock/narrow.png` and
  `_build/native/certificate-clock/wide.png`; remove that preview directory after
  visual review. The private compiler/cache/executable root and original previews
  are removed on success or failure.

  The fixture reads no Keychain credential or Home Store and sends no issuer or
  device request. Positive installed signing/source custody, qualified UTC and
  elapsed-clock accuracy, successful paired TLS and minimum-host qualification
  require their own evidence.
  """

  @shortdoc "Check shared native clock actions and panel"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root = Path.join("/private/tmp", "woh-clock-panel-#{System.unique_integer([:positive])}")
    executable = Path.join(root, "panel")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    try do
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
            Path.expand("native/macos/Tests/NativeCertificateClockPanelSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 180_000),
           {:ok, output} <- Command.run_diagnostic(executable, [root], 16_384, 20_000) do
        preview = Path.expand("_build/native/certificate-clock")
        File.mkdir_p!(preview)

        for name <- ~w(narrow.png wide.png),
            do: File.cp!(Path.join(root, name), Path.join(preview, name))

        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native clock panel smoke failed: #{reason}")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.certificate.clock.panel.smoke")
end
