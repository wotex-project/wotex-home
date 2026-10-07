defmodule Woh.Tool.NativeNetworkPreferenceSmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-network-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "preference-smoke")

    try do
      sources = ~w(NativeSetupWire NativeCoreConnection NativeNetworkPreferences)

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(directory, "cache"),
          "-target",
          "arm64-apple-macos15.0"
        ] ++
          Enum.map(sources, &Path.join(project, "native/macos/Sources/#{&1}.swift")) ++
          [
            Path.join(project, "native/macos/Tests/NativeNetworkPreferencesSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run(executable, [directory], 16_384, 15_000),
           true <-
             String.contains?(output, "native network canonical/private preference checks passed"),
           do: :ok
    after
      File.rm_rf!(directory)
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Network.Preference.Smoke do
  @moduledoc "Checks literal canonical native network records, private custody, exact compare-and-swap and nonblocking refusals without network packets or account changes."
  @shortdoc "Check private native network preferences"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeNetworkPreferenceSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native network canonical/private preference checks passed; no network packets"
        )

      {:error, reason} ->
        Mix.raise("native network preference smoke failed: #{reason}")

      _ ->
        Mix.raise("native network preference fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.network.preference.smoke")
end
