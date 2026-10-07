defmodule WotexHome.RetiredSourceDeliveryTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.{Authority, Host, Recovery}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Profiles.{Artifact, Custody}
  alias WotexHome.Recovery.Source
  @store __MODULE__.Store
  @custody __MODULE__.Custody

  setup do
    Process.flag(:trap_exit, true)
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    directory = Path.join(temporary, "woh-source-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    root = Path.join(directory, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")

    store =
      start_supervised!(
        Supervisor.child_spec({Store, path: path, name: @store, profile_custody: @custody},
          restart: :temporary
        )
      )

    custody = start_supervised!({Custody, root: root, name: @custody, store_owner: store})
    authority = Authority.new(store: store, profile_custody: custody)
    {:ok, transfer, 1} = Authority.provision_transfer(authority)
    {:ok, maintainer, 2} = Authority.provision_maintenance(authority)
    {:ok, manager, 3} = Authority.provision_profile_manager(authority)
    bytes = File.read!(Path.expand("../../priv/profiles/lifx-power-example.json", __DIR__))
    {:ok, digest} = Authority.stage_profile(authority, manager, bytes)
    {:ok, barrier} = Authority.begin_maintenance(authority, maintainer, 1, "maint:original", 3)

    {:ok, approval} =
      Authority.profile_change(authority, manager, %{
        "action" => "approve",
        "authority_epoch" => 1,
        "operation_id" => "approve:original",
        "expected_revision" => barrier.revision,
        "artifact_digest" => digest,
        "expected_trust_revision" => 0
      })

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "retire:original",
      "expected_revision" => approval.final_revision,
      "destination_owner_id" => String.duplicate("a", 64)
    }

    %{
      directory: directory,
      path: path,
      root: root,
      store: store,
      custody: custody,
      authority: authority,
      transfer: transfer,
      bytes: bytes,
      digest: digest,
      input: input,
      archive: Path.join(directory, "retired.woh"),
      key: :crypto.strong_rand_bytes(32)
    }
  end

  test "offline reader retains exact profile bytes, original receipt and default-disabled state",
       c do
    {:ok, receipt} = Authority.retire_controller(c.authority, c.transfer, c.input)
    close_source()
    assert {:ok, reader} = Source.start_link(c.directory)

    assert Enum.map(Supervisor.which_children(reader), &elem(&1, 0)) |> Enum.sort() ==
             Enum.sort([Store, Custody])

    assert {:ok, authority} = Source.authority(reader)

    assert {:ok, %{writable: false, dispatch_enabled: false}} =
             Store.health(Authority.owner(authority))

    assert {:ok, ^receipt} =
             Authority.retirement_status(authority, c.transfer, 1, "retire:original")

    assert {:ok, ^receipt} = Authority.retire_controller(authority, c.transfer, c.input)
    assert {:error, :source_retired} = Authority.provision_diagnostic(authority)

    assert {:error, :source_retired} =
             Store.collect_profiles(Authority.owner(authority), c.transfer)

    assert {:ok, summary} = Authority.export_retired_profile_backup(authority, c.archive, c.key)
    assert summary.portable_profile_objects == 1
    assert summary.bytes == File.stat!(c.archive).size
    assert summary.archive_digest == Artifact.digest(File.read!(c.archive))
    assert {:ok, ^summary} = Authority.export_retired_profile_backup(authority, c.archive, c.key)
    assert {:ok, ^summary} = Backup.verify_retired_source(c.archive, c.key, receipt)

    assert {:error, :retired_archive_mismatch} =
             Backup.verify_retired_source(c.archive, c.key, %{
               receipt
               | "destination_owner_id" => String.duplicate("b", 64)
             })

    assert {:error, :invalid_backup} =
             Authority.export_retired_profile_backup(
               authority,
               c.archive,
               :binary.copy(<<0>>, 32)
             )

    assert Host.store() == nil
    refute File.exists?(Path.join(c.directory, "ipc/home.sock"))
    :ok = Supervisor.stop(reader)
    assert Process.whereis(Source.Store) == nil and Process.whereis(Source.Custody) == nil
    assert {:ok, ^summary} = Recovery.run(["export-retired", c.directory, c.archive], line(c.key))
    assert Process.whereis(Source.Store) == nil and Process.whereis(Source.Custody) == nil
    quarantine = Path.join(c.directory, "quarantine")
    assert {:ok, _} = Backup.stage_profile_restore(c.archive, c.key, quarantine)
    assert File.read!(Path.join([quarantine, "profiles", c.digest <> ".json"])) == c.bytes

    assert {:error, :retired_source_unavailable} =
             Authority.export_retired_directory(
               quarantine,
               Path.join(c.directory, "forbidden.woh"),
               c.key
             )
  end

  test "a normal source is refused without migration, new grants or archive publication", c do
    close_source()

    assert {:error, :retired_source_unavailable} =
             Authority.export_retired_directory(c.directory, c.archive, c.key)

    refute File.exists?(c.archive)
    {:ok, db} = Sqlite3.open(c.path)

    assert {:ok, [["active", 0]]} =
             SQL.query(db, "SELECT state,head_revision FROM controller_identity")

    assert {:ok, [[c.input["expected_revision"]]]} ==
             SQL.query(db, "SELECT value FROM meta WHERE key='revision'")

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "active writer, substituted roots and missing retained bytes cannot export", c do
    {:ok, _} = Authority.retire_controller(c.authority, c.transfer, c.input)

    assert {:error, :retired_source_unavailable} =
             Authority.export_retired_directory(c.directory, c.archive, c.key)

    assert {:ok, %{writable: false}} = Store.health(c.store)
    close_source()
    alias_root = Path.join(c.directory, "alias")
    File.ln_s!(c.directory, alias_root)

    assert {:error, :invalid_retired_source} =
             Authority.export_retired_directory(alias_root, c.archive, c.key)

    File.rm!(Path.join(c.root, c.digest <> ".json"))

    assert {:error, :profile_artifact_unavailable} =
             Authority.export_retired_directory(c.directory, c.archive, c.key)

    refute File.exists?(c.archive)
    assert Process.whereis(Source.Store) == nil and Process.whereis(Source.Custody) == nil
  end

  test "an unrelated authenticated archive cannot replace the original source export", c do
    assert {:ok, _} = Store.export_profile_backup(c.store, c.archive, c.key)
    {:ok, _} = Authority.retire_controller(c.authority, c.transfer, c.input)
    original = File.read!(c.archive)

    assert {:error, :retired_archive_mismatch} =
             Authority.export_retired_profile_backup(c.authority, c.archive, c.key)

    assert File.read!(c.archive) == original
    assert {:ok, %{state: "retired"}} = Authority.controller_status(c.authority, c.transfer)
  end

  @tag :requires_socket
  test "owning application supervisor stops only the verified retired Host after exact export",
       c do
    close_source()
    isolate_host_configuration()
    assert Host.store() == nil

    assert {:ok, host} =
             Supervisor.start_child(WotexHome.Supervisor, {Host, data_dir: c.directory})

    on_exit(fn ->
      _ = Supervisor.terminate_child(WotexHome.Supervisor, Host)
      _ = Supervisor.delete_child(WotexHome.Supervisor, Host)
    end)

    monitor = Process.monitor(host)
    assert {:ok, encoded} = WotexHome.Bootstrap.issue_diagnostic_credential()
    assert byte_size(encoded) == 43
    {:ok, revision} = Store.revision(Host.store())

    args = [
      "retire-export",
      "1",
      "retire:original",
      Integer.to_string(revision),
      c.input["destination_owner_id"],
      c.archive
    ]

    assert {:error, :invalid_retirement_request} = Recovery.run(args, line(c.key))

    assert {:error, :invalid_retirement_request} =
             Recovery.run(
               List.replace_at(args, 5, "relative.woh"),
               line(c.transfer) <> line(c.key)
             )

    assert {:ok, %{state: "active", store_revision: ^revision}} =
             Authority.controller_status(Host.authority(), c.transfer)

    assert {:ok, summary} = Recovery.run(args, line(c.transfer) <> line(c.key))
    assert summary.source_stopped == true and summary.portable_profile_objects == 1
    assert_receive {:DOWN, ^monitor, :process, ^host, :shutdown}, 5_000
    assert Host.store() == nil
    refute File.exists?(Path.join(c.directory, "ipc/home.sock"))
    assert {:ok, %{store_revision: source_revision}} = Backup.verify(c.archive, c.key)
    assert source_revision == revision + 1
    assert {:ok, retry} = Recovery.run(["export-retired", c.directory, c.archive], line(c.key))
    assert retry.archive_digest == summary.archive_digest
  end

  @tag :requires_socket
  test "actual foreground retirement and offline source scripts keep both stdin secrets private",
       c do
    close_source()

    startup = """
    Logger.configure(level: :error)
    System.delete_env("WOTEX_HOME_LIFX_INTERFACE")
    Application.delete_env(:wotex_home, :lifx_capture_interface)
    Application.delete_env(:wotex_home, :component_preview)
    Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, false)
    {:ok, _} = Application.ensure_all_started(:wotex_home)
    Code.require_file("bin/recovery.exs")
    """

    environment = [
      {"WOTEX_HOME_DATA_DIR", c.directory},
      {"WOTEX_HOME_GIT_DEPS", "1"},
      {"MIX_ENV", "test"}
    ]

    args = [
      "retire-export",
      "1",
      "retire:original",
      Integer.to_string(c.input["expected_revision"]),
      c.input["destination_owner_id"],
      c.archive
    ]

    assert {:ok, retired} =
             Woh.Tool.Command.run(
               "mix",
               ["run", "--no-start", "-e", startup, "--"] ++ args,
               65_536,
               30_000,
               environment,
               line(c.transfer) <> line(c.key)
             )

    assert {:ok, %{"source_stopped" => true, "portable_profile_objects" => 1}} =
             JSON.decode(String.trim(retired))

    assert {:ok, exported} =
             Woh.Tool.Command.run(
               "mix",
               [
                 "run",
                 "--no-start",
                 "bin/recovery.exs",
                 "export-retired",
                 c.directory,
                 c.archive
               ],
               65_536,
               30_000,
               environment,
               line(c.key)
             )

    assert {:ok, %{"portable_profile_objects" => 1}} = JSON.decode(String.trim(exported))
    refute retired <> exported =~ String.trim(line(c.key))
    refute retired <> exported =~ String.trim(line(c.transfer))
    refute File.exists?(Path.join(c.directory, "ipc/home.sock"))
    assert {:ok, _} = Backup.verify(c.archive, c.key)
  end

  test "failed source publication preserves retirement and exact retry after offline reopen", c do
    {:ok, receipt} = Authority.retire_controller(c.authority, c.transfer, c.input)

    assert {:error, _} =
             Authority.export_retired_profile_backup(
               c.authority,
               Path.join(c.directory, "absent/new.woh"),
               c.key
             )

    assert {:ok, ^receipt} =
             Authority.retirement_status(c.authority, c.transfer, 1, "retire:original")

    close_source()
    assert {:ok, summary} = Recovery.run(["export-retired", c.directory, c.archive], line(c.key))
    assert {:ok, ^summary} = Backup.verify_retired_source(c.archive, c.key, receipt)
    assert Process.whereis(Source.Store) == nil and Process.whereis(Source.Custody) == nil
  end

  defp close_source do
    stop_supervised!(Custody)
    stop_supervised!(Store)
  end

  defp isolate_host_configuration do
    options = [:lifx_capture_interface, :component_preview, :lifx_power_dispatch_enabled]
    saved = Enum.map(options, &{&1, Application.fetch_env(:wotex_home, &1)})
    interface = System.get_env("WOTEX_HOME_LIFX_INTERFACE")
    System.delete_env("WOTEX_HOME_LIFX_INTERFACE")
    Application.delete_env(:wotex_home, :lifx_capture_interface)
    Application.delete_env(:wotex_home, :component_preview)
    Application.put_env(:wotex_home, :lifx_power_dispatch_enabled, false)

    on_exit(fn ->
      Enum.each(saved, fn {option, previous} ->
        case previous do
          {:ok, value} -> Application.put_env(:wotex_home, option, value)
          :error -> Application.delete_env(:wotex_home, option)
        end
      end)

      if interface,
        do: System.put_env("WOTEX_HOME_LIFX_INTERFACE", interface),
        else: System.delete_env("WOTEX_HOME_LIFX_INTERFACE")
    end)
  end

  defp line(bytes), do: Base.url_encode64(bytes, padding: false) <> "\n"
end
