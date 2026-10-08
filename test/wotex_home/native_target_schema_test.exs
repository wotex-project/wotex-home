defmodule WotexHome.NativeTargetSchemaTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Lifx.ProfileCatalogue

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-native-target-schema-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    secret = :crypto.strong_rand_bytes(32)
    {:ok, identity} = Store.native_setup_identity(store)

    original =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      })

    {:ok, receipt} = Store.ensure_native_principal(store, original)
    {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:fixture")
    {:ok, revision} = Store.enroll_thing(store, package.thing)
    %{store: store, path: path, original: original, receipt: receipt, revision: revision}
  end

  test "schema twenty two migrates without granting native access or advancing history", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions; DROP TABLE native_target_operations; PRAGMA user_version=22"
        )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    store = start_supervised!({Store, path: c.path}, id: :migrated)
    assert {:ok, revision} = Store.revision(store)
    assert revision == c.revision

    assert {:ok, receipt} =
             Store.existing_native_principal(
               store,
               Map.put(c.original, "creation_revision", c.receipt["revision"])
             )

    assert receipt == c.receipt

    with_db(c.path, fn db ->
      assert {:ok, [[25]]} = SQL.query(db, "PRAGMA user_version")
      assert {:ok, []} = SQL.query(db, "SELECT * FROM native_target_operations")
      assert {:ok, []} = SQL.query(db, "SELECT * FROM principal_targets")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "migration refuses unexplained native targets and rolls back its actual DDL", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions; DROP TABLE native_target_operations; PRAGMA user_version=22"
        )

      assert {:ok, []} =
               SQL.query(db, "INSERT INTO principal_targets VALUES (?,?)", [
                 c.receipt["principal_id"],
                 "light:fixture"
               ])

      assert :ok = Integrity.validate_snapshot(db)
    end)

    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, {:schema_failed, _}}} = Store.start_link(path: c.path)

    with_db(c.path, fn db ->
      assert {:ok, [[22]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name='native_target_operations'"
               )

      assert {:ok, [[revision]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
      assert revision == c.revision
      assert {:ok, [["light:fixture"]]} = SQL.query(db, "SELECT thing_id FROM principal_targets")
    end)
  end

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA foreign_keys=ON")
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end
end
