defmodule WotexHome.NervesSerialCheckTest do
  use ExUnit.Case

  alias Woh.Tool.NervesSerial

  test "inventory comes from the built rootfs and rejects an absent selected driver" do
    if System.find_executable("mksquashfs") && System.find_executable("unsquashfs") do
      directory =
        Path.join(System.tmp_dir!(), "wotex-serial-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(directory) end)
      modules = Path.join(directory, "tree/lib/modules/1/kernel/drivers/usb/serial")
      File.mkdir_p!(modules)
      File.write!(Path.join(modules, "cp210x.ko"), "module fixture")
      rootfs = Path.join(directory, "system.squashfs")

      {_, 0} =
        System.cmd("mksquashfs", [Path.join(directory, "tree"), rootfs, "-noappend", "-quiet"])

      assert {:ok, report} = NervesSerial.check(rootfs, ["cp210x"])
      assert report["serial_modules"]["cp210x"]
      refute report["serial_modules"]["cdc_acm"]
      assert {:error, reason} = NervesSerial.check(rootfs, ["cdc_acm"])
      assert String.contains?(reason, "selected USB serial modules missing")
      assert {:error, _} = NervesSerial.check(rootfs, ["invalid"])
    end
  end
end
