defmodule Woh.Tool.NervesImage do
  @moduledoc false

  alias Woh.Tool.{Command, Hash, ReleaseLegal}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @max_files 10_000
  @max_release_bytes 1_073_741_824
  @max_firmware_bytes 536_870_912
  @max_rootfs_bytes 134_217_728
  @max_metadata_bytes 131_072
  @max_autoboot_bytes 512
  @max_archive_listing_bytes 2_000_000
  @foreign_maude ~w(maude-darwin-arm64 maude-darwin-x64 maude-linux-x64 maude_bridge)
  @forbidden_apps ~w(nerves_pack nerves_ssh mdns_lite nerves_hub_link vintage_net_wifi nerves_time)
  @macho_magic [
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>
  ]

  def check(release, firmware) do
    release = Path.expand(release)
    firmware = Path.expand(firmware)
    require_directory!(release, "release tree is unavailable")
    firmware_bytes = require_file!(firmware, @max_firmware_bytes, "firmware file is unavailable")
    ensure!(Path.extname(firmware) == ".fw", "firmware file is unavailable")

    members = archive_members!(firmware)
    {layout, metadata} = firmware_update_layout!(firmware, members)
    data_path = firmware_data_path!(firmware, members, metadata)
    maude_priv = release_checks!(release)
    {files, elf_files} = scan_release!(release, maude_priv)

    {:ok,
     %{
       "firmware_sha256" => Hash.sha256(firmware),
       "firmware_bytes" => firmware_bytes,
       "release_files" => files,
       "aarch64_elf_files" => elf_files,
       "erlang_distribution" => "not_configured_in_vm_args",
       "wired_network" => "eth0_dhcp_loopback_probe",
       "firmware_update_layout" => layout,
       "home_data_path" => data_path,
       "remote_administration" => "not_packaged",
       "maude_backend" => "not_packaged",
       "scope" => "cross_build_packaging_only"
     }}
  rescue
    error in Error ->
      {:error, error.message}

    error in File.Error ->
      {:error, "cannot inspect release or firmware: #{Exception.message(error)}"}
  end

  def firmware_update_layout!(firmware, members) do
    for member <- ["meta.conf", "data/autoboot-a.txt", "data/autoboot-b.txt"] do
      ensure!(
        Enum.count(members, &(&1 == member)) == 1,
        "firmware update metadata or autoboot resource is missing"
      )
    end

    metadata = read_member!(firmware, "meta.conf", @max_metadata_bytes)
    ensure!(String.valid?(metadata), "firmware update metadata is not UTF-8")

    ensure!(
      "meta-platform=rpi4" in String.split(metadata, "\n"),
      "firmware metadata is not for Raspberry Pi 4"
    )

    for slot <- ~w(a b) do
      autoboot = read_member!(firmware, "data/autoboot-#{slot}.txt", @max_autoboot_bytes)
      ensure!(String.valid?(autoboot), "firmware autoboot #{slot} is not UTF-8")
      lines = String.split(autoboot, "\n")

      ensure!(
        "tryboot_a_b=1" in lines and "[tryboot]" in lines,
        "firmware autoboot #{slot} lacks tryboot selection"
      )
    end

    tasks =
      Regex.scan(~r/^task "([^"]+)" \{\s*(.*?)(?=^task "|\z)/ms, metadata)
      |> Map.new(fn [_, name, body] -> {name, body} end)

    for {target, previous} <- [{"a", "b"}, {"b", "a"}] do
      body = Map.get(tasks, "upgrade.#{target}", "")

      ensure!(
        Enum.all?(
          [
            "#{previous}.nerves_fw_validated,1",
            "#{target}.nerves_fw_validated,0",
            ~s(reboot_param,"0 tryboot")
          ],
          &String.contains?(body, &1)
        ),
        "firmware upgrade.#{target} lacks validated-source tryboot plan"
      )
    end

    {"both_upgrade_slots_require_valid_source_and_tryboot", metadata}
  end

  def firmware_data_path!(firmware, members, metadata) do
    ensure!(
      Enum.count(members, &(&1 == "data/rootfs.img")) == 1,
      "firmware root filesystem is missing"
    )

    for slot <- ~w(a b) do
      ensure!(
        String.contains?(metadata, ~s(#{slot}.nerves_fw_application_part0_target,"/root")),
        "firmware writable application mount is not /root"
      )
    end

    rootfs = read_member!(firmware, "data/rootfs.img", @max_rootfs_bytes)
    ensure!(byte_size(rootfs) > 0, "firmware root filesystem exceeds the development bound")

    directory =
      Path.join(
        System.tmp_dir!(),
        "wotex-nerves-rootfs-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      path = Path.join(directory, "rootfs.img")
      File.write!(path, rootfs)
      listing = command!("unsquashfs", ["-ll", path, "data", "root"], 1_048_576, 30_000)
      lines = String.split(listing, "\n")
      data = Enum.filter(lines, &String.contains?(&1, " squashfs-root/data -> "))
      root = Enum.filter(lines, &String.ends_with?(&1, " squashfs-root/root"))

      ensure!(
        length(data) == 1 and String.starts_with?(hd(data), "l") and
          String.ends_with?(hd(data), " -> root") and length(root) == 1 and
          String.starts_with?(hd(root), "d"),
        "firmware /data does not resolve to the writable /root mount"
      )

      firmware_legal_inputs!(path)
    after
      File.rm_rf!(directory)
    end

    "data_symlink_to_root_writable_application_mount"
  end

  defp firmware_legal_inputs!(rootfs) do
    expected = %{
      "srv/erlang/lib/ex_maude-0.4.3/priv/maude/COPYING" => ReleaseLegal.maude_license(),
      "srv/erlang/lib/ex_maude-0.4.3/priv/maude/THIRD_PARTY_NOTICES.md" =>
        ReleaseLegal.maude_notice(),
      "srv/erlang/lib/db_connection-2.10.2/priv/LICENSE" => ReleaseLegal.apache_license(),
      "srv/erlang/lib/rustler_precompiled-0.9.0/priv/LICENSE" => ReleaseLegal.apache_license()
    }

    for {relative, digest} <- expected do
      listing = command!("unsquashfs", ["-ll", rootfs, relative], 1_048_576, 30_000)

      matches =
        listing
        |> String.split("\n")
        |> Enum.filter(&String.ends_with?(&1, " squashfs-root/" <> relative))

      fields = if length(matches) == 1, do: String.split(hd(matches)), else: []
      size = if length(fields) >= 6, do: Integer.parse(Enum.at(fields, 2)), else: :error

      ensure!(
        length(fields) >= 6 and String.starts_with?(hd(fields), "-") and
          match?({n, ""} when n > 0 and n <= 20_000, size),
        "firmware legal input missing or oversized: #{relative}"
      )

      {expected_size, ""} = size
      bytes = command!("unsquashfs", ["-cat", rootfs, relative], 20_001, 30_000)

      ensure!(
        byte_size(bytes) == expected_size and
          Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest,
        "firmware legal input differs: #{relative}"
      )
    end
  end

  defp release_checks!(release) do
    beam = one!(Path.wildcard(Path.join(release, "erts-*/bin/beam.smp")), "ERTS executable")
    require_file!(beam, @max_release_bytes, "ERTS executable is unavailable")
    ensure!(elf_machine!(beam) == 183, "ERTS is not AArch64")

    vm_args = one!(Path.wildcard(Path.join(release, "releases/*/vm.args")), "VM arguments")
    require_file!(vm_args, 16_384, "VM arguments are unavailable or overlong")
    args = File.read!(vm_args)
    ensure!(String.valid?(args), "VM arguments are not UTF-8")

    ensure!(
      not Regex.match?(~r/^\s*-(?:name|sname|proto_dist|start_epmd)\b/m, args),
      "firmware enables an Erlang network node"
    )

    sys_config =
      one!(Path.wildcard(Path.join(release, "releases/*/sys.config")), "release configuration")

    require_file!(sys_config, 262_144, "release configuration is unavailable or overlong")
    config = File.read!(sys_config)
    ensure!(String.valid?(config), "release configuration is not UTF-8")

    settings = [
      "'Elixir.VintageNetEthernet'",
      "eth0",
      "method=>dhcp",
      "{persistence,'Elixir.VintageNet.Persistence.Null'}"
    ]

    probes =
      Regex.scan(~r/\{internet_host_list,\[([^\]]*)\]\}/, config, capture: :all_but_first)
      |> List.flatten()

    ensure!(
      Enum.all?(settings, &String.contains?(config, &1)) and probes == ["{{127,0,0,1},1}"],
      "wired LAN configuration or local-only probe is missing"
    )

    for app <- ~w(vintage_net vintage_net_ethernet) do
      ensure!(
        length(Path.wildcard(Path.join(release, "lib/#{app}-[0-9]*"))) == 1,
        "wired LAN applications are not packaged"
      )
    end

    ensure!(
      Enum.all?(@forbidden_apps, fn app ->
        Path.wildcard(Path.join(release, "lib/#{app}-[0-9]*")) == []
      end),
      "remote administration or discovery application is packaged"
    )

    priv =
      one!(Path.wildcard(Path.join(release, "lib/ex_maude-*/priv")), "ex_maude private directory")

    require_directory!(priv, "ex_maude private directory is unavailable")

    ensure!(
      ReleaseLegal.matches?(Path.join(priv, "maude/COPYING"), ReleaseLegal.maude_license()) and
        ReleaseLegal.matches?(
          Path.join(priv, "maude/THIRD_PARTY_NOTICES.md"),
          ReleaseLegal.maude_notice(),
          4_096
        ),
      "Maude standard-library legal inputs are missing"
    )

    for package <- ~w(db_connection-2.10.2 rustler_precompiled-0.9.0) do
      ensure!(
        ReleaseLegal.matches?(
          Path.join([release, "lib", package, "priv/LICENSE"]),
          ReleaseLegal.apache_license()
        ),
        "Apache license input is missing for #{package}"
      )
    end

    priv
  end

  defp scan_release!(release, maude_priv),
    do: scan_directory!(release, release, maude_priv, {0, 0, 0})

  defp scan_directory!(directory, release, maude_priv, counts) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(counts, fn name, {files, bytes, elf_files} = state ->
      path = Path.join(directory, name)
      info = File.lstat!(path)

      case info.type do
        :directory ->
          scan_directory!(path, release, maude_priv, state)

        :regular ->
          files = files + 1
          bytes = bytes + info.size

          ensure!(
            files <= @max_files and bytes <= @max_release_bytes,
            "release tree exceeds development bound"
          )

          ensure!(name not in @foreign_maude, "foreign Maude executable remains in ARM release")
          header = read_header!(path)

          ensure!(
            binary_part(header <> <<0, 0, 0, 0>>, 0, 4) not in @macho_magic,
            "Mach-O executable remains in ARM release"
          )

          elf_files =
            if String.starts_with?(header, <<0x7F, "ELF">>) do
              ensure!(elf_machine(header) == 183, "non-AArch64 ELF remains in ARM release")

              ensure!(
                not String.starts_with?(path, maude_priv <> "/"),
                "unqualified ARM Maude executable remains in release"
              )

              elf_files + 1
            else
              elf_files
            end

          {files, bytes, elf_files}

        :symlink ->
          fail!("release tree contains a symlink")

        _ ->
          fail!("release tree contains a nonregular entry")
      end
    end)
    |> then(fn {files, _bytes, elf_files} = result ->
      if directory == release, do: {files, elf_files}, else: result
    end)
  end

  defp archive_members!(firmware) do
    names =
      command!("unzip", ["-Z1", firmware], @max_archive_listing_bytes, 30_000)
      |> String.split("\n", trim: true)

    ensure!(length(names) <= @max_files, "firmware archive has too many members")
    names
  end

  defp read_member!(firmware, name, max_bytes) do
    case Command.run("unzip", ["-p", firmware, name], max_bytes + 1, 30_000) do
      {:ok, bytes} when byte_size(bytes) <= max_bytes -> bytes
      {:ok, _} -> fail!("firmware update metadata exceeds the development bound")
      {:error, _} -> fail!("firmware member #{name} is missing or exceeds the development bound")
    end
  end

  defp command!(executable, args, max_bytes, timeout_ms) do
    case Command.run(executable, args, max_bytes, timeout_ms) do
      {:ok, output} -> output
      {:error, reason} -> fail!("#{executable} failed: #{reason}")
    end
  end

  defp read_header!(path) do
    {:ok, bytes} = File.open(path, [:read, :binary], &IO.binread(&1, 20))
    if bytes == :eof, do: <<>>, else: bytes
  end

  defp elf_machine!(path) do
    case elf_machine(read_header!(path)) do
      nil -> fail!("expected 64-bit little-endian ELF: #{Path.basename(path)}")
      machine -> machine
    end
  end

  defp elf_machine(<<0x7F, "ELF", 2, 1, _::binary-size(12), machine::little-16>>), do: machine
  defp elf_machine(_), do: nil

  defp one!(paths, description) do
    case paths do
      [path] -> path
      _ -> fail!("expected one #{description}, found #{length(paths)}")
    end
  end

  defp require_directory!(path, message) do
    ensure!(match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)), message)
  end

  defp require_file!(path, limit, message) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= limit -> size
      _ -> fail!(message)
    end
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Nerves.Image.Check do
  @moduledoc """
  Checks a cross-built Raspberry Pi 4 release and firmware package.

  Run `mix woh.nerves.image.check RELEASE_TREE FIRMWARE.fw` after building the
  Nerves image. The task checks the AArch64 executable closure, private Maude
  legal bytes, offline wired configuration, tryboot update plan and the
  writable `/data` path inside the firmware. Its JSON report is packaging
  evidence only; board boot, rollback and power-loss tests remain necessary.
  """

  @shortdoc "Check a Pi 4 Nerves firmware package"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([release, firmware]) do
    case Woh.Tool.NervesImage.check(release, firmware) do
      {:ok, report} -> Mix.shell().info(JSON.encode!(report))
      {:error, reason} -> Mix.raise("Nerves image check failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.nerves.image.check RELEASE_TREE FIRMWARE.fw")
end
