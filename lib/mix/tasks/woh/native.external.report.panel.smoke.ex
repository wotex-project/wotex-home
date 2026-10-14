defmodule Mix.Tasks.Woh.Native.External.Report.Panel.Smoke do
  use Mix.Task
  alias Woh.Tool.Command
  @requirements ["loadpaths"]
  @shortdoc "Check native external report expiry, invalidation and mounted presentation"

  def run([]) do
    root =
      Path.join("/private/tmp", "external-report-panel-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    preview = Path.expand("_build/native")
    File.mkdir_p!(preview)
    executable = Path.join(root, "panel")

    try do
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
          Enum.flat_map(~w(SwiftUI AppKit Security), &["-framework", &1]) ++
          Enum.map(
            ~w(LocalHealthClient NativeExternalReportClient NativeExternalReportPanel),
            &Path.expand("native/macos/Sources/#{&1}.swift")
          ) ++
          [
            Path.expand("native/macos/Tests/NativeExternalReportPanelSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [Path.expand("test/fixtures/profiles/external-observations.json"), preview],
               16_384,
               30_000
             ),
           true <-
             String.ends_with?(
               String.trim(output),
               "native external report expiry, latency, invalidation and mounted layout passed"
             ),
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native external report panel failed: #{reason}")
             _ -> Mix.raise("native external report panel did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.report.panel.smoke")
end
