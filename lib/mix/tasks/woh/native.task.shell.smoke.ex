defmodule Mix.Tasks.Woh.Native.Task.Shell.Smoke do
  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check native task layout edges and retained native text focus"
  alias Woh.Tool.Command
  @impl Mix.Task
  def run([]) do
    root =
      Path.join("/private/tmp", "ts-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    preview = Path.expand("_build/native")
    File.mkdir_p!(preview)

    try do
      executable = Path.join(root, "task-shell")

      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(root, "cache"),
        "-target",
        "arm64-apple-macos15.0",
        "-framework",
        "SwiftUI",
        "-framework",
        "AppKit",
        "native/macos/Sources/HomeTaskShell.swift",
        "native/macos/Tests/HomeTaskShellSmoke.swift",
        "-o",
        executable
      ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 90_000),
           {:ok, output} <- Command.run(executable, [preview], 16_384, 30_000),
           {:ok, %{"complete" => true}} <- JSON.decode(String.trim(output)),
           do:
             Mix.shell().info("native task shell edge layouts and native focus continuity passed"),
           else: (
             {:ok, %{"complete" => false, "line" => line}} ->
               Mix.raise("native task shell assertion #{line}")

             {:error, reason} when is_binary(reason) ->
               Mix.raise("native task shell failed: #{reason}")

             _ ->
               Mix.raise("native task shell did not complete")
           )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.task.shell.smoke")
end
