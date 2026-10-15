defmodule Mix.Tasks.Woh.Native.Paired.Workspace.Smoke do
  @moduledoc """
  Checks existing paired generation workspace purposes without a signing bypass.

  Run `mix woh.native.paired.workspace.smoke` on the supported macOS toolchain.
  Independent frozen transitions exercise exact intent, archival and pending
  publication, full private-file witnesses and actual unsigned factory refusal.
  Frozen selector joins separately check duplicate collapse, digest ordering,
  conflicting first revisions and the 32-handle boundary before owned-object reads.
  These software checks do not establish installed signed custody or dispatch.
  """

  use Mix.Task
  alias Woh.Tool.Command
  @requirements ["loadpaths"]
  @shortdoc "Check paired workspace transitions and unsigned purpose refusal"

  def run([]) do
    root = Path.join("/private/tmp", "paired-workspace-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "workspace")
    sources = Woh.Tool.NativePairedRecoverySources.names()

    args =
      [
        "-parse-as-library",
        "-whole-module-optimization",
        "-Onone",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache")
      ] ++
        Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
        [Path.expand("native/macos/Tests/NativePairedWorkspaceSmoke.swift"), "-o", executable]

    try do
      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <- Command.run_diagnostic(executable, [root], 16_384, 30_000),
           true <-
             String.trim(output) ==
               "paired workspace independent transitions, file witnesses and unsigned purpose refusal passed" do
        Mix.shell().info(
          "paired workspace independent transitions, file witnesses and unsigned purpose refusal passed"
        )
      else
        {:error, reason} -> Mix.raise("paired workspace fixture failed: #{reason}")
        _ -> Mix.raise("paired workspace fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.paired.workspace.smoke")
end
