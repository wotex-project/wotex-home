defmodule WotexHome.LinuxNativeDepsCheckTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Woh.Tool.{LinuxNativeDeps, ReleaseInventory}

  test "accepts only complete 64-bit little-endian executable/shared target headers" do
    assert %{type: 2, machine: 183} = LinuxNativeDeps.header!(elf(183), "arm64")
    assert %{type: 3, machine: 62} = LinuxNativeDeps.header!(elf(62, 3), "amd64")

    for bytes <- [
          elf(62),
          elf(183, 1),
          binary_part(elf(183), 0, 63),
          replace(elf(183), 4, 1),
          replace(elf(183), 5, 2),
          replace(elf(183), 6, 0),
          replace(elf(183), 7, 9),
          replace(elf(183), 8, 1),
          replace(elf(183), 20, 2)
        ] do
      assert_raise LinuxNativeDeps.Error, ~r/ELF header/, fn ->
        LinuxNativeDeps.header!(bytes, "arm64")
      end
    end

    assert_raise LinuxNativeDeps.Error, ~r/architecture/, fn ->
      LinuxNativeDeps.header!(elf(183), "other")
    end
  end

  test "parses direct loads and checks the exact platform loader" do
    output = """
      [Requesting program interpreter: /lib/ld-linux-aarch64.so.1]
    Dynamic section at offset 0x1 contains 4 entries:
      0x0000000000000001 (NEEDED) Shared library: [libcrypto.so.3]
      0x0000000000000001 (NEEDED) Shared library: [libc.so.6]
      0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN/../../native/lib]
      0x000000000000000e (SONAME) Library soname: [own.so]
    """

    assert %{
             interpreter: "/lib/ld-linux-aarch64.so.1",
             needed: ["libc.so.6", "libcrypto.so.3"],
             runpath: "$ORIGIN/../../native/lib",
             soname: "own.so"
           } = LinuxNativeDeps.loads!(output, "arm64")

    for bad <- [
          String.replace(output, "aarch64", "other"),
          output <> "[Requesting program interpreter: missing\n",
          output <> "[Requesting program interpreter: /lib/ld-linux-aarch64.so.1]\n"
        ] do
      assert_raise LinuxNativeDeps.Error, ~r/interpreter/, fn ->
        LinuxNativeDeps.loads!(bad, "arm64")
      end
    end
  end

  test "refuses hidden search/load tags and malformed dependency names" do
    for tag <- ~w(RPATH FILTER AUXILIARY AUDIT DEPAUDIT CONFIG) do
      assert_raise LinuxNativeDeps.Error, ~r/dynamic search or load tag/, fn ->
        LinuxNativeDeps.loads!(" 0x0001 (#{tag}) value: [other]\n", "arm64")
      end
    end

    for value <- ["", "/tmp/libx.so", "../libx.so", "libx.so:other", ".", ".."] do
      assert_raise LinuxNativeDeps.Error, ~r/library basename/, fn ->
        LinuxNativeDeps.loads!(" 0x0001 (NEEDED) Shared library: [#{value}]\n", "arm64")
      end
    end

    assert_raise LinuxNativeDeps.Error, ~r/malformed/, fn ->
      LinuxNativeDeps.loads!(" 0x0001 (NEEDED) Shared library: missing\n", "arm64")
    end

    assert_raise LinuxNativeDeps.Error, ~r/duplicate/, fn ->
      LinuxNativeDeps.loads!(
        " 0x001d (RUNPATH) Library runpath: [$ORIGIN]\n" <>
          " 0x001d (RUNPATH) Library runpath: [$ORIGIN]\n",
        "arm64"
      )
    end
  end

  test "refuses glibc symbol versions above the Debian baseline and private ABI" do
    assert ["GLIBC_2.17", "GLIBC_2.2.5", "GLIBC_2.41", "GLIBC_ABI_DT_RELR"] =
             LinuxNativeDeps.glibc_versions!("""
             0x0010: Name: GLIBC_2.17 Flags: none Version: 2
             0x0020: Name: GLIBC_2.2.5 Flags: none Version: 3
             0x0030: Name: GLIBC_2.41 Flags: none Version: 4
             0x0040: Name: GLIBC_ABI_DT_RELR Flags: none Version: 5
             """)

    for value <- ~w(GLIBC_2.42 GLIBC_3.0 GLIBC_PRIVATE GLIBC_UNKNOWN) do
      assert_raise LinuxNativeDeps.Error, ~r/unsupported glibc version/, fn ->
        LinuxNativeDeps.glibc_versions!(" 0x0010: Name: #{value} Flags: none Version: 2\n")
      end
    end
  end

  test "resolves each direct library through its own bounded release-relative paths" do
    root = "/release"
    path = "/release/erts-1/bin/beam.smp"
    files = MapSet.new(["/release/native/lib/libcrypto.so.3"])
    info = %{needed: ["libc.so.6", "libcrypto.so.3"], runpath: "$ORIGIN/../../native/lib"}
    assert :ok = LinuxNativeDeps.resolve!(info, path, root, files)

    assert_raise LinuxNativeDeps.Error, ~r/unbundled native dependency/, fn ->
      LinuxNativeDeps.resolve!(%{info | runpath: nil}, path, root, files)
    end

    assert_raise LinuxNativeDeps.Error, ~r/unbundled native dependency/, fn ->
      LinuxNativeDeps.resolve!(
        info,
        path,
        root,
        MapSet.new(["/release/elsewhere/libcrypto.so.3"])
      )
    end

    for runpath <- [
          "$ORIGIN/../../../outside",
          "$ORIGIN/../../../release-other",
          "/usr/local/lib",
          "$ORIGIN:",
          ":$ORIGIN",
          "relative",
          "$LIB",
          "$ORIGIN/$PLATFORM",
          "$ORIGIN//tmp"
        ] do
      assert_raise LinuxNativeDeps.Error, fn ->
        LinuxNativeDeps.runpath!(runpath, path, root)
      end
    end

    assert ["/release/erts-1/bin", "/release/native/lib"] =
             LinuxNativeDeps.runpath!("${ORIGIN}:${ORIGIN}/../../native/lib", path, root)
  end

  test "requires an inventory and refuses payload drift, symlinks and foreign binaries" do
    directory =
      Path.join(System.tmp_dir!(), "woh-linux-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:error, _} = LinuxNativeDeps.check(directory, "arm64")

    foreign = Path.join(directory, "foreign")
    File.write!(foreign, <<0xCF, 0xFA, 0xED, 0xFE, 0::size(480)>>)
    assert {:ok, 1} = ReleaseInventory.create(directory, String.duplicate("a", 40))
    assert {:error, reason} = LinuxNativeDeps.check(directory, "arm64")
    assert reason =~ "foreign native binary"

    File.write!(foreign, "changed")
    assert {:error, reason} = LinuxNativeDeps.check(directory, "arm64")
    assert reason =~ "differs from inventory"

    File.rm!(foreign)
    File.ln_s!("outside", foreign)
    assert {:error, reason} = LinuxNativeDeps.check(directory, "arm64")
    assert reason =~ "symlink"
  end

  if :os.type() == {:unix, :linux} and System.find_executable("cc") != nil and
       System.find_executable("readelf") != nil do
    test "inspects compiled ELF closure and rejects a real unbundled library" do
      directory =
        Path.join(System.tmp_dir!(), "woh-linux-elf-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)
      release = Path.join(directory, "release")
      beam = Path.join(release, "erts-1/bin/beam.smp")
      File.mkdir_p!(Path.dirname(beam))
      source = Path.join(directory, "main.c")
      File.write!(source, "int main(void) { return 0; }\n")
      compile!([source, "-o", beam])

      architecture =
        if :erlang.system_info(:system_architecture)
           |> to_string()
           |> String.starts_with?("aarch64"), do: "arm64", else: "amd64"

      revision = String.duplicate("a", 40)
      assert {:ok, _} = ReleaseInventory.create(release, revision)

      assert {:ok, %{"native_files" => 1, "scope" => "direct_elf_loads_only"}} =
               LinuxNativeDeps.check(release, architecture)

      libdir = Path.join(release, "native/lib")
      File.mkdir_p!(libdir)
      library_source = Path.join(directory, "library.c")
      File.write!(library_source, "int outside(void) { return 0; }\n")
      library = Path.join(libdir, "liboutside.so")
      compile!(["-shared", "-fPIC", library_source, "-o", library])
      File.write!(source, "extern int outside(void); int main(void) { return outside(); }\n")

      compile!([
        source,
        "-L",
        libdir,
        "-loutside",
        "-Wl,--enable-new-dtags,-rpath,$ORIGIN/../../native/lib",
        "-o",
        beam
      ])

      assert {:ok, _} = ReleaseInventory.create(release, revision)
      assert {:ok, %{"native_files" => 2}} = LinuxNativeDeps.check(release, architecture)

      File.rename!(library, Path.join(libdir, "renamed.so"))
      assert {:ok, _} = ReleaseInventory.create(release, revision)
      assert {:error, reason} = LinuxNativeDeps.check(release, architecture)
      assert reason =~ "unbundled native dependency"
    end

    defp compile!(args) do
      {output, status} = System.cmd("cc", args, stderr_to_stdout: true)
      assert status == 0, output
    end
  end

  defp elf(machine, type \\ 2) do
    <<0x7F, "ELF", 2, 1, 1, 0, 0, 0::size(56), type::little-16, machine::little-16, 1::little-32,
      0::size(320)>>
  end

  defp replace(bytes, index, value) do
    <<prefix::binary-size(index), _, suffix::binary>> = bytes
    <<prefix::binary, value, suffix::binary>>
  end
end
