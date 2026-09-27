defmodule Woh.Tool.NervesSerial do
  @moduledoc false

  @max_rootfs_bytes 536_870_912
  @max_listing_bytes 8_388_608
  @drivers %{
    "cdc_acm" => "cdc-acm.ko",
    "ch341" => "ch341.ko",
    "cp210x" => "cp210x.ko",
    "ftdi_sio" => "ftdi_sio.ko",
    "pl2303" => "pl2303.ko"
  }

  def drivers, do: Map.keys(@drivers)

  def check(rootfs, required) when is_list(required) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(rootfs),
         true <- size > 0 and size <= @max_rootfs_bytes,
         [] <- Enum.uniq(required) -- Map.keys(@drivers),
         {:ok, listing} <-
           Woh.Tool.Command.run(
             "unsquashfs",
             ["-ll", rootfs, "lib/modules"],
             @max_listing_bytes,
             30_000
           ) do
      present =
        listing
        |> String.split("\n")
        |> Enum.reduce(MapSet.new(), fn line, names ->
          case Regex.run(~r/\bsquashfs-root\/lib\/modules\/[^\s]+\/([^\/\s]+\.ko)$/, line) do
            [_, module] -> MapSet.put(names, module)
            _ -> names
          end
        end)

      available =
        Map.new(@drivers, fn {driver, module} -> {driver, MapSet.member?(present, module)} end)

      missing = Enum.reject(required, &Map.fetch!(available, &1))

      if missing == [] do
        {:ok,
         %{
           "system_rootfs_sha256" => sha256(rootfs),
           "serial_modules" => available,
           "required_serial_drivers" => required,
           "scope" => "system_artifact_module_inventory_only"
         }}
      else
        {:error, "selected USB serial modules missing: #{Enum.join(missing, ", ")}"}
      end
    else
      {:ok, _} ->
        {:error, "system rootfs is unavailable"}

      {:error, :enoent} ->
        {:error, "system rootfs is unavailable"}

      {:error, reason} when is_atom(reason) ->
        {:error, "system rootfs is unavailable: #{reason}"}

      {:error, reason} ->
        {:error, "cannot list system modules: #{reason}"}

      false ->
        {:error, "system rootfs is outside the development size bound"}

      unknown when is_list(unknown) ->
        {:error, "unsupported serial driver selection: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp sha256(path) do
    path
    |> File.stream!([], 1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end

defmodule Mix.Tasks.Woh.Nerves.Serial.Check do
  @moduledoc """
  Inventories USB serial modules in a built Nerves system rootfs.

  Run `mix woh.nerves.serial.check ROOTFS --require cp210x` with the driver
  selected for the coordinator's recorded USB identity. The JSON result names
  all known modules and hashes the image. This is artifact evidence; inspect
  enumeration and the bound driver on the actual board as well.
  """

  @shortdoc "Check Nerves USB serial module inventory"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {options, positionals, invalid} =
      OptionParser.parse(args, strict: [require: :keep], aliases: [r: :require])

    case {positionals, invalid} do
      {[rootfs], []} ->
        required = Keyword.get_values(options, :require)

        case Woh.Tool.NervesSerial.check(rootfs, required) do
          {:ok, report} -> Mix.shell().info(JSON.encode!(report))
          {:error, reason} -> Mix.raise("Nerves serial module check failed: #{reason}")
        end

      _ ->
        Mix.raise("usage: mix woh.nerves.serial.check ROOTFS [--require DRIVER]...")
    end
  end
end
