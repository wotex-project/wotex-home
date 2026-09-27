defmodule WotexHome.Firmware.UsbInventory do
  @moduledoc """
  Read-only USB VID/PID and interface-driver inventory for a board lab.

  It omits device serials. A bound USB driver does not establish that an NCP
  speaks its expected protocol or that a tty path is stable across reconnects.

  `capture/1` reads the bounded sysfs USB view and reports vendor/product IDs
  with interface driver names. Run it before selecting a coordinator path,
  then verify the same device after cold boot and reconnect on the board.
  """

  @device ~r/^\d+-\d+(?:\.\d+)*$/
  @max_entries 256

  @spec capture(Path.t()) :: {:ok, map()} | {:error, atom()}
  def capture(root \\ "/sys/bus/usb/devices") do
    with {:ok, entries} <- File.ls(root),
         true <- length(entries) <= @max_entries,
         {:ok, devices} <- devices(root, entries) do
      {:ok, %{scope: :read_only_sysfs_usb_inventory, devices: devices}}
    else
      false -> {:error, :usb_inventory_capacity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp devices(root, entries) do
    entries
    |> Enum.filter(&Regex.match?(@device, &1))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      path = Path.join(root, name)

      with {:ok, vendor} <- hex_id(Path.join(path, "idVendor")),
           {:ok, product} <- hex_id(Path.join(path, "idProduct")),
           {:ok, interfaces} <- interfaces(root, name, entries) do
        device = %{port: name, vendor_id: vendor, product_id: product, interfaces: interfaces}
        {:cont, {:ok, [device | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, devices} -> {:ok, Enum.reverse(devices)}
      error -> error
    end
  end

  defp interfaces(root, name, entries) do
    pattern = Regex.compile!("^#{Regex.escape(name)}:\\d+\\.\\d+$")

    entries
    |> Enum.filter(&Regex.match?(pattern, &1))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn interface, {:ok, acc} ->
      driver_path = Path.join([root, interface, "driver"])

      case File.read_link(driver_path) do
        {:ok, target} ->
          driver = Path.basename(target)

          if Regex.match?(~r/^[A-Za-z0-9_-]{1,64}$/, driver) do
            {:cont, {:ok, [%{name: interface, driver: driver} | acc]}}
          else
            {:halt, {:error, :invalid_usb_driver}}
          end

        {:error, :enoent} ->
          {:cont, {:ok, [%{name: interface, driver: :unbound} | acc]}}

        {:error, _} ->
          {:halt, {:error, :usb_inventory_unavailable}}
      end
    end)
    |> case do
      {:ok, interfaces} -> {:ok, Enum.reverse(interfaces)}
      error -> error
    end
  end

  defp hex_id(path) do
    case File.read(path) do
      {:ok, <<hex::binary-size(4), rest::binary>>} when rest in ["", "\n"] ->
        if Regex.match?(~r/^[0-9a-fA-F]{4}$/, hex),
          do: {:ok, String.downcase(hex)},
          else: {:error, :invalid_usb_identity}

      _ ->
        {:error, :invalid_usb_identity}
    end
  end
end
