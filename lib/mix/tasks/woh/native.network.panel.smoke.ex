defmodule Woh.Tool.NativeNetworkPanelSmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-network-panel-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "network-panel-smoke")
    preview = Path.join(project, "_build/native/network-panel-preview.png")
    File.mkdir_p!(Path.dirname(preview))

    try do
      sources =
        ~w(NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments NativeNetworkInventory NativeNetworkPanel)

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
          "SwiftUI",
          "-framework",
          "AppKit"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/NativeNetworkPanelSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run(executable, [directory, preview], 16_384, 15_000),
           true <-
             String.contains?(
               output,
               "native network explicit selection and conflict/churn guards passed"
             ),
           do: {:ok, preview}
    after
      File.rm_rf!(directory)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Network.Panel.Smoke do
  @moduledoc "Checks private native network choices, pending guards, stale-window conflict and interface disappearance; renders an unselected panel without network packets or real-account changes."
  @shortdoc "Check explicit native network presentation"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeNetworkPanelSmoke.run(File.cwd!()) do
      {:ok, preview} ->
        Mix.shell().info(
          "native network explicit selection/conflict guards passed; inert panel: #{preview}"
        )

      {:error, reason} ->
        Mix.raise("native network panel smoke failed: #{reason}")

      _ ->
        Mix.raise("native network panel fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.network.panel.smoke")
end
