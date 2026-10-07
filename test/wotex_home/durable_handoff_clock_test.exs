Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableHandoffClockTest do
  @moduledoc false
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Mutation
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.Integrity
  alias WotexHome.Semantics.Thing

  @drop_clock """
  #{WotexHome.Test.SchemaFixtures.drop_portable_profiles()}
  DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP INDEX power_handoff_time;
  ALTER TABLE request_execution DROP COLUMN handoff_store_boot_epoch;
  ALTER TABLE request_execution DROP COLUMN handoff_store_monotonic_ms;
  """

  setup do
    directory = Path.join(System.tmp_dir!(), "home-clock-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    {:ok, store} = Store.start_link(path: path)
    {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], [thing.id])

    for n <- 1..2 do
      {:ok, mutation} =
        Mutation.new(%{
          "api_version" => 1,
          "authority_epoch" => 1,
          "operation_id" => "op:#{n}",
          "expected_revision" => 0,
          "target_id" => thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true}
        })

      assert {:ok, %{disposition: :held}} = Store.submit_request(store, credential, mutation)
    end

    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(path)
    # Historical terminal rows are integrity fixtures, not qualification or transport evidence.
    for n <- 1..2, do: terminal_fixture(db, "op:#{n}", n + 2, n * 2 + 3, n * 10)

    :ok =
      Sqlite3.execute(
        db,
        "DELETE FROM request_outbox; UPDATE meta SET value=8 WHERE key='revision'"
      )

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, path: path, directory: directory, credential: credential}
  end

  test "terminal history and encrypted staging preserve clock pairs without reactivation", c do
    {:ok, store} = Store.start_link(path: c.path)

    assert {:ok, %{disposition: :observed, revision: 6}} =
             Store.request_status(store, c.credential, 1, "op:1")

    assert {:ok, %{dispatch_enabled: false, queued_requests: 0, unknown_outcomes: 0}} =
             Store.health(store)

    refute :sys.get_state(store).clock_epoch == "store:fixture"
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "history.backup")
    assert {:ok, _} = Store.export_backup(store, archive, key)
    assert {:ok, %{store_revision: 8}} = Backup.verify(archive, key)
    staged = Path.join(c.directory, "quarantined.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(archive, key, staged)
    {:ok, db} = Sqlite3.open(staged, mode: :readonly)
    assert [[5, "store:fixture", 10], [7, "store:fixture", 20]] == timing(db)
    :ok = Sqlite3.close(db)
    :ok = GenServer.stop(store)
    {:ok, restarted} = Store.start_link(path: c.path)
    assert {:ok, 8} = Store.revision(restarted)
    :ok = GenServer.stop(restarted)
  end

  test "version twelve migration preserves receipts and explicitly leaves legacy handoffs untimed",
       c do
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, @drop_clock <> "PRAGMA user_version=12")
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "legacy.backup")
    assert {:ok, _} = Backup.export(db, archive, key)
    assert {:ok, %{store_revision: 8}} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 8} = Store.revision(store)

    assert {:ok, %{disposition: :observed, revision: 6}} =
             Store.request_status(store, c.credential, 1, "op:1")

    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    assert [[23]] == rows(db, "PRAGMA user_version")
    assert [[5, nil, nil], [7, nil, nil]] == timing(db)
    :ok = Sqlite3.close(db)
  end

  test "crash recovery changes the receipt but never the committed handoff time", c do
    {:ok, db} = Sqlite3.open(c.path)
    original = timing(db)

    :ok =
      Sqlite3.execute(db, """
      DELETE FROM request_journal WHERE revision=8;
      UPDATE request_receipts SET disposition='dispatching', revision=7 WHERE operation_id='op:2';
      UPDATE request_execution SET state='dispatching', revision=7 WHERE operation_id='op:2';
      UPDATE meta SET value=7 WHERE key='revision';
      """)

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)

    assert {:ok, %{disposition: :outcome_unknown, reason: "crash_after_handoff", revision: 8}} =
             Store.request_status(store, c.credential, 1, "op:2")

    assert {:ok, %{unknown_outcomes: 1, queued_requests: 0}} = Store.health(store)
    :ok = GenServer.stop(store)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    assert timing(db) == original
    :ok = Sqlite3.close(db)
    {:ok, restarted} = Store.start_link(path: c.path)
    assert {:ok, 8} = Store.revision(restarted)
    :ok = GenServer.stop(restarted)
  end

  for {name, mutation} <- [
        {"a missing epoch", "handoff_store_boot_epoch=NULL"},
        {"a missing time", "handoff_store_monotonic_ms=NULL"},
        {"an invalid epoch", "handoff_store_boot_epoch='invalid epoch'"},
        {"a negative time", "handoff_store_monotonic_ms=-1"},
        {"a fractional time", "handoff_store_monotonic_ms=0.5"},
        {"a timestamp without a handoff", "handoff_revision=NULL"},
        {"backwards same-epoch time", "handoff_store_monotonic_ms=9"}
      ] do
    @mutation mutation
    test "#{name} fails startup and encrypted archive verification", c do
      {:ok, db} = Sqlite3.open(c.path)
      :ok = Sqlite3.execute(db, "PRAGMA ignore_check_constraints=ON")

      :ok =
        Sqlite3.execute(db, "UPDATE request_execution SET #{@mutation} WHERE operation_id='op:2'")

      assert {:error, _} = Integrity.validate_snapshot(db)
      key = :crypto.strong_rand_bytes(32)
      archive = Path.join(c.directory, "invalid.backup")
      # Export authenticates bytes, not semantic validity; verification must reject them.
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      :ok = Sqlite3.close(db)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  test "a clock pair requires its original dispatching journal identity", c do
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "UPDATE request_journal SET operation_id='op:1' WHERE revision=7")
    assert {:error, _} = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "time may restart from zero only in a different Store epoch", c do
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE request_execution SET handoff_store_boot_epoch='store:next', handoff_store_monotonic_ms=0 WHERE operation_id='op:2'"
      )

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 8} = Store.revision(store)
    :ok = GenServer.stop(store)
  end

  test "bounded epoch validation reaches corrupt history beyond its first page", c do
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    for n <- 1..260 do
      operation = "op:page:#{n}"
      handoff = 8 + n * 2 - 1

      :ok =
        Sqlite3.execute(db, """
        INSERT INTO request_receipts
          SELECT principal_id, authority_epoch, '#{operation}', expected_revision, target_id,
            capability_key, value_kind, value_a, value_b, profile_ref, 'observed', NULL, #{handoff + 1}
          FROM request_receipts WHERE operation_id='op:1';
        """)

      terminal_fixture(db, operation, 3, handoff, 20 + n)
    end

    :ok = Sqlite3.execute(db, "UPDATE meta SET value=528 WHERE key='revision'; COMMIT")
    assert :ok = Integrity.validate_snapshot(db)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE request_execution SET handoff_store_boot_epoch='bad epoch' WHERE operation_id='op:page:260'"
      )

    assert {:error, _} = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  defp terminal_fixture(db, operation, admission, handoff, ms) do
    :ok =
      Sqlite3.execute(db, """
      UPDATE request_receipts SET disposition='observed', revision=#{handoff + 1}
        WHERE operation_id='#{operation}';
      INSERT OR REPLACE INTO request_causal_roots
        (principal_id, authority_epoch, operation_id, origin, created_revision, reserved_effects, reservation_revision)
        SELECT principal_id, authority_epoch, operation_id, 'legacy_request', NULL, 1, NULL
        FROM request_receipts WHERE operation_id='#{operation}';
      INSERT INTO request_execution
        (principal_id, authority_epoch, operation_id, target_id, effect_domain, profile_ref,
         profile_evidence_ref, resource_revision, rule_generation, baseline_revision,
         admission_revision, planned_value, state, claim_token, claim_boot_epoch,
         handoff_revision, attempts, revision, handoff_store_boot_epoch, handoff_store_monotonic_ms)
        VALUES ('operator:1', 1, '#{operation}', 'light:desk', 'light:desk', 'lifx.fixture:1',
          'fixture:profile', 0, 0, 0, #{admission}, x'0101', 'observed', zeroblob(32),
          'worker:observation', #{handoff}, 1, #{handoff + 1}, 'store:fixture', #{ms});
      INSERT INTO request_journal VALUES (#{handoff}, 'operator:1', 1, '#{operation}', 'dispatching', NULL);
      INSERT INTO request_journal VALUES (#{handoff + 1}, 'operator:1', 1, '#{operation}', 'observed', NULL);
      """)
  end

  defp thing do
    Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.fixture:1",
      "capabilities" => [
        %{
          "thing_id" => "light:desk",
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => "lifx.fixture:1",
          "evidence_ref" => "fixture:profile",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    })
  end

  defp timing(db),
    do:
      rows(
        db,
        "SELECT handoff_revision, handoff_store_boot_epoch, handoff_store_monotonic_ms FROM request_execution ORDER BY handoff_revision"
      )

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      rows
    after
      :ok = Sqlite3.release(db, statement)
    end
  end
end
