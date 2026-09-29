defmodule WotexHome.MacosNativeDepsCheckTest do
  @moduledoc false

  use ExUnit.Case

  alias Woh.Tool.MacosNativeDeps

  if Enum.all?(~w(clang lipo otool plutil), &System.find_executable/1) do
    test "checks system loads, deployment version, architecture and external libraries" do
      directory =
        Path.join(System.tmp_dir!(), "wotex-native-deps-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)

      app = Path.join(directory, "Test.app")
      macos = Path.join(app, "Contents/MacOS")
      File.mkdir_p!(macos)
      plist = Path.join(app, "Contents/Info.plist")
      write_plist(plist, "15.0")
      simple = Path.join(directory, "simple.c")
      File.write!(simple, "int main(void) { return 0; }\n")
      compile!(["-mmacosx-version-min=15.0", simple, "-o", Path.join(macos, "WotexHome")])
      File.cp!(Path.join(macos, "WotexHome"), Path.join(macos, "WotexHomeAgent"))

      assert {:ok, %{"native_files" => 2}} = MacosNativeDeps.check(app)

      write_plist(plist, "14.0")
      assert {:error, reason} = MacosNativeDeps.check(app)
      assert String.contains?(reason, "requires newer macOS")
      write_plist(plist, "15.0")

      library_source = Path.join(directory, "outside.c")
      File.write!(library_source, "int outside(void) { return 0; }\n")
      library = Path.join(directory, "liboutside.dylib")

      compile!([
        "-mmacosx-version-min=15.0",
        "-dynamiclib",
        library_source,
        "-install_name",
        library,
        "-o",
        library
      ])

      resources = Path.join(app, "Contents/Resources")
      File.mkdir_p!(resources)
      File.cp!(library, Path.join(resources, "liboutside.dylib"))
      assert {:ok, %{"nonportable_self_install_ids" => 1}} = MacosNativeDeps.check(app)

      foreign = Path.join(resources, "foreign")
      compile!(["-arch", "x86_64", "-mmacosx-version-min=15.0", simple, "-o", foreign])
      assert {:error, reason} = MacosNativeDeps.check(app)
      assert String.contains?(reason, "unsupported native architecture")
      File.rm!(foreign)

      linked = Path.join(directory, "linked.c")
      File.write!(linked, "extern int outside(void); int main(void) { return outside(); }\n")

      compile!([
        "-mmacosx-version-min=15.0",
        linked,
        library,
        "-o",
        Path.join(macos, "WotexHomeAgent")
      ])

      assert {:error, reason} = MacosNativeDeps.check(app)
      assert String.contains?(reason, "unbundled native dependency")
    end

    defp write_plist(path, version) do
      File.write!(
        path,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <>
          "<plist version=\"1.0\"><dict><key>LSMinimumSystemVersion</key>" <>
          "<string>#{version}</string></dict></plist>"
      )
    end

    defp compile!(args) do
      {output, status} = System.cmd("clang", args, stderr_to_stdout: true)
      assert status == 0, output
    end
  end

  test "rejects missing and unsupported dynamic load names" do
    assert_raise MacosNativeDeps.Error, ~r/no library name/, fn ->
      MacosNativeDeps.loads!("Load command 1\n          cmd LC_LOAD_DYLIB\nLoad command 2\n")
    end

    assert_raise MacosNativeDeps.Error, ~r/unsupported Mach-O dylib command/, fn ->
      MacosNativeDeps.loads!("Load command 1\n          cmd LC_RPATH_DYLIB\n")
    end
  end
end
