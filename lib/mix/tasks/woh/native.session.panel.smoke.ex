defmodule Woh.Tool.NativeSessionPanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-session-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "session-smoke")
    preview = Path.join(project, "_build/native/session-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    sources =
      ~w(LocalHealthClient NativeSetupWire SignedSetupPeer NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativeSetupSocket NativeBrokerClient NativeSetupPanel)

    try do
      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(directory, "cache"),
          "-target",
          "arm64-apple-macos15.0",
          "-framework",
          "Security",
          "-framework",
          "SwiftUI",
          "-framework",
          "AppKit",
          "-framework",
          "CryptoKit"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/NativeSessionPresentationSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run(executable, [preview], 16_384, 15_000),
           true <-
             String.contains?(
               output,
               "native session memory transitions and unsigned setup refusal passed"
             ),
           do: {:ok, preview}
    after
      File.rm_rf!(directory)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Session.Panel.Smoke do
  @moduledoc "Checks inert native session memory and actual unsigned refusal, then renders an unselected panel; opens no Keychain."
  @shortdoc "Check native session presentation"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeSessionPanelSmoke.run(File.cwd!()) do
      {:ok, preview} ->
        Mix.shell().info("native session memory/refusal passed; inert panel: #{preview}")

      {:error, reason} ->
        Mix.raise("native session panel smoke failed: #{reason}")

      _ ->
        Mix.raise("native session panel fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.session.panel.smoke")
end
