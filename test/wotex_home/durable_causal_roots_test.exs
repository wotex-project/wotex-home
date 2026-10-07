Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableCausalRootsTest do
  @moduledoc false
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{CausalLedger, Integrity, SQL}
  alias WotexHome.{Mutation, Semantics.Thing}

  setup do
    directory = Path.join(System.tmp_dir!(), "home-causes-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    {:ok, store} = Store.start_link(path: path)
    {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], [thing.id])

    {:ok, mutation} = mutation("op:1", 0)

    assert {:ok, %{disposition: :held, revision: 3} = receipt} =
             Store.submit_request(store, credential, mutation)

    {:ok, rejected} = mutation("op:2", 1)

    assert {:ok, %{disposition: :rejected, revision: 4}} =
             Store.submit_request(store, credential, rejected)

    :ok = GenServer.stop(store)

    {:ok,
     path: path,
     directory: directory,
     credential: credential,
     mutation: mutation,
     receipt: receipt}
  end

  test "held and rejected receipts have distinct immutable unused roots", c do
    assert %{profile: "home-explicit-request-cause-v1", max_effects: 1, max_depth: 1} ==
             CausalLedger.profile()

    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)

    assert [["op:1", "explicit_request", 3, 0, nil], ["op:2", "explicit_request", 4, 0, nil]] ==
             roots(db)

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, receipt} = Store.submit_request(store, c.credential, c.mutation)
    assert receipt == c.receipt
    assert {:ok, 4} = Store.revision(store)

    assert {:ok, %{disposition: :rejected, revision: 5}} =
             Store.cancel_request(store, c.credential, 1, "op:1")

    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)

    assert [["op:1", "explicit_request", 3, 0, nil], ["op:2", "explicit_request", 4, 0, nil]] ==
             roots(db)

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "a failed outer transaction cannot spend or regenerate a root", c do
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    assert :ok = CausalLedger.reserve(db, c.receipt, 5)
    assert {:error, :causal_budget_exhausted} = CausalLedger.reserve(db, c.receipt, 6)

    assert [[1, 5]] ==
             rows(
               db,
               "SELECT reserved_effects, reservation_revision FROM request_causal_roots WHERE operation_id='op:1'"
             )

    :ok = Sqlite3.execute(db, "ROLLBACK")

    assert [[0, nil]] ==
             rows(
               db,
               "SELECT reserved_effects, reservation_revision FROM request_causal_roots WHERE operation_id='op:1'"
             )

    assert [[4]] == rows(db, "SELECT value FROM meta WHERE key='revision'")
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "a failed root insert rolls back the complete new request transaction", c do
    {:ok, store} = Store.start_link(path: c.path)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TRIGGER fixture_cause_abort BEFORE INSERT ON request_causal_roots
      BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END;
      """)

    :ok = Sqlite3.close(db)
    {:ok, mutation} = mutation("op:3", 0)
    assert {:error, :store_unavailable} = Store.submit_request(store, c.credential, mutation)
    assert {:ok, 4} = Store.revision(store)
    assert :not_found == Store.request_status(store, c.credential, 1, "op:3")
    assert {:ok, %{writable: false, held_requests: 1}} = Store.health(store)
    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path)
    assert [[2]] == rows(db, "SELECT COUNT(*) FROM request_causal_roots")
    assert [[2]] == rows(db, "SELECT COUNT(*) FROM request_receipts")
    assert [[1]] == rows(db, "SELECT COUNT(*) FROM request_outbox")
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "a spent cancellation tombstone survives encrypted backup and restart", c do
    {:ok, db} = Sqlite3.open(c.path)
    cancelled_fixture(db, c.receipt)
    assert {:error, :causal_budget_exhausted} = CausalLedger.reserve(db, c.receipt, 7)
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)

    assert {:ok,
            %{disposition: :rejected, reason: "cancelled_before_claim", revision: 6} = receipt} =
             Store.submit_request(store, c.credential, c.mutation)

    assert {:ok, ^receipt} = Store.cancel_request(store, c.credential, 1, "op:1")

    assert {:error, :request_not_held} =
             Store.admit_held_power(store, c.credential, 1, "op:1", "boot:1", 0)

    assert {:ok, 6} = Store.revision(store)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "causes.backup")
    assert {:ok, _} = Store.export_backup(store, archive, key)
    assert {:ok, %{store_revision: 6}} = Backup.verify(archive, key)
    staged = Path.join(c.directory, "quarantined.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(archive, key, staged)
    {:ok, db} = Sqlite3.open(staged, mode: :readonly)

    assert [["op:1", "explicit_request", 3, 1, 5], ["op:2", "explicit_request", 4, 0, nil]] ==
             roots(db)

    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
    {:ok, again} = Store.start_link(path: c.path)
    assert {:ok, ^receipt} = Store.request_status(again, c.credential, 1, "op:1")
    :ok = GenServer.stop(again)
  end

  test "version thirteen migration conserves queue history without inventing creation provenance",
       c do
    {:ok, db} = Sqlite3.open(c.path)
    cancelled_fixture(db, c.receipt)
    downgrade(db)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "legacy.backup")
    assert {:ok, _} = Backup.export(db, archive, key)
    assert {:ok, %{store_revision: 6}} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 6} = Store.revision(store)
    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path)
    assert [[22]] == rows(db, "PRAGMA user_version")

    assert [["op:1", "legacy_request", nil, 1, 5], ["op:2", "legacy_request", nil, 0, nil]] ==
             roots(db)

    assert {:error, :causal_budget_exhausted} = CausalLedger.reserve(db, c.receipt, 7)
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "legacy queued work lacking its queue event retains a budget but cannot gain provenance",
       c do
    {:ok, db} = Sqlite3.open(c.path)
    legacy_queue_fixture(db)
    downgrade(db)
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 5} = Store.revision(store)
    assert {:ok, %{dispatch_enabled: false, queued_requests: 1}} = Store.health(store)
    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path)

    assert [["op:1", "legacy_request", nil, 1, nil], ["op:2", "legacy_request", nil, 0, nil]] ==
             roots(db)

    assert {:error, :causal_provenance_unavailable} = CausalLedger.execution_guard(db, c.receipt)
    assert {:error, :causal_budget_exhausted} = CausalLedger.reserve(db, c.receipt, 6)
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "duplicate current queue history fails rather than extending the budget", c do
    {:ok, db} = Sqlite3.open(c.path)
    cancelled_fixture(db, c.receipt)
    duplicate_queue_fixture(db)
    assert {:error, _} = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "ambiguous legacy queue history migrates as spent with unavailable provenance", c do
    {:ok, db} = Sqlite3.open(c.path)
    cancelled_fixture(db, c.receipt)
    duplicate_queue_fixture(db)
    downgrade(db)
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 7} = Store.revision(store)
    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path)

    assert [["op:1", "legacy_request", nil, 1, nil], ["op:2", "legacy_request", nil, 0, nil]] ==
             roots(db)

    assert {:error, :causal_budget_exhausted} = CausalLedger.reserve(db, c.receipt, 8)
    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  for {name, mutation} <- [
        {"a missing root", "DELETE FROM request_causal_roots WHERE operation_id='op:1'"},
        {"a mismatched creation event",
         "UPDATE request_causal_roots SET created_revision=4 WHERE operation_id='op:1'"},
        {"an unknown origin",
         "UPDATE request_causal_roots SET origin='reported_edge' WHERE operation_id='op:1'"},
        {"a missing explicit origin revision",
         "UPDATE request_causal_roots SET created_revision=NULL WHERE operation_id='op:1'"},
        {"an oversized effect budget",
         "UPDATE request_causal_roots SET reserved_effects=2 WHERE operation_id='op:1'"},
        {"a fractional effect count",
         "UPDATE request_causal_roots SET reserved_effects=0.5 WHERE operation_id='op:1'"},
        {"a negative effect count",
         "UPDATE request_causal_roots SET reserved_effects=-1 WHERE operation_id='op:1'"},
        {"a spend without its queue event",
         "UPDATE request_causal_roots SET reserved_effects=1, reservation_revision=4 WHERE operation_id='op:1'"},
        {"an explicit spend without a revision",
         "UPDATE request_causal_roots SET reserved_effects=1, reservation_revision=NULL WHERE operation_id='op:1'"},
        {"a refund of terminal history",
         "UPDATE request_causal_roots SET reserved_effects=0, reservation_revision=NULL WHERE operation_id='op:1'"}
      ] do
    @mutation mutation
    test "#{name} fails startup and encrypted snapshot verification", c do
      {:ok, db} = Sqlite3.open(c.path)
      cancelled_fixture(db, c.receipt)
      :ok = Sqlite3.execute(db, "PRAGMA ignore_check_constraints=ON")
      :ok = Sqlite3.execute(db, @mutation)
      assert {:error, _} = Integrity.validate_snapshot(db)
      key = :crypto.strong_rand_bytes(32)
      archive = Path.join(c.directory, "invalid.backup")
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      :ok = Sqlite3.close(db)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  # Transaction fault fixtures, not physical qualification or dispatch evidence.
  defp cancelled_fixture(db, receipt) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    :ok = CausalLedger.reserve(db, receipt, 5)

    :ok =
      Sqlite3.execute(db, """
      DELETE FROM request_outbox WHERE operation_id='op:1';
      UPDATE request_receipts SET disposition='rejected', reason='cancelled_before_claim', revision=6
        WHERE operation_id='op:1';
      INSERT INTO request_journal VALUES (5, 'operator:1', 1, 'op:1', 'queued', NULL);
      INSERT INTO request_journal VALUES (6, 'operator:1', 1, 'op:1', 'rejected', 'cancelled_before_claim');
      UPDATE meta SET value=6 WHERE key='revision'; COMMIT;
      """)
  end

  defp legacy_queue_fixture(db) do
    :ok =
      Sqlite3.execute(db, """
      DELETE FROM request_outbox WHERE operation_id='op:1';
      UPDATE request_receipts SET disposition='queued', revision=5 WHERE operation_id='op:1';
      INSERT INTO request_execution
        (principal_id, authority_epoch, operation_id, target_id, effect_domain, profile_ref,
         profile_evidence_ref, resource_revision, rule_generation, baseline_revision,
         admission_revision, planned_value, state, attempts, revision)
        VALUES ('operator:1', 1, 'op:1', 'light:desk', 'light:desk', 'fixture:power:1',
          'fixture:profile:1', 0, 0, 0, 5, x'0101', 'queued', 0, 5);
      INSERT INTO authority_journal VALUES (5, 'fixture_legacy', 'op:1');
      UPDATE meta SET value=5 WHERE key='revision';
      """)
  end

  defp duplicate_queue_fixture(db),
    do:
      Sqlite3.execute(db, """
      INSERT INTO request_journal VALUES (7, 'operator:1', 1, 'op:1', 'queued', NULL);
      UPDATE meta SET value=7 WHERE key='revision';
      """)

  defp downgrade(db),
    do:
      Sqlite3.execute(
        db,
        WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
          "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; PRAGMA user_version=13"
      )

  defp roots(db),
    do:
      rows(
        db,
        "SELECT operation_id, origin, created_revision, reserved_effects, reservation_revision FROM request_causal_roots ORDER BY operation_id"
      )

  defp rows(db, sql) do
    {:ok, result} = SQL.query(db, sql)
    result
  end

  defp mutation(operation, expected),
    do:
      Mutation.new(%{
        "api_version" => 1,
        "operation_id" => operation,
        "authority_epoch" => 1,
        "expected_revision" => expected,
        "target_id" => "light:desk",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

  defp thing,
    do:
      Thing.new(%{
        "id" => "light:desk",
        "role" => "Light",
        "profile_ref" => "fixture:power:1",
        "capabilities" => [
          %{
            "thing_id" => "light:desk",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:power:1",
            "evidence_ref" => "fixture:evidence:1",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })
end
