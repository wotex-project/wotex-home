defmodule WotexHome.LinuxInstallPreflightTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Woh.Tool.{LinuxInstallPreflight, LinuxNativeBundle, LinuxServicePackage}

  defp report do
    %{
      "profile" => LinuxServicePackage.profile(),
      "source_revision" => String.duplicate("a", 40),
      "artifact_id" => String.duplicate("b", 64)
    }
  end

  defp snapshot do
    %{
      platform: {:unix, :linux},
      uid: 0,
      distribution: {"debian", "13"},
      architecture: "arm64",
      glibc_package: LinuxNativeBundle.profile()["glibc_package_version"],
      pid1: "systemd",
      cgroup: "cgroup2fs",
      systemd_version: 257,
      account: :absent,
      group: :absent,
      units: :absent,
      paths: Map.new(LinuxInstallPreflight.paths(), &{&1, :absent}),
      parents:
        Map.new(
          ~w(/opt /var/lib /run /etc/systemd /etc/systemd/system /usr/lib/systemd/system),
          &{&1, :safe_directory}
        ),
      storage:
        Map.new(~w(/opt /var/lib), &{&1, %{filesystem: "ext4", writable: true, executable: true}})
    }
  end

  test "initial plan is inert, cohort-bound and refuses existing resources" do
    assert {:ok, plan} = LinuxInstallPreflight.plan(report(), snapshot())
    assert plan["registration"] == "not_performed"
    assert plan["installed_host_qualification"] == "missing"
    assert plan["artifact_id"] == report()["artifact_id"]

    assert {:error, _} =
             LinuxInstallPreflight.plan(
               put_in(report(), ["profile", "account"], "foreign"),
               snapshot()
             )

    for change <- [
          %{account: :present},
          %{group: :present},
          %{units: :present},
          %{uid: 10001},
          %{architecture: "amd64"},
          %{pid1: "container-init"},
          %{cgroup: "tmpfs"},
          %{systemd_version: 256},
          %{glibc_package: "different"},
          %{parents: %{}},
          %{paths: %{}}
        ] do
      assert {:error, _} = LinuxInstallPreflight.plan(report(), Map.merge(snapshot(), change))
    end

    for path <- LinuxInstallPreflight.paths() do
      changed = put_in(snapshot(), [:paths, path], :occupied_or_unsafe)
      assert {:error, reason} = LinuxInstallPreflight.plan(report(), changed)
      assert reason =~ path
    end
  end

  test "nested mount controls govern storage instead of the root filesystem" do
    mounts = """
    20 1 8:1 / / rw,relatime - ext4 /dev/fixture rw
    21 20 8:2 / /opt rw,noexec,relatime - xfs /dev/other rw
    22 20 0:8 / /var/lib rw,relatime - nfs fixture:/state rw
    """

    opt = LinuxInstallPreflight.observe_storage(mounts, "/opt")
    state = LinuxInstallPreflight.observe_storage(mounts, "/var/lib")
    assert opt == %{filesystem: "xfs", writable: true, executable: false}
    assert state.filesystem == "nfs"
    changed = %{snapshot() | storage: %{"/opt" => opt, "/var/lib" => state}}
    assert {:error, reason} = LinuxInstallPreflight.plan(report(), changed)
    assert reason =~ "/opt"
    changed = put_in(changed, [:storage, "/opt"], snapshot().storage["/opt"])
    assert {:error, reason} = LinuxInstallPreflight.plan(report(), changed)
    assert reason =~ "/var/lib"

    assert %{writable: false} =
             LinuxInstallPreflight.observe_storage(
               "20 1 8:1 / / ro,relatime - ext4 /dev/fixture ro\n",
               "/var/lib"
             )

    private_state = put_in(snapshot(), [:storage, "/var/lib", :executable], false)
    assert {:ok, _} = LinuxInstallPreflight.plan(report(), private_state)
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    test "actual foreign paths and symlink ancestors are observed without modification" do
      root = Path.join(System.tmp_dir!(), "woh-preflight-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "opt"))
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)
      assert LinuxInstallPreflight.observe_paths(root)["/opt/wotex-home"] == :absent
      foreign = Path.join(root, "opt/wotex-home")
      File.write!(foreign, "foreign owner bytes")
      before = File.stat!(foreign)
      assert LinuxInstallPreflight.observe_paths(root)["/opt/wotex-home"] == :occupied_or_unsafe
      assert File.stat!(foreign) == before
      assert File.read!(foreign) == "foreign owner bytes"
      File.rm!(foreign)
      File.rmdir!(Path.join(root, "opt"))
      File.ln_s!(System.tmp_dir!(), Path.join(root, "opt"))
      assert LinuxInstallPreflight.observe_paths(root)["/opt/wotex-home"] == :occupied_or_unsafe
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(root, "opt"))
    end

    if File.read!("/proc/1/comm") != "systemd\n" do
      test "real host preflight refuses container PID 1 after verifying inert fixture bytes" do
        alias Woh.Tool.{ReleaseBootstrap, ReleaseInventory}

        root =
          Path.join(
            System.tmp_dir!(),
            "woh-preflight-artifact-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(Path.join(root, "bin"))
        File.chmod!(root, 0o700)
        File.write!(Path.join(root, "bin/fixture"), "inert fixture bytes")
        manifest = root <> ".bootstrap.tsv"

        on_exit(fn ->
          File.rm_rf!(root)
          File.rm(manifest)
        end)

        assert {:ok, _} = LinuxServicePackage.assemble(root, String.duplicate("a", 40))
        assert {:ok, _} = ReleaseInventory.create(root, String.duplicate("a", 40))
        assert {:ok, pin} = ReleaseBootstrap.create(root, manifest)
        before = LinuxInstallPreflight.observe_paths()
        assert {:error, reason} = LinuxInstallPreflight.check(root, manifest, pin)
        assert reason =~ "systemd as PID 1"
        assert LinuxInstallPreflight.observe_paths() == before
        assert {:ok, _} = ReleaseInventory.verify(root)
      end
    end
  end
end
