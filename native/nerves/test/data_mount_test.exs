defmodule WotexHome.Firmware.DataMountTest do
  use ExUnit.Case

  alias WotexHome.Firmware.DataMount

  test "requires the selected data symlink and a real F2FS application mount" do
    root = Path.join(System.tmp_dir!(), "home-mount-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "root"))
    File.ln_s!("root", Path.join(root, "data"))
    on_exit(fn -> File.rm_rf!(root) end)
    mountinfo = Path.join(root, "mountinfo")

    File.write!(
      mountinfo,
      "25 20 179:7 / #{Path.join(root, "root")} rw - f2fs /dev/mmcblk0p7 rw\n"
    )

    assert {:ok, %{filesystem: "f2fs", writable_mount: target}} =
             DataMount.capture(root, mountinfo)

    assert target == Path.join(root, "root")

    File.write!(mountinfo, "25 20 179:7 / #{target} ro - f2fs /dev/mmcblk0p7 rw\n")
    assert {:error, :data_mount_unavailable} = DataMount.capture(root, mountinfo)

    File.write!(mountinfo, "25 20 179:7 / #{target} rw - ext4 /dev/mmcblk0p7 rw\n")
    assert {:error, :data_mount_unavailable} = DataMount.capture(root, mountinfo)

    File.write!(mountinfo, "25 20 179:7 / / rw - f2fs /dev/mmcblk0p7 rw\n")
    assert {:error, :data_mount_unavailable} = DataMount.capture(root, mountinfo)

    File.rm!(Path.join(root, "data"))
    File.mkdir!(Path.join(root, "data"))
    File.write!(mountinfo, "25 20 179:7 / #{target} rw - f2fs /dev/mmcblk0p7 rw\n")
    assert {:error, :data_mount_unavailable} = DataMount.capture(root, mountinfo)
  end
end
