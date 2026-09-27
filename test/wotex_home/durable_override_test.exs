defmodule WotexHome.DurableOverrideTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Rules.RuntimeGate
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-override-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [
                 @power,
                 %{
                   @power
                   | "key" => "brightness",
                     "value_kind" => "fraction",
                     "unit" => "ppm",
                     "evidence_ref" => "fixture:brightness:1"
                 }
               ]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, owner, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], [thing.id])

    assert {:ok, other, 3} =
             Store.provision_principal(store, "operator:2", ["control:ordinary"], [thing.id])

    assert {:ok, reader, 4} = Store.provision_principal(store, "reader:1", ["read"], [thing.id])
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    {:ok, path: path, store: store, owner: owner, other: other, reader: reader}
  end

  test "authenticated lease blocks the pure gate until expiry and revocation", ctx do
    %{store: store, owner: owner, other: other, reader: reader} = ctx

    assert {:error, :unauthorized} =
             Store.issue_override_lease(
               store,
               :binary.copy(<<0>>, 32),
               "light:desk",
               1,
               1,
               100,
               100
             )

    assert {:error, :permission_denied} =
             Store.issue_override_lease(store, reader, "light:desk", 1, 0, 100, 100)

    assert {:error, :stale_resource_revision} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 1, 100, 100)

    assert {:error, :stale_authority_epoch} =
             Store.issue_override_lease(store, owner, "light:desk", 2, 0, 100, 100)

    assert {:error, :invalid_override_lease} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 86_400_001)

    assert {:ok, lease, 5} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 100)

    assert lease.operator_id == "operator:1"
    assert {:ok, [^lease]} = Store.active_override_leases(store, reader, ["light:desk"], 199)

    assert {:ok, %{"light:desk" => :operator_override}} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :allow}, [lease], 1, 199)

    assert {:ok, %{"light:desk" => :safety_denied}} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :deny}, [lease], 1, 199)

    assert {:error, :override_conflict} =
             Store.issue_override_lease(store, other, "light:desk", 1, 0, 150, 100)

    assert {:error, :override_unavailable} =
             Store.revoke_override_lease(store, other, "light:desk", 1)

    assert {:ok, []} = Store.active_override_leases(store, reader, ["light:desk"], 200)
    assert {:ok, 6} = Store.revoke_override_lease(store, owner, "light:desk", 1)
    assert {:ok, []} = Store.active_override_leases(store, reader, ["light:desk"], 150)

    assert {:ok, _new_lease, 7} =
             Store.issue_override_lease(store, other, "light:desk", 1, 0, 200, 100)
  end

  test "restart and encrypted restore retain history but never reactivate a lease", ctx do
    %{path: path, store: store, owner: owner, reader: reader} = ctx

    assert {:ok, _lease, 5} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 100)

    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".backup"
    assert {:ok, %{store_revision: 5}} = Store.export_backup(store, archive, key)
    assert {:ok, %{store_revision: 5}} = Backup.verify(archive, key)
    restore_dir = path <> ".restore"
    File.mkdir!(restore_dir)
    File.chmod!(restore_dir, 0o700)

    assert {:ok, %{store_revision: 5, quarantined: true}} =
             Backup.stage_restore(archive, key, Path.join(restore_dir, "staged.sqlite"))

    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)

    assert {:ok, statement} =
             Sqlite3.prepare(db, "SELECT COUNT(*) FROM operator_override_leases")

    assert {:ok, [[1]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)

    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, []} = Store.active_override_leases(reopened, reader, ["light:desk"], 150)

    assert {:error, :override_unavailable} =
             Store.revoke_override_lease(reopened, owner, "light:desk", 1)

    assert {:ok, _fresh, 6} =
             Store.issue_override_lease(reopened, owner, "light:desk", 1, 0, 150, 100)

    :ok = GenServer.stop(reopened)
  end

  test "grant revocation makes the issuer's lease unavailable to readers", ctx do
    %{store: store, owner: owner, reader: reader} = ctx

    assert {:ok, _lease, 5} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 100)

    assert {:ok, [_]} = Store.active_override_leases(store, reader, ["light:desk"], 150)
    assert {:ok, 6} = Store.revoke_target_grant(store, "operator:1", "light:desk")
    assert {:ok, []} = Store.active_override_leases(store, reader, ["light:desk"], 150)

    assert {:error, :permission_denied} =
             Store.revoke_override_lease(store, owner, "light:desk", 1)
  end

  test "version nine backup verifies and migrates with empty leases", ctx do
    %{path: path, store: store, reader: reader} = ctx
    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(db, "DROP TABLE operator_override_leases; PRAGMA user_version=9")
    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".v9.backup"
    assert {:ok, %{store_revision: 4}} = Backup.export(db, archive, key)
    assert {:ok, %{store_revision: 4}} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)

    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, []} = Store.active_override_leases(migrated, reader, ["light:desk"], 100)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "PRAGMA user_version")
    assert {:ok, [[10]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(migrated)
  end
end
