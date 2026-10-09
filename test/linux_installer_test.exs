Code.require_file(Path.expand("support/linux_update_fixtures.exs", __DIR__))

defmodule WotexHome.LinuxInstallerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Woh.Tool.{LinuxInstallPreflight, LinuxNativeBundle}

  defmodule FixtureHost do
    @moduledoc false
    def snapshot do
      root = Process.get(:installer_fixture_root)

      {:ok,
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
         paths: LinuxInstallPreflight.observe_paths(root),
         parents: LinuxInstallPreflight.observe_parents(root),
         storage:
           Map.new(
             ~w(/opt /var/lib),
             &{&1, %{filesystem: "ext4", writable: true, executable: true}}
           )
       }}
    end

    def choose_account_id, do: {:ok, 211}

    def accounts(id, installation) do
      root = Process.get(:installer_fixture_root)
      passwd = File.read!(root <> "/etc/passwd")
      group = File.read!(root <> "/etc/group")

      user =
        "wotex-home:x:#{id}:#{id}:WoTEx Home installation #{installation}:/var/lib/wotex-home:/usr/sbin/nologin\n"

      wanted_group = "wotex-home:x:#{id}:\n"

      cond do
        String.contains?(passwd, user) and String.contains?(group, wanted_group) ->
          {:ok, :ready}

        not String.contains?(passwd, "wotex-home:") and String.contains?(group, wanted_group) ->
          {:ok, :group_only}

        not String.contains?(passwd, "wotex-home:") and not String.contains?(group, "wotex-home:") ->
          {:ok, :absent}

        true ->
          {:error, "foreign fixture account"}
      end
    end

    def create_group(id) do
      with :ok <- event!(:group),
           do:
             tool!("/usr/sbin/groupadd", [
               "--prefix",
               Process.get(:installer_fixture_root),
               "--system",
               "--gid",
               to_string(id),
               "wotex-home"
             ])
    end

    def create_user(id, installation) do
      event!(:user)

      tool!("/usr/sbin/useradd", [
        "--prefix",
        Process.get(:installer_fixture_root),
        "--system",
        "--uid",
        to_string(id),
        "--gid",
        to_string(id),
        "--no-user-group",
        "--no-create-home",
        "--no-log-init",
        "--home-dir",
        "/var/lib/wotex-home",
        "--shell",
        "/usr/sbin/nologin",
        "--comment",
        "WoTEx Home installation " <> installation,
        "wotex-home"
      ])

      event!(:after_user)
    end

    def verify_units(_) do
      if Process.delete(:installer_fixture_add_override) do
        File.write!(
          Process.get(:installer_fixture_root) <> "/usr/lib/systemd/system/wotex-home.service",
          "foreign fixture override"
        )
      end

      event!(:verify)
    end

    def reload, do: event!(:reload)
    def effective_units, do: event!(:effective)
    def enable_start, do: event!(:start)
    def disable_stop, do: event!(:stop)
    def stop_journal, do: event!(:journal_stop)
    def running, do: event!(:running)

    defp event!(event) do
      Process.put(
        :installer_fixture_events,
        Process.get(:installer_fixture_events, []) ++ [event]
      )

      if Process.get(:installer_fixture_fail) == event do
        Process.delete(:installer_fixture_fail)
        {:error, "injected fixture interruption"}
      else
        :ok
      end
    end

    defp tool!(tool, args) do
      case System.cmd(tool, args, stderr_to_stdout: true) do
        {"", 0} -> :ok
        _ -> {:error, "fixture account tool failed"}
      end
    end
  end

  if :os.type() == {:unix, :linux} and File.stat!("/proc/self").uid == 0 do
    alias Woh.Tool.{
      LinuxInstaller,
      LinuxServicePackage,
      ReleaseBootstrap,
      ReleaseInventory,
      LinuxInstallFiles,
      LinuxInstallStage,
      LinuxUpdateJournal,
      LinuxUpdateSelection
    }

    alias WotexHome.LinuxUpdateFixtures, as: F
    @tool Path.expand("../native/linux/installer-files", __DIR__)
    setup do
      directory =
        Path.join(System.tmp_dir!(), "woh-installer-#{System.unique_integer([:positive])}")

      root = Path.join(directory, "host")
      source = Path.join(directory, "source")
      File.mkdir_p!(source)
      File.chmod!(directory, 0o700)

      for relative <- ~w(opt var/lib run etc/systemd/system usr/lib/systemd/system) do
        File.mkdir_p!(Path.join(root, relative))
      end

      File.write!(root <> "/etc/passwd", "root:x:0:0:root:/root:/bin/sh\n")
      File.write!(root <> "/etc/group", "root:x:0:\n")
      File.write!(root <> "/etc/shadow", "root:!:20000:0:99999:7:::\n")
      File.write!(root <> "/etc/gshadow", "root:!::\n")

      File.write!(
        root <> "/etc/login.defs",
        "SYS_UID_MIN 100\nSYS_UID_MAX 999\nSYS_GID_MIN 100\nSYS_GID_MAX 999\nUID_MIN 1000\nGID_MIN 1000\n"
      )

      File.write!(Path.join(source, "fixture"), "inert public payload")
      assert {:ok, _} = LinuxServicePackage.assemble(source, String.duplicate("a", 40))
      assert {:ok, _} = ReleaseInventory.create(source, String.duplicate("a", 40))
      manifest = Path.join(directory, "bootstrap.tsv")
      assert {:ok, pin} = ReleaseBootstrap.create(source, manifest)
      Process.put(:installer_fixture_root, root)
      Process.put(:installer_fixture_events, [])
      on_exit(fn -> File.rm_rf!(directory) end)

      %{
        root: root,
        source: source,
        manifest: manifest,
        pin: pin,
        options: [root: root, host: FixtureHost, tool: @tool, fixture: true]
      }
    end

    test "initial install, exact repeat, uninstall and reinstall preserve private bytes",
         context do
      assert {:ok, %{"phase" => "installed"}} = run(:install, context)
      events = Process.get(:installer_fixture_events)
      assert :group in events and :user in events and :start in events
      assert Enum.find_index(events, &(&1 == :verify)) < Enum.find_index(events, &(&1 == :start))
      shadow = File.read!(context.root <> "/etc/shadow")
      assert shadow =~ "wotex-home:!:"
      data = context.root <> "/var/lib/wotex-home/private-fixture"
      File.write!(data, "preserved fixture custody")
      Process.put(:installer_fixture_events, [])
      assert {:ok, %{"phase" => "installed"}} = run(:install, context)
      refute :user in Process.get(:installer_fixture_events)
      refute :start in Process.get(:installer_fixture_events)
      assert {:ok, %{"phase" => "uninstalled"}} = run(:uninstall, context)
      assert File.read!(data) == "preserved fixture custody"
      refute File.exists?(context.root <> "/etc/systemd/system/wotex-home.service")
      assert {:ok, %{"phase" => "uninstalled"}} = run(:uninstall, context)
      assert {:ok, %{"phase" => "installed"}} = run(:install, context)
      assert File.read!(data) == "preserved fixture custody"
    end

    test "legacy format installation remains repeatable and state-preserving to uninstall", c do
      report_path = Path.join(c.source, "native/linux-service/manifest.json")
      report = JSON.decode!(File.read!(report_path))
      legacy_files = LinuxServicePackage.files(report["artifact_id"], 1)

      for {relative, bytes} <- legacy_files,
          do: File.write!(Path.join(c.source, "native/linux-service/" <> relative), bytes)

      legacy =
        report
        |> Map.delete("update_compatibility")
        |> Map.put("schema_version", 1)
        |> Map.put(
          "files",
          Map.new(legacy_files, fn {path, bytes} ->
            {path, Woh.Tool.LinuxInstallFiles.digest(bytes)}
          end)
        )

      File.write!(report_path, JSON.encode!(legacy) <> "\n")
      File.rm!(Path.join(c.source, "release-inventory.json"))
      assert {:ok, _} = ReleaseInventory.create(c.source, String.duplicate("a", 40))
      File.rm!(c.manifest)
      assert {:ok, pin} = ReleaseBootstrap.create(c.source, c.manifest)
      c = %{c | pin: pin}
      assert {:ok, _} = run(:install, c)
      data = c.root <> "/var/lib/wotex-home/private-fixture"
      File.write!(data, "preserve legacy private bytes")
      assert {:ok, _} = run(:install, c)
      assert {:ok, _} = run(:uninstall, c)
      assert File.read!(data) == "preserve legacy private bytes"
      refute File.exists?(c.root <> "/etc/systemd/system/wotex-home.service")
    end

    test "retained update progress refuses initial repeat and uninstall before effects", c do
      assert {:ok, _} = run(:install, c)
      base = c.root <> "/opt/wotex-home"
      owner_bytes = File.read!(base <> "/.installer/owner.json")
      owner = JSON.decode!(owner_bytes)

      source = %{
        "source_revision" => owner["source_revision"],
        "artifact_id" => owner["artifact_id"],
        "bootstrap_sha256" => owner["bootstrap_sha256"],
        "inventory_sha256" =>
          Woh.Tool.LinuxInstallFiles.digest(
            File.read!(base <> "/releases/" <> owner["artifact_id"] <> "/release-inventory.json")
          )
      }

      {:ok, journal} = Woh.Tool.LinuxUpdateJournal.new(owner_bytes, source)

      {:ok, journal} =
        Woh.Tool.LinuxUpdateJournal.prepare(
          journal,
          String.duplicate("a", 64),
          source,
          %{source | "artifact_id" => String.duplicate("b", 64)},
          123
        )

      {:ok, journal_bytes} = Woh.Tool.LinuxUpdateJournal.encode(journal)
      journal_path = base <> "/.installer/update-journal.json"
      File.write!(journal_path, journal_bytes)
      File.chmod!(journal_path, 0o600)
      unit = c.root <> "/etc/systemd/system/wotex-home.service"
      unit_bytes = File.read!(unit)
      Process.put(:installer_fixture_events, [])

      for action <- [:install, :uninstall] do
        assert {:error, reason} = run(action, c)
        assert reason =~ "retained release update"
        assert Process.get(:installer_fixture_events) == []
        assert File.read!(journal_path) == journal_bytes
        assert File.read!(base <> "/.installer/owner.json") == owner_bytes
        assert File.read!(unit) == unit_bytes
        assert phase(c) == "installed"
      end

      File.write!(journal_path, "foreign progress")
      assert {:error, _} = run(:uninstall, c)
      assert File.read!(journal_path) == "foreign progress"
      assert Process.get(:installer_fixture_events) == []
    end

    test "lost account reply resumes original ownership without creating a second account",
         context do
      Process.put(:installer_fixture_fail, :after_user)
      assert {:error, _} = run(:install, context)
      assert phase(context) == "accounts_pending"
      Process.put(:installer_fixture_events, [])
      assert {:ok, %{"phase" => "installed"}} = run(:install, context)
      refute :user in Process.get(:installer_fixture_events)
    end

    test "parser diagnostics leave owned inert configuration and no registration", context do
      Process.put(:installer_fixture_fail, :verify)
      assert {:error, _} = run(:install, context)
      assert phase(context) == "configuration_pending"
      refute :start in Process.get(:installer_fixture_events)
      assert {:ok, %{"phase" => "installed"}} = run(:install, context)
    end

    test "foreign configuration refuses without overwriting bytes or starting service", context do
      Process.put(:installer_fixture_fail, :after_user)
      assert {:error, _} = run(:install, context)
      target = context.root <> "/etc/systemd/system/wotex-home.service"
      File.write!(target, "foreign controller bytes")
      Process.put(:installer_fixture_events, [])
      assert {:error, _} = run(:install, context)
      assert File.read!(target) == "foreign controller bytes"
      refute :start in Process.get(:installer_fixture_events)
    end

    test "interrupted stop precedes removal and retries preserve the same state", context do
      assert {:ok, _} = run(:install, context)
      Process.put(:installer_fixture_fail, :journal_stop)
      assert {:error, _} = run(:uninstall, context)
      assert phase(context) == "uninstall_pending"
      assert File.regular?(context.root <> "/etc/systemd/system/wotex-home.service")
      assert {:ok, %{"phase" => "uninstalled"}} = run(:uninstall, context)
    end

    test "lost reload after removal resumes the stopped phase without recreating configuration",
         context do
      assert {:ok, _} = run(:install, context)
      Process.put(:installer_fixture_fail, :reload)
      assert {:error, _} = run(:uninstall, context)
      assert phase(context) == "uninstall_stopped"
      refute File.exists?(context.root <> "/etc/systemd/system/wotex-home.service")
      Process.put(:installer_fixture_events, [])
      assert {:ok, %{"phase" => "uninstalled"}} = run(:uninstall, context)
      refute :stop in Process.get(:installer_fixture_events)
    end

    test "malformed retained ownership refuses before registration changes", context do
      assert {:ok, _} = run(:install, context)
      owner_path = context.root <> "/opt/wotex-home/.installer/owner.json"
      before = File.read!(owner_path)
      File.write!(owner_path, before <> "damage")
      Process.put(:installer_fixture_events, [])
      assert {:error, _} = run(:install, context)
      refute :start in Process.get(:installer_fixture_events)
      assert File.read!(owner_path) == before <> "damage"
    end

    test "a valid different artifact cannot upgrade by repeating initial setup", context do
      assert {:ok, _} = run(:install, context)
      owner_path = context.root <> "/opt/wotex-home/.installer/owner.json"
      before = File.read!(owner_path)
      File.write!(Path.join(context.source, "fixture"), "different public source bytes")
      File.rm!(Path.join(context.source, "release-inventory.json"))
      File.rm_rf!(Path.join(context.source, "native/linux-service"))
      assert {:ok, _} = LinuxServicePackage.assemble(context.source, String.duplicate("b", 40))
      assert {:ok, _} = ReleaseInventory.create(context.source, String.duplicate("b", 40))
      File.rm!(context.manifest)
      assert {:ok, pin} = ReleaseBootstrap.create(context.source, context.manifest)
      Process.put(:installer_fixture_events, [])
      assert {:error, reason} = run(:install, %{context | pin: pin})
      assert reason =~ "maintenance/recovery"
      refute :start in Process.get(:installer_fixture_events)
      assert File.read!(owner_path) == before
    end

    test "uninstall cancels a claimed partial setup without starting it", context do
      Process.put(:installer_fixture_fail, :group)
      assert {:error, _} = run(:install, context)
      assert phase(context) == "accounts_pending"
      Process.put(:installer_fixture_events, [])
      assert {:ok, %{"phase" => "uninstalled"}} = run(:uninstall, context)
      refute :start in Process.get(:installer_fixture_events)
      refute File.exists?(context.root <> "/var/lib/wotex-home")
      assert {:ok, %{"phase" => "installed"}} = run(:install, context)
    end

    test "a namespace changed after parsing refuses before service registration", context do
      Process.put(:installer_fixture_add_override, true)
      assert {:error, _} = run(:install, context)
      assert phase(context) == "registration_pending"
      refute :start in Process.get(:installer_fixture_events)

      assert File.read!(context.root <> "/usr/lib/systemd/system/wotex-home.service") ==
               "foreign fixture override"
    end

    test "an inconsistent retained phase refuses without changing the original record", context do
      assert {:ok, _} = run(:install, context)
      target = context.root <> "/opt/wotex-home/.installer/state.json"
      invalid = File.read!(target) |> JSON.decode!() |> Map.put("uninstall_from", "installed")
      bytes = JSON.encode!(invalid) <> "\n"
      File.write!(target, bytes)
      Process.put(:installer_fixture_events, [])
      assert {:error, _} = run(:uninstall, context)
      refute :stop in Process.get(:installer_fixture_events)
      assert File.read!(target) == bytes
    end

    test "completed selection drives repeat, uninstall and reinstall without rewriting initial ownership",
         c do
      selected = selected_fixture(c)
      complete_fixture(selected)
      Process.put(:installer_fixture_events, [])

      assert {:ok, %{"artifact_id" => artifact, "phase" => "installed"}} =
               run(:install, selected.target_context)

      assert artifact == selected.target["artifact_id"]
      refute :start in Process.get(:installer_fixture_events)
      data = c.root <> "/var/lib/wotex-home/private-selected-fixture"
      File.write!(data, "retained private fixture state")

      assert {:ok, %{"artifact_id" => ^artifact, "phase" => "uninstalled"}} =
               run(:uninstall, selected.target_context)

      assert File.read!(data) == "retained private fixture state"
      assert File.read!(selected.base <> "/.installer/owner.json") == selected.owner

      assert {:ok, %{"artifact_id" => ^artifact, "phase" => "installed"}} =
               run(:install, selected.target_context)

      assert File.read!(selected.base <> "/.installer/owner.json") == selected.owner
      assert File.read!(data) == "retained private fixture state"
      Process.put(:installer_fixture_events, [])
      assert {:error, _} = run(:uninstall, c)
      assert Process.get(:installer_fixture_events) == []
    end

    test "incomplete or stale completed selection refuses before account, unit or service effects",
         c do
      selected = selected_fixture(c)
      Process.put(:installer_fixture_events, [])

      for context <- [c, selected.target_context], action <- [:install, :uninstall] do
        assert {:error, reason} = run(action, context)
        assert reason =~ "unfinished"
      end

      assert Process.get(:installer_fixture_events) == []
      complete_fixture(selected)

      File.write!(
        selected.base <> "/.installer/current-release.json",
        selected.initial_selection_bytes
      )

      assert {:error, _} = run(:uninstall, selected.target_context)
      assert Process.get(:installer_fixture_events) == []
      assert File.read!(selected.base <> "/.installer/owner.json") == selected.owner
      assert File.read!(c.root <> "/etc/systemd/system/wotex-home.service") == selected.unit
    end

    test "an inventory self-mode change cannot evade the held whole-payload pin", c do
      assert {:ok, _} = run(:install, c)
      owner = JSON.decode!(File.read!(c.root <> "/opt/wotex-home/.installer/owner.json"))
      release = c.root <> "/opt/wotex-home/releases/" <> owner["artifact_id"]
      inventory = release <> "/release-inventory.json"
      mode = Bitwise.band(File.stat!(inventory).mode, 0o777)
      File.chmod!(inventory, if(mode == 0o600, do: 0o644, else: 0o600))
      assert {:ok, _} = LinuxServicePackage.verify(release)
      Process.put(:installer_fixture_events, [])
      assert {:error, reason} = run(:install, c)
      assert reason =~ "whole payload differs"
      assert Process.get(:installer_fixture_events) == []
    end

    defp selected_fixture(c) do
      assert {:ok, _} = run(:install, c)
      base = c.root <> "/opt/wotex-home"
      owner_bytes = File.read!(base <> "/.installer/owner.json")
      owner = JSON.decode!(owner_bytes)

      initial = %{
        "source_revision" => owner["source_revision"],
        "artifact_id" => owner["artifact_id"],
        "bootstrap_sha256" => owner["bootstrap_sha256"],
        "inventory_sha256" =>
          LinuxInstallFiles.digest(
            File.read!(base <> "/releases/" <> owner["artifact_id"] <> "/release-inventory.json")
          )
      }

      {:ok, journal} = LinuxUpdateJournal.new(owner_bytes, initial)
      {:ok, journal_bytes} = LinuxUpdateJournal.persist(base, owner_bytes, journal, nil, @tool)
      {:ok, initial_selection} = LinuxUpdateSelection.new(owner_bytes, journal)

      {:ok, initial_selection_bytes} =
        LinuxUpdateSelection.persist(base, owner_bytes, journal, initial_selection, nil, @tool)

      new_source = Path.dirname(c.root) <> "/target-source"
      File.mkdir!(new_source)
      File.write!(new_source <> "/fixture", "inert selected payload")
      {:ok, report} = LinuxServicePackage.assemble(new_source, String.duplicate("b", 40))
      {:ok, _} = ReleaseInventory.create(new_source, String.duplicate("b", 40))
      File.chmod!(new_source <> "/release-inventory.json", 0o644)
      manifest = Path.dirname(c.root) <> "/target-bootstrap.tsv"
      {:ok, pin} = ReleaseBootstrap.create(new_source, manifest)

      target = %{
        "source_revision" => report["source_revision"],
        "artifact_id" => report["artifact_id"],
        "bootstrap_sha256" => pin,
        "inventory_sha256" =>
          LinuxInstallFiles.digest(File.read!(new_source <> "/release-inventory.json"))
      }

      nonce = F.nonce()
      stage = base <> "/.installer/update-stage-" <> nonce
      :ok = LinuxInstallFiles.mkdir(stage, 0o700, 0, 0, @tool)
      marker = "{\"scope\":\"synthetic_selection_fixture\"}\n"
      :ok = LinuxInstallFiles.write(stage <> "/stage.json", 0o600, marker, nil, @tool)
      :ok = LinuxInstallFiles.bootstrap(new_source, manifest, pin, stage <> "/release", @tool)

      {:ok, %{complete: true} = snapshot} =
        LinuxInstallStage.snapshot(stage, marker, File.read!(manifest), pin)

      :ok =
        LinuxInstallFiles.publish_release(
          stage <> "/release",
          base <> "/releases/" <> target["artifact_id"],
          base <> "/.installer/owner.json",
          owner_bytes,
          marker,
          snapshot.sha256,
          target["inventory_sha256"],
          @tool
        )

      Process.put(:selection_fixture_journal_bytes, journal_bytes)

      checkpoint = fn updated ->
        {:ok, bytes} =
          LinuxUpdateJournal.persist(
            base,
            owner_bytes,
            updated,
            Process.get(:selection_fixture_journal_bytes),
            @tool
          )

        Process.put(:selection_fixture_journal_bytes, bytes)
        updated
      end

      running = F.running(journal, initial, target, nonce, checkpoint)
      # These are administrative phase fixtures. The service callbacks and
      # process/status values are synthetic; only file/lock/CAS effects are real.
      unit_path = c.root <> "/etc/systemd/system/wotex-home.service"

      unit =
        Enum.find_value(LinuxServicePackage.files(target["artifact_id"], 2), fn
          {"etc/systemd/system/wotex-home.service", bytes} -> bytes
          _ -> nil
        end)

      :ok =
        LinuxInstallFiles.write(
          unit_path,
          0o644,
          unit,
          LinuxInstallFiles.digest(File.read!(unit_path)),
          @tool
        )

      {:ok, selection} = LinuxUpdateSelection.select(initial_selection, running, nonce)

      {:ok, _} =
        LinuxUpdateSelection.persist(
          base,
          owner_bytes,
          running,
          selection,
          initial_selection_bytes,
          @tool
        )

      %{
        base: base,
        owner: owner_bytes,
        journal: running,
        nonce: nonce,
        target: target,
        initial_selection_bytes: initial_selection_bytes,
        unit: unit,
        target_context: %{c | source: new_source, manifest: manifest, pin: pin}
      }
    end

    defp complete_fixture(c) do
      {:ok, selected} = LinuxUpdateJournal.advance(c.journal, c.nonce, "selected")

      {:ok, bytes} =
        LinuxUpdateJournal.persist(
          c.base,
          c.owner,
          selected,
          Process.get(:selection_fixture_journal_bytes),
          @tool
        )

      {:ok, complete} = LinuxUpdateJournal.advance(selected, c.nonce, "complete")
      {:ok, _} = LinuxUpdateJournal.persist(c.base, c.owner, complete, bytes, @tool)
    end

    defp run(action, context),
      do:
        LinuxInstaller.run(action, context.source, context.manifest, context.pin, context.options)

    defp phase(context),
      do:
        context.root
        |> Path.join("opt/wotex-home/.installer/state.json")
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("phase")
  end
end
