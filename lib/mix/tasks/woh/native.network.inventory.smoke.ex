defmodule Woh.Tool.NativeNetworkInventorySmoke do
  @moduledoc false
  alias Woh.Tool.Command

  def run(project) do
    directory =
      Path.join(
        "/private/tmp",
        "woh-network-inventory-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    executable = Path.join(directory, "inventory-smoke")

    try do
      sources =
        ~w(NativeSetupWire NativeCoreConnection NativeNetworkPreferences NativeNetworkInventory)

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
            Path.join(project, "native/macos/Tests/NativeNetworkInventorySmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run("swiftc", args, 1_048_576, 60_000),
           {:ok, expected} <- expected_names(),
           {:ok, output} <-
             Command.run(executable, [], 16_384, 15_000, [], JSON.encode!(expected) <> "\n"),
           true <-
             String.contains?(
               output,
               "native network independent scope and actual passive inventory checks passed"
             ) do
        :ok
      else
        false -> {:error, "native inventory correspondence differs"}
        other -> other
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp expected_names do
    with {:ok, interfaces} <- :inet.getifaddrs() do
      names =
        Enum.flat_map(interfaces, fn {name, properties} ->
          text = to_string(name)

          if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9]{0,14}\z/, text) and
               match?({:ok, _}, WotexHome.Lifx.InterfaceSelection.from_properties(properties)),
             do: [text],
             else: []
        end)

      {:ok, Enum.sort(names)}
    end
  end
end

defmodule Mix.Tasks.Woh.Native.Network.Inventory.Smoke do
  @moduledoc "Checks independent selected-scope vectors and bounded actual OS interface enumeration without sockets or network packets."
  @shortdoc "Check passive native interface inventory"
  @requirements ["loadpaths"]
  use Mix.Task

  def run([]) do
    case Woh.Tool.NativeNetworkInventorySmoke.run(File.cwd!()) do
      :ok -> Mix.shell().info("native network scope and passive OS inventory checks passed")
      {:error, reason} -> Mix.raise("native network inventory smoke failed: #{reason}")
      _ -> Mix.raise("native network inventory fixture did not complete")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.network.inventory.smoke")
end
