defmodule Mix.Tasks.Woh.Native.Authoring.Read.Panel.Smoke do
  @moduledoc """
  Checks native authoring-read invalidation and mounted presentation.

  Run `mix woh.native.authoring.read.panel.smoke` on the supported macOS toolchain. The task
  compiles and runs the owning Swift fixture under bounded deadlines and reports
  a refusal when compilation, peer exchange or fixture assertions fail.

  The fixture establishes bounded software behavior only. It neither qualifies
  physical devices nor installs or changes the operator's controller policy.
  """

  use Mix.Task
  alias Woh.Tool.Command
  @requirements ["loadpaths"]
  @shortdoc "Check native authoring read invalidation and mounted presentation"

  def run([]) do
    root =
      Path.join("/private/tmp", "authoring-read-panel-#{System.unique_integer([:positive])}")

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
            ~w(LocalHealthClient NativeAuthoringReadClient NativeAuthoringReadPanel),
            &Path.expand("native/macos/Sources/#{&1}.swift")
          ) ++
          [
            Path.expand("native/macos/Tests/NativeAuthoringReadPanelSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [Path.expand("test/fixtures/profiles/authoring-review.json"), preview],
               16_384,
               30_000
             ),
           true <-
             String.ends_with?(
               String.trim(output),
               "native authoring delayed delivery, missing/error, metadata and mounted layout passed"
             ),
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native authoring read panel failed: #{reason}")
             _ -> Mix.raise("native authoring read panel did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.read.panel.smoke")
end
