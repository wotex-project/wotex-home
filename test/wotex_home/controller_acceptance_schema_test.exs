Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.ControllerAcceptanceSchemaTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{ControllerWriter, Integrity, RecoverySnapshot, Schema, SQL}

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-accept-schema-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    authority = Authority.new(store: store)
    {:ok, transfer, 1} = Authority.provision_transfer(authority)
    {:ok, maintainer, 2} = Authority.provision_maintenance(authority)
    {:ok, barrier} = Store.begin_maintenance(store, maintainer, 1, "maint:source", 2)

    %{
      root: root,
      path: path,
      store: store,
      transfer: transfer,
      maintainer: maintainer,
      barrier: barrier,
      key: :crypto.strong_rand_bytes(32)
    }
  end

  test "active historical schema twenty one migrates without changing retained authority", c do
    before = with_db(c.path, &retained/1)
    :ok = GenServer.stop(c.store)
    downgrade(c.path)
    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
    store = start_supervised!({Store, path: c.path}, id: :migrated)

    assert {:ok,
            %{
              authority_epoch: 1,
              store_revision: revision,
              rule_generation: 1,
              dispatch_enabled: false
            }} = Store.health(store)

    assert revision == c.barrier.revision

    assert {:ok, %{begin_revision: revision, state: :maintenance}} =
             Store.maintenance_status(store, c.maintainer)

    assert revision == c.barrier.revision

    with_db(c.path, fn db ->
      assert before == retained(db)
      assert {:ok, [[22]]} = SQL.query(db, "PRAGMA user_version")
      assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM controller_acceptances")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "retired historical source is refused before migration and readonly export stays historical",
       c do
    retire(c)
    :ok = GenServer.stop(c.store)
    downgrade(c.path)

    before =
      with_db(c.path, fn db ->
        assert {:ok, digest} = RecoverySnapshot.commitment(db, :source)
        {digest, retained(db)}
      end)

    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, :source_retired}} = Store.start_link(path: c.path)

    with_db(c.path, fn db ->
      assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name='controller_acceptances'"
               )

      assert {:ok, digest} = RecoverySnapshot.commitment(db, :source)
      assert {digest, retained(db)} == before

      assert {:error, {:schema_failed, {:error, :source_retired}}} =
               Schema.initialize(db, &Integrity.validate_schema_version/2)

      assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version")
    end)

    source =
      start_supervised!({Store, path: c.path, controller_mode: :retired_readonly}, id: :reader)

    archive = Path.join(c.root, "historical.woh")
    assert {:ok, _} = Store.export_profile_backup(source, archive, c.key)
    assert {:ok, %{authority_epoch: 1, store_revision: revision}} = Backup.verify(archive, c.key)
    assert revision == c.barrier.revision + 1
    with_db(c.path, fn db -> assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version") end)
  end

  test "quarantine schema installation rolls back with the outer acceptance transaction", c do
    retire(c)
    :ok = GenServer.stop(c.store)
    downgrade(c.path)
    archive = Path.join(c.root, "historical.woh")
    with_db(c.path, fn db -> assert {:ok, _} = Backup.export(db, archive, c.key) end)
    destination = Path.join(c.root, "staged.sqlite")
    assert {:ok, _} = Backup.stage_restore(archive, c.key, destination)

    with_db(destination, fn db ->
      assert {:ok, before} = RecoverySnapshot.commitment(db, :quarantine)

      assert {:error, :injected_acceptance_failure} =
               SQL.transaction(db, fn db ->
                 assert :ok = Schema.install_transfer_schema_tx(db)
                 assert {:ok, [[22]]} = SQL.query(db, "PRAGMA user_version")

                 assert {:ok, [[0]]} =
                          SQL.query(db, "SELECT COUNT(*) FROM controller_acceptances")

                 {:rollback, :injected_acceptance_failure}
               end)

      assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version")
      assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name='controller_acceptances'"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "schema installation requires exact retired quarantine and cannot make it active", c do
    with_db(c.path, fn db ->
      assert {:error, :invalid_transfer_snapshot} = Schema.install_transfer_schema_tx(db)
    end)

    retire(c)

    with_db(c.path, fn db ->
      assert {:error, :invalid_transfer_snapshot} = Schema.install_transfer_schema_tx(db)
      assert {:ok, %{state: "retired"}} = ControllerWriter.identity(db)
    end)
  end

  test "schema twenty two rejects unmatched destination journals and corrupted ownership heads",
       c do
    for statement <- [
          "INSERT INTO authority_journal VALUES (5,'controller_destination_accepted','controller:forged'); UPDATE meta SET value=5 WHERE key='revision'",
          "UPDATE controller_identity SET head_revision=1",
          "UPDATE controller_identity SET state='retired'",
          "UPDATE meta SET value=2 WHERE key='authority_epoch'"
        ] do
      with_db(c.path, fn db ->
        assert {:error, :fixture_rollback} =
                 SQL.transaction(db, fn db ->
                   assert :ok = Sqlite3.execute(db, statement)
                   assert {:error, _} = Integrity.validate_snapshot(db)
                   {:rollback, :fixture_rollback}
                 end)

        assert :ok = Integrity.validate_snapshot(db)
      end)
    end
  end

  defp retire(c) do
    assert {:ok, _} =
             Store.retire_controller(c.store, c.transfer, %{
               "authority_epoch" => 1,
               "operation_id" => "retire:source",
               "expected_revision" => c.barrier.revision,
               "destination_owner_id" => String.duplicate("a", 64)
             })
  end

  defp downgrade(path) do
    with_db(path, fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 WotexHome.Test.SchemaFixtures.drop_transfer_acceptance() <>
                   "PRAGMA user_version=21"
               )
    end)
  end

  defp retained(db) do
    for table <-
          ~w(meta controller_identity controller_retirements principals principal_targets authority_journal host_maintenance_operations) do
      {:ok, rows} = SQL.query(db, "SELECT * FROM #{table} ORDER BY 1")
      {table, rows}
    end
  end

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end
end
