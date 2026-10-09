defmodule WotexHome.LinuxNativeBundleTest do
  @moduledoc false
  use ExUnit.Case

  alias Woh.Tool.{LinuxNativeBundle, LinuxNativeDeps, ReleaseComponents}

  @project Path.expand("..", __DIR__)

  test "attributes each provider and its pinned package copyright independently" do
    for library <- LinuxNativeBundle.profile()["libraries"] do
      assert ReleaseComponents.component_for("native/linux-libraries/lib/" <> library["library"]) ==
               library["component"]

      assert ReleaseComponents.component_for(
               "native/linux-libraries/licenses/packages/" <> library["package"] <> "/COPYRIGHT"
             ) == library["component"]

      assert {:ok, inputs} = ReleaseComponents.license_inputs(@project, library["component"])
      assert length(inputs) == 11
      assert hd(inputs)["sha256"] == library["copyright"]["sha256"]
      assert LinuxNativeBundle.package_version(library["component"]) == library["version"]
    end
  end

  test "refuses missing or changed pinned source legal inputs" do
    directory = temporary()
    library = hd(LinuxNativeBundle.profile()["libraries"])
    assert {:error, _} = ReleaseComponents.license_inputs(directory, library["component"])
    path = Path.join(directory, library["copyright"]["path"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "changed")
    assert {:error, reason} = ReleaseComponents.license_inputs(directory, library["component"])
    assert reason =~ "pinned Linux license input differs"
  end

  test "unissued payload inspection does not claim inventory verification" do
    directory = temporary()
    assert {:error, _} = LinuxNativeDeps.check_payload(directory, "arm64")
    assert {:error, _} = LinuxNativeBundle.verify(directory)
  end

  if :os.type() == {:unix, :linux} and
       String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64") and
       System.find_executable("cc") != nil and System.find_executable("patchelf") != nil do
    alias Woh.Tool.{Command, Hash, ReleaseInventory}

    setup do
      directory = temporary()
      release = Path.join(directory, "release")
      beam = Path.join(release, "erts-fixture/bin/beam.smp")
      File.mkdir_p!(Path.dirname(beam))
      source = Path.join(directory, "main.c")
      File.write!(source, "int main(void) { return 0; }\n")

      {output, 0} =
        System.cmd(
          "cc",
          [
            source,
            "-Wl,--no-as-needed",
            "-l:libcrypto.so.3",
            "-l:libstdc++.so.6",
            "-l:libtinfo.so.6",
            "-l:libz.so.1",
            "-l:libzstd.so.1",
            "-l:libgcc_s.so.1",
            "-o",
            beam
          ],
          stderr_to_stdout: true
        )

      assert is_binary(output)
      {:ok, release: release, beam: beam, directory: directory}
    end

    test "bundles actual pinned libraries, resolves their closure and executes the fixture",
         context do
      assert {:ok, 7} = LinuxNativeBundle.assemble(context.release, @project)
      assert {:ok, 7} = LinuxNativeBundle.verify(context.release)

      assert {:ok, %{"native_files" => 7, "inventory_verified" => false}} =
               LinuxNativeDeps.check_payload(context.release, "arm64")

      assert {:ok, loads} = Command.run(context.beam, [], 65_536, 5_000, [{"LD_DEBUG", "libs"}])

      for library <- LinuxNativeBundle.profile()["libraries"] do
        assert loads =~ "calling init: "

        assert Regex.match?(
                 ~r/calling init: .*native\/linux-libraries\/lib\/#{Regex.escape(library["library"])}/,
                 loads
               )
      end

      assert {:ok, _} = ReleaseInventory.create(context.release, String.duplicate("a", 40))

      assert {:ok, %{"native_files" => 7, "inventory_verified" => true}} =
               LinuxNativeDeps.check(context.release, "arm64")

      original = Hash.sha256(context.beam)
      assert {:error, reason} = LinuxNativeBundle.assemble(context.release, @project)
      assert reason =~ "issued release"
      assert Hash.sha256(context.beam) == original
    end

    test "a pinned provider cannot be reblessed by rewriting the unsigned patch digest",
         context do
      assert {:ok, 7} = LinuxNativeBundle.assemble(context.release, @project)
      profile = LinuxNativeBundle.profile()
      library = hd(profile["libraries"])
      relative = "native/linux-libraries/lib/" <> library["library"]
      path = Path.join(context.release, relative)
      File.write!(path, File.read!(path) <> "changed")
      manifest = Path.join(context.release, LinuxNativeBundle.manifest())
      report = JSON.decode!(File.read!(manifest))

      report =
        Map.update!(report, "patches", fn patches ->
          Enum.map(patches, fn patch ->
            if patch["path"] == relative,
              do: Map.put(patch, "packaged_sha256", Hash.sha256(path)),
              else: patch
          end)
        end)

      File.write!(manifest, JSON.encode!(report))
      assert {:error, reason} = LinuxNativeBundle.verify(context.release)
      assert reason =~ "provider source or patched bytes differ"
    end

    test "profile substitution and malformed patch records refuse", context do
      assert {:ok, 7} = LinuxNativeBundle.assemble(context.release, @project)
      manifest = Path.join(context.release, LinuxNativeBundle.manifest())
      bytes = File.read!(manifest)
      report = JSON.decode!(bytes)
      changed = put_in(report, ["profile", "glibc_package_version"], "other")
      File.write!(manifest, JSON.encode!(changed))
      assert {:error, reason} = LinuxNativeBundle.verify(context.release)
      assert reason =~ "profile differs"

      File.write!(manifest, JSON.encode!(Map.put(report, "patches", List.duplicate(nil, 7))))
      assert {:error, reason} = LinuxNativeBundle.verify(context.release)
      assert reason =~ "invalid Linux native patch list"
    end

    test "missing source legal input refuses before changing the assembled ELF", context do
      original = Hash.sha256(context.beam)
      assert {:error, _} = LinuxNativeBundle.assemble(context.release, context.directory)
      assert Hash.sha256(context.beam) == original
      assert {:error, :enoent} = File.lstat(Path.join(context.release, "native"))
    end

    test "altered or linked packaged copyrights refuse", context do
      assert {:ok, 7} = LinuxNativeBundle.assemble(context.release, @project)
      library = hd(LinuxNativeBundle.profile()["libraries"])

      path =
        Path.join(
          context.release,
          "native/linux-libraries/licenses/packages/" <> library["package"] <> "/COPYRIGHT"
        )

      File.write!(path, "changed")
      assert {:error, reason} = LinuxNativeBundle.verify(context.release)
      assert reason =~ "packaged Linux license input differs"
      File.rm!(path)
      File.ln_s!(Path.join(@project, library["copyright"]["path"]), path)
      assert {:error, reason} = LinuxNativeBundle.verify(context.release)
      assert reason =~ "symlink"
    end
  end

  defp temporary do
    path = Path.join(System.tmp_dir!(), "woh-native-bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
