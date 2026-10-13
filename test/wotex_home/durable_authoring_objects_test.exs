defmodule WotexHome.DurableAuthoringObjectsTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Profiles.{AuthoringImport, AuthoringObject, Custody}
  alias Exqlite.Sqlite3
  @store __MODULE__.Store

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("home-authoring-journal-#{System.unique_integer([:positive])}")
      |> Path.expand()

    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    custody_root = Path.join(root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @store})
    path = Path.join(root, "home.sqlite")
    store = start_supervised!({Store, path: path, profile_custody: custody, name: @store})
    {:ok, credential, 1} = Store.provision_principal(store, "author:1", ["profile:manage"], [])
    {:ok, reader, 2} = Store.provision_principal(store, "reader:1", ["read"], [])

    %{
      root: root,
      custody: custody,
      path: path,
      store: store,
      credential: credential,
      reader: reader,
      authority: Authority.new(store: store, profile_custody: custody)
    }
  end

  defp input(_c, operation, payload, revision) do
    {:ok, object} = AuthoringObject.new("source", payload)
    {:ok, summary} = AuthoringObject.summary(object)

    %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => revision,
      "object" => summary
    }
  end

  test "exact originals preserve ownership and receipts across missing bytes and restart", c do
    data = input(c, "import:1", "original", 2)

    assert {:ok, receipt} =
             Authority.import_authoring_object(c.authority, c.credential, data, "original")

    assert receipt == AuthoringImport.receipt(data, 3, 3)

    assert {:ok, ^receipt} =
             Authority.import_authoring_object(c.authority, c.credential, data, nil)

    assert {:ok, ^receipt} =
             Authority.authoring_object_status(c.authority, c.credential, 1, "import:1")

    assert {:error, :authoring_operation_conflict} =
             Authority.import_authoring_object(
               c.authority,
               c.credential,
               Map.put(data, "expected_revision", 3),
               "original"
             )

    assert {:ok, 3} = Store.revision(c.store)
    File.rm!(Path.join([c.root, "profiles", data["object"]["object_digest"] <> ".json"]))

    assert {:ok, ^receipt} =
             Authority.import_authoring_object(c.authority, c.credential, data, nil)

    stop_supervised(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @store})
    assert {:ok, ^receipt} = Store.authoring_object_status(store, c.credential, 1, "import:1")
    assert :not_found = Store.authoring_object_status(store, c.credential, 1, "absent")
  end

  test "current permission/CAS and proof of exact bytes precede durable ownership", c do
    data = input(c, "import:1", "original", 2)

    assert {:error, :permission_denied} =
             Store.import_authoring_object(c.store, c.reader, data, "original")

    assert {:error, :resnapshot_required} =
             Store.import_authoring_object(
               c.store,
               c.credential,
               Map.put(data, "expected_revision", 0),
               "original"
             )

    assert {:error, :stale_authority_epoch} =
             Store.import_authoring_object(
               c.store,
               c.credential,
               Map.put(data, "authority_epoch", 2),
               "original"
             )

    assert {:error, :invalid_authoring_import} =
             Store.import_authoring_object(c.store, c.credential, data, "other")

    assert {:ok, %{object_count: 0}} = Custody.inventory(c.custody)
    assert {:ok, first} = Store.import_authoring_object(c.store, c.credential, data, "original")
    second = Map.merge(data, %{"operation_id" => "import:2", "expected_revision" => 3})

    assert {:ok, receipt} =
             Store.import_authoring_object(c.store, c.credential, second, "original")

    assert receipt["first_revision"] == first["first_revision"]
    assert receipt["revision"] == 4
    assert {:ok, 5} = Store.revoke_principal(c.store, "author:1")

    assert {:error, :unauthorized} =
             Store.import_authoring_object(c.store, c.credential, data, nil)

    assert {:error, :unauthorized} =
             Store.authoring_object_status(c.store, c.credential, 1, "import:1")
  end

  test "a transaction failure rolls back ownership, original and revision while an inert orphan remains",
       c do
    state = :sys.get_state(c.store)

    :ok =
      Sqlite3.execute(
        state.db,
        "CREATE TEMP TRIGGER refuse_authoring_operation BEFORE INSERT ON profile_authoring_object_operations BEGIN SELECT RAISE(ABORT,'fixture'); END"
      )

    data = input(c, "import:1", "original", 2)

    assert {:error, :store_unavailable} =
             Store.import_authoring_object(c.store, c.credential, data, "original")

    assert {:ok, [[0]]} = SQL.query(state.db, "SELECT COUNT(*) FROM profile_authoring_objects")

    assert {:ok, [[0]]} =
             SQL.query(state.db, "SELECT COUNT(*) FROM profile_authoring_object_operations")

    assert {:ok, [[2]]} = SQL.query(state.db, "SELECT value FROM meta WHERE key='revision'")

    assert {:ok, [[0]]} =
             SQL.query(
               state.db,
               "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_object_imported'"
             )

    assert {:ok, %{object_count: 1, lease_count: 0}} = Custody.inventory(c.custody)
    assert :ok = Integrity.validate_snapshot(state.db)
  end

  test "changed journal/receipt links fail integrity and fence subsequent writes", c do
    data = input(c, "import:1", "original", 2)
    assert {:ok, _} = Store.import_authoring_object(c.store, c.credential, data, "original")
    state = :sys.get_state(c.store)

    {:ok, []} =
      SQL.query(state.db, "UPDATE authority_journal SET entity_id='different' WHERE revision=3")

    assert {:error, :corrupt_authoring_objects} = Integrity.validate_snapshot(state.db)

    assert {:error, :corrupt_authoring_objects} =
             Store.authoring_object_status(c.store, c.credential, 1, "import:1")

    assert {:error, :store_unavailable} =
             Store.import_authoring_object(
               c.store,
               c.credential,
               Map.put(data, "operation_id", "import:2"),
               "original"
             )
  end

  test "inclusive backup retains exact source objects while database-only restore stays quarantined",
       c do
    data = input(c, "import:1", "private original", 2)

    assert {:ok, receipt} =
             Store.import_authoring_object(c.store, c.credential, data, "private original")

    key = :crypto.strong_rand_bytes(32)
    complete = Path.join(c.root, "complete.backup")
    assert {:ok, %{authoring_objects: 1}} = Store.export_profile_backup(c.store, complete, key)
    assert <<"WOHBK3", 0, _::binary>> = File.read!(complete)
    assert {:ok, report} = Backup.verify(complete, key)
    assert report.dependencies.authoring_bytes_included
    assert report.dependencies.authoring_objects == [data["object"]]
    target = Path.join(c.root, "restored")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(complete, key, target)
    source = Path.join([target, "profiles", data["object"]["object_digest"] <> ".json"])
    assert {:ok, %{payload: "private original"}} = AuthoringObject.parse(File.read!(source))
    assert {:ok, restored} = Sqlite3.open(Path.join(target, "home.sqlite"))
    assert :ok = Integrity.validate_snapshot(restored)

    assert {:ok, [[document]]} =
             SQL.query(
               restored,
               "SELECT receipt_document FROM profile_authoring_object_operations"
             )

    assert {:ok, ^receipt} = AuthoringImport.decode_receipt(document)
    Sqlite3.close(restored)
    database = Path.join(c.root, "database.backup")
    assert {:ok, _} = Store.export_backup(c.store, database, key)
    assert {:ok, report} = Backup.verify(database, key)
    refute report.dependencies.authoring_bytes_included

    assert {:ok, %{quarantined: true}} =
             Backup.stage_restore(database, key, Path.join(c.root, "database.sqlite"))

    assert {:error, :profile_bytes_missing} =
             Backup.stage_profile_restore(database, key, Path.join(c.root, "incomplete"))

    File.rm!(Path.join([c.root, "profiles", data["object"]["object_digest"] <> ".json"]))

    assert {:error, :authoring_object_unavailable} =
             Store.export_profile_backup(c.store, Path.join(c.root, "missing.backup"), key)

    refute File.exists?(Path.join(c.root, "missing.backup"))
  end

  test "schema 28 migration creates empty ownership without changing old authority history", c do
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE profile_authoring_object_operations; DROP TABLE profile_authoring_objects; PRAGMA user_version=28;"
      )

    assert :ok = Integrity.validate_schema_version(28, db)
    Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody, name: @store})
    state = :sys.get_state(store)
    assert {:ok, [[29]]} = SQL.query(state.db, "PRAGMA user_version")

    assert {:ok, [[0, 0]]} =
             SQL.query(
               state.db,
               "SELECT (SELECT COUNT(*) FROM profile_authoring_objects),(SELECT COUNT(*) FROM profile_authoring_object_operations)"
             )

    assert {:ok, 2} = Store.revision(store)
    assert :ok = Integrity.validate_snapshot(state.db)
  end

  test "different actors own proved bytes and collection preserves retained objects", c do
    {:ok, other, 3} = Store.provision_principal(c.store, "author:2", ["profile:manage"], [])
    first = input(c, "import:1", "shared original", 3)

    assert {:ok, _} =
             Store.import_authoring_object(c.store, c.credential, first, "shared original")

    second = Map.put(first, "expected_revision", 4)

    assert {:ok, receipt} =
             Store.import_authoring_object(c.store, other, second, "shared original")

    assert receipt["first_revision"] == 5
    assert {:ok, %{object_count: 1}} = Custody.inventory(c.custody)
    state = :sys.get_state(c.store)
    assert {:ok, [[2]]} = SQL.query(state.db, "SELECT COUNT(*) FROM profile_authoring_objects")
    assert {:ok, _} = Custody.stage_object(c.custody, "draft", "orphan")

    {:ok, maintainer, 6} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    assert {:ok, _} = Store.begin_maintenance(c.store, maintainer, 1, "maintenance:1", 6)
    assert {:ok, %{removed_objects: 1}} = Store.collect_profiles(c.store, other)
    assert {:ok, _} = Custody.read_object(c.custody, first["object"]["object_digest"])
  end

  test "operation capacity refuses before publication at the exact retained bound", c do
    data = input(c, "import:1", "one original", 2)
    assert {:ok, _} = Store.import_authoring_object(c.store, c.credential, data, "one original")
    state = :sys.get_state(c.store)
    :ok = Sqlite3.execute(state.db, "BEGIN")

    for revision <- 4..1026 do
      input =
        Map.merge(data, %{
          "operation_id" => "import:#{revision}",
          "expected_revision" => revision - 1
        })

      {:ok, document} = AuthoringImport.encode(input)
      {:ok, receipt} = AuthoringImport.encode_receipt(AuthoringImport.receipt(input, 3, revision))

      {:ok, []} =
        SQL.query(state.db, "INSERT INTO authority_journal VALUES (?,?,?)", [
          revision,
          "authoring_object_imported",
          input["operation_id"]
        ])

      {:ok, []} =
        SQL.query(
          state.db,
          "INSERT INTO profile_authoring_object_operations VALUES (?,?,?,?,?,?)",
          ["author:1", 1, input["operation_id"], document, receipt, revision]
        )
    end

    {:ok, []} = SQL.query(state.db, "UPDATE meta SET value=1026 WHERE key='revision'")
    :ok = Sqlite3.execute(state.db, "COMMIT")
    assert :ok = Integrity.validate_snapshot(state.db)
    next = input(c, "over-capacity", "new source", 1026)

    assert {:error, :authoring_object_capacity} =
             Store.import_authoring_object(c.store, c.credential, next, "new source")

    assert {:ok, %{object_count: 1}} = Custody.inventory(c.custody)
    assert {:ok, 1026} = Store.revision(c.store)
  end

  test "maintenance blocks new publication while an original receipt remains readable", c do
    data = input(c, "import:1", "original", 2)
    assert {:ok, receipt} = Store.import_authoring_object(c.store, c.credential, data, "original")

    {:ok, maintainer, 4} =
      Store.provision_principal(c.store, "maintainer:1", ["host:maintain"], [])

    assert {:ok, barrier} = Store.begin_maintenance(c.store, maintainer, 1, "maintenance:1", 4)
    next = input(c, "import:2", "must stay absent", barrier.revision)

    assert {:error, :maintenance_active} =
             Store.import_authoring_object(c.store, c.credential, next, "must stay absent")

    assert {:ok, ^receipt} = Store.import_authoring_object(c.store, c.credential, data, nil)
    assert {:ok, %{object_count: 1, lease_count: 0}} = Custody.inventory(c.custody)
    assert {:ok, revision} = Store.revision(c.store)
    assert revision == barrier.revision
  end

  for corruption <- [:receipt, :first_revision, :orphan_event] do
    @corruption corruption
    test "integrity refuses #{@corruption} corruption without creating a new import", c do
      data = input(c, "import:1", "original", 2)

      assert {:ok, receipt} =
               Store.import_authoring_object(c.store, c.credential, data, "original")

      state = :sys.get_state(c.store)

      case @corruption do
        :receipt ->
          {:ok, document} =
            AuthoringImport.encode_receipt(Map.put(receipt, "operation_id", "other"))

          assert {:ok, []} =
                   SQL.query(
                     state.db,
                     "UPDATE profile_authoring_object_operations SET receipt_document=?",
                     [document]
                   )

        :first_revision ->
          assert {:ok, []} =
                   SQL.query(
                     state.db,
                     "UPDATE profile_authoring_objects SET first_revision=1"
                   )

        :orphan_event ->
          assert {:ok, []} =
                   SQL.query(
                     state.db,
                     "INSERT INTO authority_journal VALUES (4,'authoring_object_imported','orphan')"
                   )

          assert {:ok, []} =
                   SQL.query(
                     state.db,
                     "UPDATE meta SET value=4 WHERE key='revision'"
                   )
      end

      assert {:error, :corrupt_authoring_objects} = Integrity.validate_snapshot(state.db)

      assert {:error, :corrupt_authoring_objects} =
               Store.import_authoring_object(c.store, c.credential, data, nil)

      assert {:ok, %{object_count: 1}} = Custody.inventory(c.custody)
    end
  end
end
