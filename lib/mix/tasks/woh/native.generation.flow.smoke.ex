defmodule Mix.Tasks.Woh.Native.Generation.Flow.Smoke do
  @moduledoc """
  Checks guarded native generation first decisions against an actual Store.

  Run `mix woh.native.generation.flow.smoke` on the supported macOS toolchain.
  The task compiles the actual shared driver/panel closure and runs both
  quantity families through private workspace/pending publication, dropped
  mutation replies, explicit repair feedback, fresh manual assessment and
  root cancellation. A scripted provider supplies inert fixture drafts.

  The fixture uses temporary private directories and synthetic custody, with
  no external model, Keychain or device dispatch. Compilation and software
  behavior do not establish installed signing, accessibility or qualification.
  """

  use Mix.Task
  alias Woh.Tool.Command
  @requirements ["loadpaths"]
  @shortdoc "Check native generation first decisions and publication against Store"
  def run([]) do
    root =
      Path.join(
        "/private/tmp",
        "gen-flow-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "flow")

    sources =
      Path.wildcard(Path.expand("native/macos/Sources/*.swift"))
      |> Enum.reject(&(Path.basename(&1) == "WotexHomeApp.swift"))

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
        Enum.flat_map(
          ~w(SwiftUI AppKit Security LocalAuthentication CryptoKit ServiceManagement),
          &["-framework", &1]
        ) ++
        sources ++
        [Path.expand("native/macos/Tests/NativeGenerationFlowSmoke.swift"), "-o", executable]

    try do
      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 180_000),
           :ok <- Woh.Tool.NativeGenerationStoreSmoke.run(executable, root, true),
           do:
             Mix.shell().info(
               "native generation both-family first decisions, lost replies, explicit repair, fresh manual assessment and cancellation passed"
             ),
           else: ({:error, reason} -> Mix.raise("native generation flow smoke failed: #{reason}"))
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.generation.flow.smoke")
end
