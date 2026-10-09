defmodule WotexHome.LinuxServicePackageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Woh.Tool.{Hash, LinuxServicePackage, ReleaseComponents, ReleaseInventory}

  # Deliberate fixture identity; these files are not an executable release.
  @revision String.duplicate("a", 40)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "woh-service-package-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(directory, "bin"))
    File.write!(Path.join(directory, "bin/wotex_home"), "fixture core payload")
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "binds inert configuration to core bytes and the issued source identity", context do
    assert {:ok, report} = LinuxServicePackage.assemble(context.directory, @revision)
    assert report["registration"] == "not_performed_by_packaging"
    assert report["profile"]["installed_host_qualification"] == "missing"
    assert report["profile"]["durable_state_hard_quota"] == "not_implemented"
    assert {:ok, ^report} = LinuxServicePackage.verify_payload(context.directory)
    assert {:error, _} = LinuxServicePackage.verify(context.directory)
    assert {:ok, 6} = ReleaseInventory.create(context.directory, @revision)
    assert {:ok, ^report} = LinuxServicePackage.verify(context.directory)

    assert ReleaseComponents.component_for("native/linux-service/manifest.json") ==
             LinuxServicePackage.component()

    original = Hash.sha256(Path.join(context.directory, "bin/wotex_home"))
    assert {:error, reason} = LinuxServicePackage.assemble(context.directory, @revision)
    assert reason =~ "issued release"
    assert Hash.sha256(Path.join(context.directory, "bin/wotex_home")) == original
  end

  test "identical core bytes have stable names; source or payload changes produce another name",
       context do
    assert {:ok, original} = LinuxServicePackage.assemble(context.directory, @revision)
    other = context.directory <> "-other"
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)
    File.mkdir!(Path.join(other, "bin"))
    File.cp!(Path.join(context.directory, "bin/wotex_home"), Path.join(other, "bin/wotex_home"))
    assert {:ok, same} = LinuxServicePackage.assemble(other, @revision)
    assert same["artifact_id"] == original["artifact_id"]

    File.rm_rf!(Path.join(other, LinuxServicePackage.directory()))
    File.write!(Path.join(other, "bin/wotex_home"), "different fixture core")
    assert {:ok, changed} = LinuxServicePackage.assemble(other, @revision)
    refute changed["artifact_id"] == original["artifact_id"]

    File.rm_rf!(Path.join(other, LinuxServicePackage.directory()))
    assert {:ok, revised} = LinuxServicePackage.assemble(other, String.duplicate("b", 40))
    refute revised["artifact_id"] == changed["artifact_id"]
  end

  test "changed source and service bytes or extra files refuse", context do
    assert {:ok, _} = LinuxServicePackage.assemble(context.directory, @revision)
    file = Path.join(context.directory, "bin/wotex_home")
    original = File.read!(file)
    File.write!(file, "changed")
    assert {:error, reason} = LinuxServicePackage.verify_payload(context.directory)
    assert reason =~ "payload identity differs"
    File.write!(file, original)

    extra = Path.join(context.directory, LinuxServicePackage.directory() <> "/extra.conf")
    File.write!(extra, "injected configuration")
    assert {:error, reason} = LinuxServicePackage.verify_payload(context.directory)
    assert reason =~ "file set differs"
    File.rm!(extra)

    unit =
      Path.join(
        context.directory,
        LinuxServicePackage.directory() <> "/etc/systemd/system/wotex-home.service"
      )

    File.write!(unit, File.read!(unit) <> "User=root\n")
    assert {:error, reason} = LinuxServicePackage.verify_payload(context.directory)
    assert reason =~ "configuration differs"
  end

  test "source substitution cannot borrow another issued inventory", context do
    assert {:ok, _} = LinuxServicePackage.assemble(context.directory, @revision)
    assert {:ok, 6} = ReleaseInventory.create(context.directory, String.duplicate("b", 40))
    assert {:error, reason} = LinuxServicePackage.verify(context.directory)
    assert reason =~ "source differs"
  end

  test "symlink and invalid revision refuse before creating service files", context do
    assert {:error, _} = LinuxServicePackage.assemble(context.directory, "bad\nUser=root")

    assert {:error, :enoent} =
             File.lstat(Path.join(context.directory, LinuxServicePackage.directory()))

    File.ln_s!("/tmp", Path.join(context.directory, "linked"))
    assert {:error, reason} = LinuxServicePackage.assemble(context.directory, @revision)
    assert reason =~ "symlink"

    assert {:error, :enoent} =
             File.lstat(Path.join(context.directory, LinuxServicePackage.directory()))
  end

  test "nonregular and widened mode service files cannot be accepted", context do
    assert {:ok, _} = LinuxServicePackage.assemble(context.directory, @revision)

    unit =
      Path.join(
        context.directory,
        LinuxServicePackage.directory() <> "/etc/systemd/system/wotex-home.service"
      )

    File.chmod!(unit, 0o666)
    assert {:error, reason} = LinuxServicePackage.verify_payload(context.directory)
    assert reason =~ "configuration differs"
    File.rm!(unit)
    File.ln_s!("../../../../../../bin/wotex_home", unit)
    assert {:error, reason} = LinuxServicePackage.verify_payload(context.directory)
    assert reason =~ "symlink"
  end
end
