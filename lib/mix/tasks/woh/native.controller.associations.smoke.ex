defmodule Mix.Tasks.Woh.Native.Controller.Associations.Smoke do
  @moduledoc "Checks independent public association/binding vectors and real private CAS/restart/concurrent publication; opens no TLS or Keychain."
  @shortdoc "Check public native controller association custody"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command

  def run([]) do
    root =
      Path.join(
        "/private/tmp",
        "woh-controller-associations-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "association-smoke")
    vectors = Path.expand("test/fixtures/controller_connections/native_associations_v1.json")

    try do
      sources =
        ~w(NativeControllerPairingWire NativeControllerAssociations NativeControllerAssociationStorage
        NativePrivateDocuments NativeSetupWire NativeTargetWire NativeCoreConnection NativeNetworkPreferences)

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-module-cache-path",
          Path.join(root, "cache"),
          "-target",
          "arm64-apple-macos15.0"
        ] ++
          Enum.map(sources, &Path.expand("native/macos/Sources/#{&1}.swift")) ++
          [
            Path.expand("native/macos/Tests/NativeControllerAssociationsSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 60_000),
           {:ok, output} <- Command.run_diagnostic(executable, [vectors, root], 16_384, 30_000),
           true <-
             String.trim(output) ==
               "native controller associations independent codec, private CAS, restart and concurrent publication passed" do
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native controller associations smoke failed: #{reason}")
        _ -> Mix.raise("native controller associations fixture did not complete")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.associations.smoke")
end
