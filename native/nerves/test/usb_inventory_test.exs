defmodule WotexHome.Firmware.UsbInventoryTest do
  use ExUnit.Case

  alias WotexHome.Firmware.UsbInventory

  test "reads a bound serial interface without exposing the USB serial" do
    root = Path.join(System.tmp_dir!(), "home-usb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "1-2"))
    File.mkdir_p!(Path.join(root, "1-2:1.0"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "1-2/idVendor"), "10C4\n")
    File.write!(Path.join(root, "1-2/idProduct"), "ea60\n")
    File.write!(Path.join(root, "1-2/serial"), "private-identifier\n")
    File.ln_s!("../../drivers/cp210x", Path.join(root, "1-2:1.0/driver"))

    assert {:ok, %{devices: [device]}} = UsbInventory.capture(root)
    assert device.vendor_id == "10c4"
    assert device.product_id == "ea60"
    assert device.interfaces == [%{name: "1-2:1.0", driver: "cp210x"}]
    refute inspect(device) =~ "private-identifier"

    File.rm!(Path.join(root, "1-2:1.0/driver"))

    assert {:ok, %{devices: [%{interfaces: [%{driver: :unbound}]}]}} =
             UsbInventory.capture(root)
  end

  test "invalid USB identity fails closed" do
    root = Path.join(System.tmp_dir!(), "home-usb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "1-2"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "1-2/idVendor"), "spoof\n")
    File.write!(Path.join(root, "1-2/idProduct"), "ea60\n")
    assert {:error, :invalid_usb_identity} = UsbInventory.capture(root)
  end
end
