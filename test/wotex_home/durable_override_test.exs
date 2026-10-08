Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableOverrideTest do
  @moduledoc false

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
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))

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

    assert {:ok,
            %{
              store_revision: 5,
              dependencies: %{
                operator_override_rows: 1,
                operator_overrides_reactivate_on_restore: false
              }
            }} = Backup.verify(archive, key)

    restore_dir = path <> ".restore"
    File.mkdir!(restore_dir)
    File.chmod!(restore_dir, 0o700)

    assert {:ok,
            %{
              store_revision: 5,
              quarantined: true,
              dependencies: %{operator_override_rows: 1}
            }} =
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
    %{store: store, owner: owner, other: other, reader: reader} = ctx

    assert {:ok, _lease, 5} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 100)

    assert {:ok, [_]} = Store.active_override_leases(store, reader, ["light:desk"], 150)
    assert {:ok, 6} = Store.revoke_target_grant(store, "operator:1", "light:desk")
    assert {:ok, []} = Store.active_override_leases(store, reader, ["light:desk"], 150)

    assert {:error, :permission_denied} =
             Store.revoke_override_lease(store, owner, "light:desk", 1)

    assert {:ok, _lease, 7} =
             Store.issue_override_lease(store, other, "light:desk", 1, 0, 150, 100)
  end

  test "credential rotation clears the old lease in the authority transaction", ctx do
    %{store: store, owner: owner, other: other, reader: reader} = ctx

    assert {:ok, _lease, 5} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 100)

    assert {:ok, replacement, 6} =
             Store.rotate_principal_credential(store, "operator:1")

    assert {:error, :unauthorized} =
             Store.active_override_leases(store, owner, ["light:desk"], 150)

    assert {:ok, []} = Store.active_override_leases(store, reader, ["light:desk"], 150)

    assert {:ok, _lease, 7} =
             Store.issue_override_lease(store, other, "light:desk", 1, 0, 150, 100)

    assert {:error, :override_conflict} =
             Store.issue_override_lease(store, replacement, "light:desk", 1, 0, 150, 100)
  end

  test "target revocation clears its lease", ctx do
    %{store: store, owner: owner, reader: reader} = ctx

    assert {:ok, _lease, 5} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 100, 100)

    assert {:ok, 6} = Store.revoke_thing(store, "light:desk")
    assert {:ok, []} = Store.active_override_leases(store, reader, ["light:desk"], 150)

    assert {:error, :target_unavailable} =
             Store.issue_override_lease(store, owner, "light:desk", 1, 0, 150, 100)
  end

  test "version nine backup verifies and migrates with empty leases", ctx do
    %{path: path, store: store, reader: reader} = ctx
    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
                 "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time; ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch; ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms; DROP TABLE rule_candidate_reviews; DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; PRAGMA user_version=9"
             )

    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".v9.backup"
    assert {:ok, %{store_revision: 4}} = Backup.export(db, archive, key)

    assert {:ok, %{store_revision: 4, dependencies: %{operator_override_rows: 0}}} =
             Backup.verify(archive, key)

    :ok = Sqlite3.close(db)

    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, []} = Store.active_override_leases(migrated, reader, ["light:desk"], 100)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "PRAGMA user_version")
    assert {:ok, [[26]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(migrated)
  end

  test "live lease APIs use Store monotonic time and reset it with the boot", ctx do
    %{path: path, store: store, owner: owner, reader: reader} = ctx

    assert {:ok, lease, 5} =
             Store.issue_override_lease_live(store, owner, "light:desk", 1, 0, 5_000)

    assert lease.start_ms >= 0
    assert lease.expires_ms - lease.start_ms == 5_000
    assert {:ok, [^lease]} = Store.active_override_leases_live(store, reader, ["light:desk"])
    :ok = GenServer.stop(store)

    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, []} = Store.active_override_leases_live(reopened, reader, ["light:desk"])
    :ok = GenServer.stop(reopened)
  end

  test "override operation IDs prevent renewal and resolve lost issue or revoke replies", ctx do
    %{path: path, store: store, owner: owner, other: other} = ctx

    assert {:ok, issued} =
             Store.issue_override_operation_live(
               store,
               owner,
               1,
               "override:one",
               "light:desk",
               0,
               5_000
             )

    assert issued.issue_revision == 5
    assert issued.active
    assert issued.remaining_ms in 1..5_000

    assert {:ok, repeated} =
             Store.issue_override_operation_live(
               store,
               owner,
               1,
               "override:one",
               "light:desk",
               0,
               5_000
             )

    assert repeated.issue_revision == issued.issue_revision
    assert {:ok, 5} = Store.revision(store)

    assert {:error, :override_operation_conflict} =
             Store.issue_override_operation_live(
               store,
               owner,
               1,
               "override:one",
               "light:desk",
               0,
               6_000
             )

    assert {:error, :override_conflict} =
             Store.issue_override_operation_live(
               store,
               owner,
               1,
               "override:two",
               "light:desk",
               0,
               5_000
             )

    assert :not_found = Store.override_operation_status_live(store, other, 1, "override:one")
    assert {:ok, current} = Store.override_operation_status_live(store, owner, 1, "override:one")
    assert current.active

    assert {:ok, revoked} =
             Store.revoke_override_operation_live(store, owner, 1, "override:one")

    assert revoked.revoke_revision == 6
    refute revoked.active
    assert revoked.remaining_ms == 0

    assert {:ok, ^revoked} =
             Store.revoke_override_operation_live(store, owner, 1, "override:one")

    assert {:ok, 6} = Store.revision(store)

    assert {:ok, next} =
             Store.issue_override_operation_live(
               store,
               other,
               1,
               "override:other",
               "light:desk",
               0,
               5_000
             )

    assert next.issue_revision == 7

    assert {:ok, ^revoked} =
             Store.issue_override_operation_live(
               store,
               owner,
               1,
               "override:one",
               "light:desk",
               0,
               5_000
             )

    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".operations.backup"
    assert {:ok, %{store_revision: 7}} = Store.export_backup(store, archive, key)

    assert {:ok,
            %{
              dependencies: %{
                operator_override_rows: 1,
                operator_override_operation_rows: 2,
                operator_overrides_reactivate_on_restore: false
              }
            }} = Backup.verify(archive, key)

    :ok = GenServer.stop(store)
    assert {:ok, reopened} = Store.start_link(path: path)

    assert {:ok, original} =
             Store.override_operation_status_live(reopened, owner, 1, "override:one")

    assert original.revoke_revision == 6
    refute original.active

    assert {:ok, restored_issue} =
             Store.override_operation_status_live(reopened, other, 1, "override:other")

    assert restored_issue.issue_revision == 7
    refute restored_issue.active
    assert {:ok, 7} = Store.revision(reopened)
    :ok = GenServer.stop(reopened)
  end

  test "version ten snapshot migrates without inventing operation receipts", ctx do
    %{path: path, store: store, owner: owner} = ctx
    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
                 "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time; ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch; ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms; DROP TABLE rule_candidate_reviews; DROP TABLE operator_override_operations; PRAGMA user_version=10"
             )

    key = :crypto.strong_rand_bytes(32)
    archive = path <> ".v10.backup"
    assert {:ok, %{store_revision: 4}} = Backup.export(db, archive, key)

    assert {:ok, %{dependencies: %{operator_override_operation_rows: 0}}} =
             Backup.verify(archive, key)

    :ok = Sqlite3.close(db)
    assert {:ok, migrated} = Store.start_link(path: path)

    assert :not_found =
             Store.override_operation_status_live(migrated, owner, 1, "override:old")

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "PRAGMA user_version")
    assert {:ok, [[26]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(migrated)
  end

  test "trusted revoke updates a matching operation receipt in the same revision", ctx do
    %{store: store, owner: owner} = ctx

    assert {:ok, %{issue_revision: 5}} =
             Store.issue_override_operation_live(
               store,
               owner,
               1,
               "override:direct",
               "light:desk",
               0,
               5_000
             )

    assert {:ok, 6} = Store.revoke_override_lease(store, owner, "light:desk", 1)

    assert {:ok, %{revoke_revision: 6, active: false}} =
             Store.override_operation_status_live(store, owner, 1, "override:direct")

    assert {:ok, %{revoke_revision: 6}} =
             Store.revoke_override_operation_live(store, owner, 1, "override:direct")

    assert {:ok, 6} = Store.revision(store)
  end
end
