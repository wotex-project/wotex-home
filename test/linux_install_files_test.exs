defmodule WotexHome.LinuxInstallFilesTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Woh.Tool.LinuxInstallFiles

  test "installer tools are packaged only into fresh Home payload custody" do
    root = Path.join(System.tmp_dir!(), "woh-install-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/wotex_home-0.1.0/priv"))
    on_exit(fn -> File.rm_rf!(root) end)
    assert :ok = LinuxInstallFiles.assemble(root)
    assert {:error, _} = LinuxInstallFiles.assemble(root)

    for name <- LinuxInstallFiles.tools() do
      target = Path.join(root, "lib/wotex_home-0.1.0/priv/linux-install/#{name}")
      source = Path.expand("../native/linux/#{name}", __DIR__)
      assert File.read!(target) == File.read!(source)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(target)
    end
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    @tool Path.expand("../native/linux/installer-files", __DIR__)
    setup do
      root =
        Path.join(System.tmp_dir!(), "woh-install-files-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "atomic file writes, CAS and removal preserve foreign bytes", %{root: root} do
      path = Path.join(root, "journal.json")
      assert :ok = LinuxInstallFiles.write(path, 0o600, "first", nil, @tool)
      assert {:error, _} = LinuxInstallFiles.write(path, 0o600, "foreign", nil, @tool)
      assert File.read!(path) == "first"

      assert {:error, _} =
               LinuxInstallFiles.write(
                 path,
                 0o600,
                 "next",
                 LinuxInstallFiles.digest("wrong"),
                 @tool
               )

      assert File.read!(path) == "first"

      assert :ok =
               LinuxInstallFiles.write(
                 path,
                 0o600,
                 "next",
                 LinuxInstallFiles.digest("first"),
                 @tool
               )

      assert File.read!(path) == "next"

      assert {:error, _} =
               LinuxInstallFiles.remove(path, 0o600, LinuxInstallFiles.digest("wrong"), @tool)

      assert :ok = LinuxInstallFiles.remove(path, 0o600, LinuxInstallFiles.digest("next"), @tool)
      refute File.exists?(path)
      File.ln_s!(Path.join(root, "outside"), path)
      assert {:error, _} = LinuxInstallFiles.write(path, 0o600, "no", nil, @tool)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
    end

    test "directory publication sets ownership before exposing the name and preserves conflicts",
         %{root: root} do
      path = Path.join(root, "owned")
      assert :ok = LinuxInstallFiles.mkdir(path, 0o700, 211, 211, @tool)
      assert %File.Stat{type: :directory, uid: 211, gid: 211} = File.lstat!(path)
      assert Bitwise.band(File.lstat!(path).mode, 0o7777) == 0o700
      File.write!(Path.join(path, "private-fixture"), "preserve")
      assert {:error, _} = LinuxInstallFiles.mkdir(path, 0o755, 212, 212, @tool)
      assert File.read!(Path.join(path, "private-fixture")) == "preserve"
      assert File.lstat!(path).uid == 211

      outside = Path.join(root, "outside")
      File.write!(outside, "foreign bytes")
      linked = Path.join(root, "linked")
      File.ln_s!(outside, linked)
      assert {:error, _} = LinuxInstallFiles.mkdir(linked, 0o700, 211, 211, @tool)
      assert File.read!(outside) == "foreign bytes"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(linked)
      assert Enum.sort(File.ls!(root)) == ["linked", "outside", "owned"]
    end

    test "publication syncs a complete marked tree and cannot replace another namespace", %{
      root: root
    } do
      source = Path.join(root, "staged")
      File.mkdir_p!(Path.join(source, ".installer"))
      File.chmod!(Path.join(source, ".installer"), 0o700)
      marker = "fixture ownership bytes"

      assert :ok =
               LinuxInstallFiles.write(
                 Path.join(source, ".installer/owner.json"),
                 0o600,
                 marker,
                 nil,
                 @tool
               )

      File.write!(Path.join(source, "payload"), "inert bytes")
      destination = Path.join(root, "installed")
      File.mkdir!(destination)
      File.write!(Path.join(destination, "foreign"), "preserve")
      assert {:error, _} = LinuxInstallFiles.publish(source, destination, marker, @tool)
      assert File.read!(Path.join(destination, "foreign")) == "preserve"
      assert File.read!(Path.join(source, "payload")) == "inert bytes"
      File.rm!(Path.join(destination, "foreign"))
      File.rmdir!(destination)
      assert :ok = LinuxInstallFiles.publish(source, destination, marker, @tool)
      refute File.exists?(source)
      assert File.read!(Path.join(destination, "payload")) == "inert bytes"
      assert File.read!(Path.join(destination, ".installer/owner.json")) == marker
    end

    test "publication refuses symlinks and altered ownership before moving anything", %{
      root: root
    } do
      source = Path.join(root, "staged")
      File.mkdir_p!(Path.join(source, ".installer"))
      File.chmod!(Path.join(source, ".installer"), 0o700)
      marker = "fixture ownership bytes"

      assert :ok =
               LinuxInstallFiles.write(
                 Path.join(source, ".installer/owner.json"),
                 0o600,
                 marker,
                 nil,
                 @tool
               )

      File.ln_s!(root, Path.join(source, "linked"))
      destination = Path.join(root, "installed")
      assert {:error, _} = LinuxInstallFiles.publish(source, destination, marker, @tool)
      assert File.dir?(source)
      refute File.exists?(destination)
      File.rm!(Path.join(source, "linked"))
      assert {:error, _} = LinuxInstallFiles.publish(source, destination, "different", @tool)
      assert File.dir?(source)
      refute File.exists?(destination)
    end
  end
end
