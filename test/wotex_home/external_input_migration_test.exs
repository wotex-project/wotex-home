defmodule WotexHome.ExternalInputMigrationTest do
  @moduledoc false

  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Backup, Registry, Store}

  alias WotexHome.Durable.Store.{
    EnrollmentWriter,
    Integrity,
    Journal,
    PrincipalWriter,
    RecoverySnapshot,
    Schema,
    SQL
  }

  alias WotexHome.Profiles.Custody
  alias WotexHome.Rules.ExternalInputOperation, as: Operation
  alias WotexHome.Semantics.Thing

  @drop "DROP TABLE routine_external_input_current; DROP TABLE routine_external_input_history; DROP TABLE routine_external_input_operations; PRAGMA user_version=37"

  setup do
    Process.flag(:trap_exit, true)

    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()

    root =
      Path.join(
        temporary,
        "woh-input-history-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, db} = Sqlite3.open(":memory:")
    :ok = Sqlite3.execute(db, "PRAGMA foreign_keys=ON")
    :ok = Schema.initialize(db, &Integrity.validate_schema_version/2)

    on_exit(fn ->
      Sqlite3.close(db)
      File.rm_rf!(root)
    end)

    %{
      db: db,
      root: root,
      key: :crypto.strong_rand_bytes(32),
      v: JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    }
  end

  test "fresh schema 38 has the exact object inventory and creates no input authority", c do
    assert 38 = Schema.current_version()
    assert {:ok, [[38]]} = SQL.query(c.db, "PRAGMA user_version")

    assert {:ok, [[62]]} =
             SQL.query(
               c.db,
               "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*'"
             )

    assert {:ok, [[68]]} =
             SQL.query(c.db, "SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'")

    assert {:ok, [[0, 0, 0]]} =
             SQL.query(
               c.db,
               "SELECT (SELECT COUNT(*) FROM routine_external_input_operations),(SELECT COUNT(*) FROM routine_external_input_history),(SELECT COUNT(*) FROM routine_external_input_current)"
             )

    assert :ok = Integrity.validate_snapshot(c.db)
  end

  test "actual schema 37 migrates empty inputs without changing rows, revisions or v1 retained hashes",
       c do
    principal(c.db, "retained:actor")
    assert :ok = Sqlite3.execute(c.db, @drop)
    assert :ok = Integrity.validate_snapshot(c.db)
    before = retained(c.db)
    assert {:ok, hash} = RecoverySnapshot.retained_commitment(c.db, 1, "fresh:actor")
    old = Path.join(c.root, "old.backup")
    assert {:ok, _} = Backup.export(c.db, old, c.key)
    assert {:ok, verified} = Backup.verify(old, c.key)
    assert_input_counts(verified.dependencies, [0, 0, 0, 0])
    refute verified.dependencies.reviewer_keys_required
    assert :ok = Schema.initialize(c.db, &Integrity.validate_schema_version/2)
    assert {:ok, [[38]]} = SQL.query(c.db, "PRAGMA user_version")
    assert retained(c.db) == before
    assert {:ok, ^hash} = RecoverySnapshot.retained_commitment(c.db, 1, "fresh:actor")
    assert :ok = Integrity.validate_snapshot(c.db)

    fresh = Path.join(c.root, "new.backup")
    assert {:ok, _} = Backup.export(c.db, fresh, c.key)
    assert {:ok, verified} = Backup.verify(fresh, c.key)
    assert_input_counts(verified.dependencies, [0, 0, 0, 0])
    destination = Path.join(c.root, "restored.sqlite")
    assert {:ok, _} = Backup.stage_restore(fresh, c.key, destination)
    {:ok, staged} = Sqlite3.open(destination)

    try do
      assert {:ok, [[38]]} = SQL.query(staged, "PRAGMA user_version")

      assert {:ok, [[1]]} =
               SQL.query(staged, "SELECT value FROM meta WHERE key='restore_quarantine'")

      assert :ok = Integrity.validate_snapshot(staged)
    after
      Sqlite3.close(staged)
    end

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: destination)

    assert {:ok, _} = Backup.verify(old, c.key)
  end

  test "DDL publication failure rolls back new tables and the schema number", c do
    principal(c.db, "retained:actor")
    assert :ok = Sqlite3.execute(c.db, @drop)
    before = retained(c.db)

    assert :ok =
             Sqlite3.execute(c.db, "CREATE TABLE routine_external_input_history(collision TEXT)")

    assert {:error, _} = Schema.initialize(c.db, &Integrity.validate_schema_version/2)
    assert {:ok, [[37]]} = SQL.query(c.db, "PRAGMA user_version")
    assert retained(c.db) == before

    assert {:ok, [["routine_external_input_history"]]} =
             SQL.query(
               c.db,
               "SELECT name FROM sqlite_master WHERE name GLOB 'routine_external_input_*'"
             )
  end

  test "new semantic validation fails inside migration and rolls back every new object", c do
    assert :ok = Sqlite3.execute(c.db, @drop)
    assert :ok = Journal.authority_event(c.db, 1, "external_input_installed", "unexplained")
    assert :ok = Integrity.validate_snapshot(c.db)
    before = retained(c.db)

    assert {:error, {:schema_failed, {:error, :corrupt_external_inputs}}} =
             Schema.initialize(c.db, &Integrity.validate_schema_version/2)

    assert {:ok, [[37]]} = SQL.query(c.db, "PRAGMA user_version")
    assert retained(c.db) == before

    assert {:ok, [[0]]} =
             SQL.query(
               c.db,
               "SELECT COUNT(*) FROM sqlite_master WHERE name GLOB 'routine_external_input_*'"
             )
  end

  test "startup and every Store write fence even empty-domain DDL corruption", c do
    path = Path.join(c.root, "live.sqlite")
    store = start_supervised!({Store, path: path}, id: :live)

    :sys.replace_state(store, fn state ->
      :ok =
        Sqlite3.execute(
          state.db,
          "ALTER TABLE routine_external_input_history ADD COLUMN substituted TEXT"
        )

      state
    end)

    assert {:error, :corrupt_external_inputs} =
             Store.provision_principal(store, "actor:late", ["read"], [])

    assert {:ok, %{writable: false, store_revision: 0}} = Store.health(store)
    stop_supervised!(:live)
    assert {:error, {:store_open_failed, :corrupt_external_inputs}} = Store.start_link(path: path)
  end

  test "encrypted database and inclusive archives retain input originals with explicit non-reactivation",
       c do
    history_parents(c.db)
    install(c)
    assert :ok = Integrity.validate_snapshot(c.db)
    profiles = Path.join(c.root, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o700)
    custody = start_supervised!({Custody, root: profiles, store_owner: self()})

    for {name, exporter} <- [
          {"database", fn path -> Backup.export(c.db, path, c.key) end},
          {"inclusive", fn path -> Backup.export_profiles(c.db, path, c.key, custody) end}
        ] do
      path = Path.join(c.root, name <> ".backup")
      assert {:ok, _} = exporter.(path)
      assert {:ok, verified} = Backup.verify(path, c.key)
      assert_input_counts(verified.dependencies, [1, 1, 1, 1])
      assert verified.dependencies.reviewer_keys_required
      target = Path.join(c.root, name <> ".sqlite")

      target =
        if name == "inclusive" do
          assert {:error, :profile_restore_required} = Backup.stage_restore(path, c.key, target)
          destination = Path.join(c.root, "inclusive-restored")
          assert {:ok, _} = Backup.stage_profile_restore(path, c.key, destination)
          Path.join(destination, "home.sqlite")
        else
          assert {:ok, _} = Backup.stage_restore(path, c.key, target)
          target
        end

      {:ok, copy} = Sqlite3.open(target)

      try do
        assert {:ok, [[c.v["receipt_document"]]]} ==
                 SQL.query(copy, "SELECT receipt_document FROM routine_external_input_operations")

        assert :ok = Integrity.validate_snapshot(copy)

        assert {:error, {:store_open_failed, :restore_requires_transfer}} =
                 Store.start_link(path: target)

        assert {:ok, []} =
                 SQL.query(
                   copy,
                   "UPDATE routine_external_input_history SET outcome_document='[]'"
                 )

        assert {:error, :corrupt_external_inputs} = Integrity.validate_snapshot(copy)
      after
        Sqlite3.close(copy)
      end
    end
  end

  test "normalized retention omits future input history and reconstructs source-revision heads",
       c do
    history_parents(c.db)
    assert {:ok, empty} = RecoverySnapshot.retained_commitment(c.db, 20, "fresh:actor")
    install(c)
    assert {:ok, ^empty} = RecoverySnapshot.retained_commitment(c.db, 20, "fresh:actor")
    assert {:ok, source} = RecoverySnapshot.retained_commitment(c.db, 21, "fresh:actor")
    revoke(c)
    assert :ok = Integrity.validate_snapshot(c.db)
    assert {:ok, ^source} = RecoverySnapshot.retained_commitment(c.db, 21, "fresh:actor")
    assert {:ok, later} = RecoverySnapshot.retained_commitment(c.db, 22, "fresh:actor")
    refute later == source

    assert {:ok, [[22, 21, 2, "revoked"]]} =
             SQL.query(
               c.db,
               "SELECT history_revision,install_revision,generation,state FROM routine_external_input_current"
             )

    path = Path.join(c.root, "revoked.backup")
    assert {:ok, _} = Backup.export(c.db, path, c.key)
    assert {:ok, verified} = Backup.verify(path, c.key)
    assert_input_counts(verified.dependencies, [2, 2, 1, 0])
  end

  defp principal(db, id) do
    {:ok, {:ok, nil, revision}} =
      SQL.transaction(
        db,
        &PrincipalWriter.provision_principal_tx(
          &1,
          id,
          :crypto.hash(:sha256, id),
          "[\"read\"]",
          [],
          nil
        )
      )

    revision
  end

  # A structurally retained package in an unqualified legacy registry proves
  # archive/history mechanics only. It has no current external target/source,
  # trusted runtime/reviewer basis or live report and is never admitted for use.
  defp history_parents(db) do
    capability = %{
      "thing_id" => "sensor:independent",
      "role" => "Light",
      "key" => "power",
      "value_kind" => "boolean",
      "unit" => "none",
      "operations" => ["read", "write"],
      "risk_class" => "ordinary",
      "profile_ref" => "synthetic:archive",
      "evidence_ref" => "fixture:archive",
      "freshness_ms" => 1000,
      "constraints" => %{},
      "extensions" => %{}
    }

    {:ok, thing} =
      Thing.new(%{
        "id" => "sensor:independent",
        "role" => "Light",
        "profile_ref" => "synthetic:archive",
        "capabilities" => [capability]
      })

    {:ok, document} = Registry.encode_thing(thing)

    assert {:ok, {:ok, 1}} =
             SQL.transaction(db, &EnrollmentWriter.enroll_thing_tx(&1, thing, document))

    assert 2 = principal(db, "operator:entry")
    for revision <- 3..20, do: assert(^revision = principal(db, "fixture:#{revision}"))
    assert :ok = Integrity.validate_snapshot(db)
  end

  defp install(c) do
    assert :ok =
             Journal.authority_event(c.db, 21, "external_input_installed", "sensor:independent")

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO routine_external_input_operations VALUES ('operator:entry',1,'install:entry',?,?,?,21)",
               [c.v["change_document"], c.v["outcome_document"], c.v["receipt_document"]]
             )

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO routine_external_input_history VALUES ('sensor:independent','sample',21,1,'install',NULL,?)",
               [c.v["outcome_document"]]
             )

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO routine_external_input_current VALUES ('sensor:independent','sample',21,21,1,'installed')"
             )
  end

  defp revoke(c) do
    input =
      Map.merge(c.v["change"], %{
        "operation_id" => "revoke:later",
        "action" => "revoke",
        "package_document" => nil,
        "expected_install_revision" => 21,
        "expected_generation" => 1
      })

    {:ok, id} = Operation.encode(input)
    {:ok, od} = Operation.encode_outcome(Map.put(c.v["outcome"], "action", "revoke"))

    r =
      Map.merge(c.v["receipt"], %{
        "operation_id" => "revoke:later",
        "action" => "revoke",
        "revision" => 22,
        "generation" => 2,
        "input_sha256" => Operation.input_sha256(id),
        "outcome_sha256" => Operation.outcome_sha256(od)
      })

    {:ok, rd} = Operation.encode_receipt(r)
    assert :ok = Journal.authority_event(c.db, 22, "external_input_revoked", "sensor:independent")

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO routine_external_input_operations VALUES ('operator:entry',1,'revoke:later',?,?,?,22)",
               [id, od, rd]
             )

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO routine_external_input_history VALUES ('sensor:independent','sample',22,2,'revoke',NULL,?)",
               [od]
             )

    assert {:ok, []} =
             SQL.query(
               c.db,
               "UPDATE routine_external_input_current SET history_revision=22,generation=2,state='revoked'"
             )
  end

  defp retained(db) do
    for table <- ~w(meta principals authority_journal), into: %{} do
      {:ok, rows} = SQL.query(db, "SELECT * FROM #{table} ORDER BY 1")
      {table, rows}
    end
  end

  defp assert_input_counts(dependencies, expected) do
    assert [
             dependencies.external_input_operation_rows,
             dependencies.external_input_history_rows,
             dependencies.external_input_current_rows,
             dependencies.external_input_installed_rows
           ] == expected

    refute dependencies.external_inputs_reactivate
  end
end
