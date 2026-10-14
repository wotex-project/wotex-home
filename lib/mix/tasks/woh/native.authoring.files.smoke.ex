defmodule Mix.Tasks.Woh.Native.Authoring.Files.Smoke do
  @moduledoc """
  Checks private native authoring-file custody with synthetic files.

  Run `mix woh.native.authoring.files.smoke` on the supported macOS toolchain. The task
  compiles and runs the owning Swift fixture under bounded deadlines and reports
  a refusal when compilation, private file checks or fixture assertions fail.

  The fixture establishes bounded software behavior only. It neither qualifies
  physical devices nor installs or changes the operator's controller policy.
  """

  use Mix.Task
  alias Woh.Tool.Command
  @requirements ["loadpaths"]
  @shortdoc "Check private authoring files without credentials or API requests"
  def run([]) do
    root =
      Path.join(
        "/private/tmp",
        "authoring-files-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "files")

    try do
      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-target",
        "arm64-apple-macos15.0",
        "-module-cache-path",
        Path.join(root, "cache"),
        Path.expand("native/macos/Sources/NativeAuthoringFiles.swift"),
        Path.expand("native/macos/Tests/NativeAuthoringFilesSmoke.swift"),
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run_diagnostic(executable, [root], 16_384, 10_000),
           true <-
             String.trim(output) ==
               "native authoring private file descriptor, links, modes, binary bytes and bounds passed",
           do: Mix.shell().info(String.trim(output)),
           else: (
             {:error, reason} -> Mix.raise("native authoring file smoke failed: #{reason}")
             _ -> Mix.raise("native authoring file fixture did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.authoring.files.smoke")
end
