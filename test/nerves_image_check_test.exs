defmodule WotexHome.NervesImageCheckTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.NervesImage

  @project Path.expand("..", __DIR__)
  @metadata """
  meta-platform=rpi4
  task "upgrade.a" {
  reqlist={b.nerves_fw_validated,1}
  on-init {funlist={a.nerves_fw_validated,0}}
  on-finish {funlist={reboot_param,"0 tryboot"}}
  }
  task "upgrade.b" {
  reqlist={a.nerves_fw_validated,1}
  on-init {funlist={b.nerves_fw_validated,0}}
  on-finish {funlist={reboot_param,"0 tryboot"}}
  }
  a.nerves_fw_application_part0_target,"/root"
  b.nerves_fw_application_part0_target,"/root"
  """

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-nerves-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "requires both validated-source tryboot plans", %{directory: directory} do
    firmware = Path.join(directory, "fixture.fw")
    write_firmware(firmware)
    members = ~w(meta.conf data/autoboot-a.txt data/autoboot-b.txt)

    assert {"both_upgrade_slots_require_valid_source_and_tryboot", _} =
             NervesImage.firmware_update_layout!(firmware, members)

    write_firmware(firmware, autoboot: "[all]\n")

    assert_raise NervesImage.Error, ~r/lacks tryboot selection/, fn ->
      NervesImage.firmware_update_layout!(firmware, members)
    end

    write_firmware(firmware,
      metadata: String.replace(@metadata, "b.nerves_fw_validated,1", "b.nerves_fw_validated,0")
    )

    assert_raise NervesImage.Error, ~r/validated-source tryboot plan/, fn ->
      NervesImage.firmware_update_layout!(firmware, members)
    end
  end

  if System.find_executable("mksquashfs") && System.find_executable("unsquashfs") &&
       System.find_executable("unzip") do
    test "checks the packaged rootfs, ARM closure and offline host settings", %{
      directory: directory
    } do
      rootfs_tree = Path.join(directory, "tree")
      File.mkdir_p!(Path.join(rootfs_tree, "root"))
      File.ln_s!("root", Path.join(rootfs_tree, "data"))

      legal_files = %{
        "ex_maude-0.4.3/priv/maude/COPYING" =>
          "docs/provenance/license-inputs/maude-3.5.1-COPYING",
        "ex_maude-0.4.3/priv/maude/THIRD_PARTY_NOTICES.md" =>
          "vendor/ex_maude/THIRD_PARTY_NOTICES.md",
        "db_connection-2.10.2/priv/LICENSE" =>
          "docs/provenance/license-inputs/apache-2.0-LICENSE.txt",
        "rustler_precompiled-0.9.0/priv/LICENSE" =>
          "docs/provenance/license-inputs/apache-2.0-LICENSE.txt",
        "wotex_udp-0.1.0/priv/LICENSE" => "vendor/wotex_udp/LICENSE",
        "wotex_udp-0.1.0/priv/NOTICE" => "vendor/wotex_udp/NOTICE"
      }

      for {relative, source} <- legal_files do
        destination = Path.join([rootfs_tree, "srv/erlang/lib", relative])
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(Path.join(@project, source), destination)
      end

      image = Path.join(directory, "rootfs.img")
      make_rootfs(rootfs_tree, image)
      firmware = Path.join(directory, "fixture.fw")
      write_firmware(firmware, rootfs: File.read!(image))

      release = Path.join(directory, "release")
      beam = Path.join(release, "erts-1/bin/beam.smp")
      File.mkdir_p!(Path.dirname(beam))
      File.write!(beam, elf(183))
      args = Path.join(release, "releases/0.1.0/vm.args")
      File.mkdir_p!(Path.dirname(args))
      File.write!(args, "-noshell\n")
      config = Path.join(release, "releases/0.1.0/sys.config")

      File.write!(
        config,
        "[{'Elixir.VintageNetEthernet',eth0,method=>dhcp}," <>
          "{internet_host_list,[{{127,0,0,1},1}]}," <>
          "{persistence,'Elixir.VintageNet.Persistence.Null'}]."
      )

      File.mkdir_p!(Path.join(release, "lib/vintage_net-1"))
      File.mkdir_p!(Path.join(release, "lib/vintage_net_ethernet-1"))

      for {relative, source} <- legal_files do
        destination = Path.join([release, "lib", relative])
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(Path.join(@project, source), destination)
      end

      assert {:ok, %{"aarch64_elf_files" => 1, "scope" => "cross_build_packaging_only"}} =
               NervesImage.check(release, firmware)

      write_firmware(firmware,
        metadata:
          String.replace(
            @metadata,
            ~s(application_part0_target,"/root"),
            ~s(application_part0_target,"/data")
          ),
        rootfs: File.read!(image)
      )

      assert {:error, "firmware writable application mount is not /root"} =
               NervesImage.check(release, firmware)

      rootfs_license = Path.join(rootfs_tree, "srv/erlang/lib/ex_maude-0.4.3/priv/maude/COPYING")
      File.write!(rootfs_license, "changed")
      File.rm!(image)
      make_rootfs(rootfs_tree, image)
      write_firmware(firmware, rootfs: File.read!(image))

      assert {:error,
              "firmware legal input differs: srv/erlang/lib/ex_maude-0.4.3/priv/maude/COPYING"} =
               NervesImage.check(release, firmware)

      File.cp!(
        Path.join(@project, legal_files["ex_maude-0.4.3/priv/maude/COPYING"]),
        rootfs_license
      )

      File.rm!(Path.join(rootfs_tree, "data"))
      File.mkdir!(Path.join(rootfs_tree, "data"))
      File.rm!(image)
      make_rootfs(rootfs_tree, image)
      write_firmware(firmware, rootfs: File.read!(image))

      assert {:error, "firmware /data does not resolve to the writable /root mount"} =
               NervesImage.check(release, firmware)

      File.rmdir!(Path.join(rootfs_tree, "data"))
      File.ln_s!("root", Path.join(rootfs_tree, "data"))
      File.rm!(image)
      make_rootfs(rootfs_tree, image)
      write_firmware(firmware, rootfs: File.read!(image))

      File.write!(args, "-sname home\n")

      assert {:error, "firmware enables an Erlang network node"} =
               NervesImage.check(release, firmware)

      File.write!(args, "-noshell\n")

      File.write!(beam, elf(62))
      assert {:error, "ERTS is not AArch64"} = NervesImage.check(release, firmware)
      File.write!(beam, elf(183))

      license = Path.join(release, "lib/ex_maude-0.4.3/priv/maude/COPYING")
      File.write!(license, "changed")

      assert {:error, "Maude standard-library legal inputs are missing"} =
               NervesImage.check(release, firmware)

      File.cp!(Path.join(@project, legal_files["ex_maude-0.4.3/priv/maude/COPYING"]), license)

      File.write!(Path.join(release, "lib/ex_maude-0.4.3/priv/maude-darwin-arm64"), "foreign")

      assert {:error, "foreign Maude executable remains in ARM release"} =
               NervesImage.check(release, firmware)

      File.rm!(Path.join(release, "lib/ex_maude-0.4.3/priv/maude-darwin-arm64"))
      File.ln_s!(beam, Path.join(release, "linked-beam"))
      assert {:error, "release tree contains a symlink"} = NervesImage.check(release, firmware)
    end
  end

  defp write_firmware(path, options \\ []) do
    metadata = Keyword.get(options, :metadata, @metadata)
    autoboot = Keyword.get(options, :autoboot, "tryboot_a_b=1\n[tryboot]\n")

    files = [
      {~c"meta.conf", metadata},
      {~c"data/autoboot-a.txt", autoboot},
      {~c"data/autoboot-b.txt", autoboot}
    ]

    files =
      case Keyword.fetch(options, :rootfs) do
        {:ok, rootfs} -> files ++ [{~c"data/rootfs.img", rootfs}]
        :error -> files
      end

    {:ok, {_name, archive}} = :zip.create(~c"fixture.fw", files, [:memory])
    File.write!(path, archive)
  end

  defp make_rootfs(tree, destination) do
    {_output, 0} =
      System.cmd("mksquashfs", [tree, destination, "-noappend", "-quiet"], stderr_to_stdout: true)
  end

  defp elf(machine), do: <<0x7F, "ELF", 2, 1, 0::size(96), machine::little-16>>
end
