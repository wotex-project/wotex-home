Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableObservationClockTest do
  @moduledoc false
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{FactReadModel, Integrity, SQL}
  alias WotexHome.Rules.{Event, Rule, Sandbox}
  alias WotexHome.Semantics.{Observation, Thing, Value}

  @fact {"light:clock", "power"}
  @drop_clock """
  #{WotexHome.Test.SchemaFixtures.drop_portable_profiles()}
  DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time;
  ALTER TABLE journal DROP COLUMN received_store_monotonic_ms;
  ALTER TABLE journal DROP COLUMN received_store_boot_epoch;
  ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms;
  ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch;
  """

  setup do
    directory =
      Path.join(System.tmp_dir!(), "home-observation-clock-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!({Store, path: path})
    {:ok, thing} = thing()
    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, credential, 2} =
      Store.provision_principal(store, "reviewer:clock", ["rule:review", "read"], [thing.id])

    {:ok, capability} = Thing.capability(thing, "power")

    %{
      directory: directory,
      path: path,
      store: store,
      thing: thing,
      capability: capability,
      credential: credential
    }
  end

  test "Store-owned receipts bind the journal without trusting adapter clocks", c do
    observation = report(c, 1)
    assert {:ok, 3} = Store.record(c.store, observation, c.capability)
    assert {:ok, ^observation, 3} = Store.current(c.store, elem(@fact, 0), elem(@fact, 1))
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    [[epoch, ms]] = timing(db)
    assert epoch == :sys.get_state(c.store).clock_epoch
    assert epoch != observation.boot_epoch and ms < observation.received_monotonic_ms

    assert [[epoch, ms]] ==
             rows(
               db,
               "SELECT received_store_boot_epoch, received_store_monotonic_ms FROM journal"
             )

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)

    assert {:ok, snapshot} =
             Authority.rule_facts(Authority.new(store: c.store), c.credential, [@fact])

    assert snapshot.profile == "home-reported-facts-v1"
    assert snapshot.scope == :reported_fact_preview_only
    assert snapshot.facts == %{@fact => {:known, %Value{kind: :boolean, data: true}}}
    assert snapshot.report_revisions == %{@fact => 3}
    assert snapshot.resource_revisions == %{c.thing.id => 0}
    assert snapshot.store_revision == 3 and snapshot.authority_epoch == 1
    assert snapshot.store_boot_epoch == epoch and snapshot.sampled_ms >= ms
    assert {:ok, 3} = Store.revision(c.store)

    assert {:ok, %{queued_requests: 0, rule_generation: 0, dispatch_enabled: false}} =
             Store.health(c.store)
  end

  test "missing, unknown and lab reports remain unknown rather than false", c do
    assert {:ok, %{facts: %{@fact => :unknown}, report_revisions: %{@fact => nil}}} = facts(c)

    assert {:ok, 3} =
             Store.record(c.store, %{report(c, 1) | trust: "synthetic_lab"}, c.capability)

    assert {:ok, %{facts: %{@fact => :unknown}, report_revisions: %{@fact => 3}}} = facts(c)

    assert {:ok, 4} =
             Store.record(c.store, %{report(c, 2) | quality: "unknown", value: nil}, c.capability)

    assert {:ok, %{facts: %{@fact => :unknown}, report_revisions: %{@fact => 4}}} = facts(c)
  end

  test "duplicate, stale and changed-content replays never restamp freshness", c do
    first = report(c, 2)
    assert {:ok, 3} = Store.record(c.store, first, c.capability)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    original = timing(db)
    age!(c.store, 5_001)
    # A later claimed receipt time or another adapter boot cannot refresh the same source event.
    duplicate = %{
      first
      | received_monotonic_ms: 0,
        received_time_utc_ms: 9_999_999,
        boot_epoch: "adapter:new"
    }

    assert {:duplicate, 3} = Store.record(c.store, duplicate, c.capability)
    assert {:error, :stale_sequence} = Store.record(c.store, report(c, 1), c.capability)

    assert {:error, :sequence_conflict} =
             Store.record(
               c.store,
               %{first | value: %Value{kind: :boolean, data: false}},
               c.capability
             )

    assert timing(db) == original
    assert {:ok, %{facts: %{@fact => :unknown}, store_revision: 3}} = facts(c)
    assert {:ok, ^first, 3} = Store.current(c.store, elem(@fact, 0), "power")
    :ok = Sqlite3.close(db)
  end

  test "receipt freshness boundaries agree with an independent elapsed-time reference", c do
    assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    [[epoch, received]] = timing(db)

    for delta <- [-1, 0, 1, 4_999, 5_000, 5_001, 10_000] do
      now = received + delta

      if now >= 0 do
        assert {:ok, snapshot} = FactReadModel.read(db, c.credential, [@fact], {epoch, now})
        expected = if delta in 0..5_000, do: {:known, report(c, 1).value}, else: :unknown
        assert snapshot.facts[@fact] == expected
      end
    end

    assert {:ok, %{facts: %{@fact => :unknown}}} =
             FactReadModel.read(db, c.credential, [@fact], {"store:other", received})

    :ok = Sqlite3.close(db)
  end

  test "restart and duplicate replay keep old reports unknown until a new accepted event", c do
    assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    original = timing(db)
    :ok = stop_supervised(Store)
    restarted = start_supervised!({Store, path: c.path})
    assert timing(db) == original

    assert {:ok, %{facts: %{@fact => :unknown}}} =
             Store.rule_facts_live(restarted, c.credential, [@fact])

    assert {:duplicate, 3} = Store.record(restarted, report(c, 1), c.capability)
    assert timing(db) == original
    assert {:ok, 4} = Store.record(restarted, report(c, 2), c.capability)
    [[new_epoch, _]] = timing(db)
    refute new_epoch == hd(hd(original))

    assert {:ok, %{facts: %{@fact => {:known, _}}, store_revision: 4}} =
             Store.rule_facts_live(restarted, c.credential, [@fact])

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  test "current review and observation permissions plus the target grant are mandatory", c do
    for {name, permissions} <- [
          {"reader:only", ["read"]},
          {"reviewer:only", ["rule:review"]},
          {"controller:only", ["control:ordinary"]}
        ] do
      {:ok, credential, _} = Store.provision_principal(c.store, name, permissions, [c.thing.id])
      assert {:error, :permission_denied} = Store.rule_facts_live(c.store, credential, [@fact])
    end

    assert {:error, :permission_denied} =
             Store.rule_facts_live(c.store, c.credential, [{"light:other", "power"}])

    assert {:ok, replacement, _} = Store.rotate_principal_credential(c.store, "reviewer:clock")
    assert {:error, :unauthorized} = facts(c)
    assert {:ok, _} = Store.rule_facts_live(c.store, replacement, [@fact])
    assert {:ok, _} = Store.revoke_target_grant(c.store, "reviewer:clock", c.thing.id)
    assert {:error, :permission_denied} = Store.rule_facts_live(c.store, replacement, [@fact])
  end

  test "fact inputs are closed and bounded before any projection", c do
    for invalid <- [
          [],
          [@fact, @fact],
          [@fact | :improper],
          [{"bad id", "power"}],
          List.duplicate(@fact, 33),
          [:not_a_fact]
        ] do
      assert {:error, :invalid_fact_scope} = Store.rule_facts_live(c.store, c.credential, invalid)
    end

    assert {:error, :unsupported_fact} =
             Store.rule_facts_live(c.store, c.credential, [{c.thing.id, "absent"}])

    assert {:error, :invalid_credential} =
             Store.rule_facts_live(c.store, "not-a-credential", [@fact])

    assert {:ok, 2} = Store.revision(c.store)
  end

  test "version fourteen migration preserves untimed reports without manufacturing freshness",
       c do
    assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
    :ok = stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, @drop_clock <> "PRAGMA user_version=14")
    archive = Path.join(c.directory, "legacy.backup")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Backup.export(db, archive, key)
    assert {:ok, %{store_revision: 3}} = Backup.verify(archive, key)
    :ok = Sqlite3.close(db)
    migrated = start_supervised!({Store, path: c.path})

    assert {:ok, %{facts: %{@fact => :unknown}}} =
             Store.rule_facts_live(migrated, c.credential, [@fact])

    assert {:duplicate, 3} = Store.record(migrated, report(c, 1), c.capability)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    assert [[27]] == rows(db, "PRAGMA user_version")
    assert [[nil, nil]] == timing(db)
    assert {:ok, 4} = Store.record(migrated, report(c, 2), c.capability)
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, %{facts: %{@fact => {:known, _}}}} =
             Store.rule_facts_live(migrated, c.credential, [@fact])

    :ok = Sqlite3.close(db)
  end

  test "encrypted staging retains receipt clocks but remains quarantined", c do
    assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    original = timing(db)
    :ok = Sqlite3.close(db)
    archive = Path.join(c.directory, "current.backup")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:ok, %{store_revision: 3}} = Backup.verify(archive, key)
    staged = Path.join(c.directory, "staged.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(archive, key, staged)
    {:ok, db} = Sqlite3.open(staged, mode: :readonly)
    assert timing(db) == original and :ok == Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: staged)
  end

  test "backup table scope permits SQLite housekeeping but rejects unchecked Home data", c do
    assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
    :ok = stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "ANALYZE")

    assert [[1]] ==
             rows(
               db,
               "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sqlite_stat1'"
             )

    key = :crypto.strong_rand_bytes(32)
    housekeeping = Path.join(c.directory, "housekeeping.backup")
    assert {:ok, _} = Backup.export(db, housekeeping, key)
    assert {:ok, %{store_revision: 3}} = Backup.verify(housekeeping, key)
    :ok = Sqlite3.execute(db, "CREATE TABLE unchecked_home_data(secret TEXT)")
    unchecked = Path.join(c.directory, "unchecked.backup")
    assert {:ok, _} = Backup.export(db, unchecked, key)
    assert {:error, :invalid_backup} = Backup.verify(unchecked, key)
    :ok = Sqlite3.close(db)
  end

  test "IR evaluation consumes authenticated unknown facts without creating authority", c do
    {:ok, rule} =
      Rule.new(%{
        "version" => 1,
        "id" => "rule:clock",
        "source_revision" => 2,
        "trigger" => %{"kind" => "explicit_request"},
        "predicate" => %{
          "op" => "not",
          "predicate" => %{
            "op" => "eq",
            "fact" => %{"thing_id" => c.thing.id, "capability_key" => "power"},
            "value" => %{"type" => "boolean", "value" => false}
          }
        },
        "effect" => %{
          "target_id" => c.thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true}
        },
        "authority_class" => "automation",
        "unknown_policy" => "block",
        "ownership_ms" => 1_000,
        "cooldown_ms" => 0,
        "causal_budget" => 1
      })

    {:ok, event} =
      Event.new(%{
        "kind" => "explicit_request",
        "rule_id" => rule.id,
        "root_id" => "root:clock",
        "depth" => 0
      })

    {:ok, sandbox} = Sandbox.new([rule])
    {:ok, snapshot} = facts(c)

    assert {:ok, %{proposals: []}, ^sandbox} =
             Sandbox.step(sandbox, event, snapshot.facts, %{}, 0)

    assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
    {:ok, snapshot} = facts(c)

    assert {:ok, %{proposals: [_proposal]}, _draft} =
             Sandbox.step(sandbox, event, snapshot.facts, %{}, 0)

    assert {:ok, %{queued_requests: 0, rule_generation: 0, dispatch_enabled: false}} =
             Store.health(c.store)
  end

  for {name, sql} <- [
        {"half a current clock", "UPDATE observation_current SET received_store_boot_epoch=NULL"},
        {"missing journal time", "UPDATE journal SET received_store_monotonic_ms=NULL"},
        {"invalid journal epoch", "UPDATE journal SET received_store_boot_epoch='invalid epoch'"},
        {"negative time", "UPDATE journal SET received_store_monotonic_ms=-1"},
        {"fractional time", "UPDATE journal SET received_store_monotonic_ms=0.5"},
        {"a changed current value", "UPDATE observation_current SET value_a='0'"},
        {"a mismatched source identity", "UPDATE journal SET source_sequence=2"},
        {"a missing original journal", "DELETE FROM journal"},
        {"a forged matched quality",
         "UPDATE observation_current SET quality='false'; UPDATE journal SET quality='false'"},
        {"a forged matched sequence",
         "UPDATE observation_current SET source_sequence=-1; UPDATE journal SET source_sequence=-1"}
      ] do
    @sql sql
    test "#{name} fails live facts, startup and encrypted verification", c do
      assert {:ok, 3} = Store.record(c.store, report(c, 1), c.capability)
      {:ok, db} = Sqlite3.open(c.path)
      :ok = Sqlite3.execute(db, "PRAGMA ignore_check_constraints=ON")
      :ok = Sqlite3.execute(db, @sql)
      assert {:error, :corrupt_value} = facts(c)
      assert {:ok, %{writable: false}} = Store.health(c.store)
      assert {:error, :store_unavailable} = facts(c)
      assert {:error, _} = Integrity.validate_snapshot(db)
      key = :crypto.strong_rand_bytes(32)
      archive = Path.join(c.directory, "invalid.backup")
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      :ok = Sqlite3.close(db)
      :ok = stop_supervised(Store)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  test "backwards same-epoch receipt time and late-page invalid epochs fail integrity", c do
    for sequence <- 1..102,
        do: assert({:ok, _} = Store.record(c.store, report(c, sequence), c.capability))

    {:ok, db} = Sqlite3.open(c.path)
    assert :ok = Integrity.validate_snapshot(db)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE journal SET received_store_monotonic_ms=1000000 WHERE source_sequence=1"
      )

    assert {:error, _} = Integrity.validate_snapshot(db)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE journal SET received_store_monotonic_ms=0 WHERE source_sequence=1"
      )

    assert :ok = Integrity.validate_snapshot(db)

    :ok =
      Sqlite3.execute(
        db,
        "UPDATE journal SET received_store_boot_epoch='invalid epoch' WHERE source_sequence=101"
      )

    assert {:error, _} = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
  end

  defp facts(c), do: Store.rule_facts_live(c.store, c.credential, [@fact])
  # Fixture-only clock advancement; the production boundary accepts no epoch/time option.
  defp age!(store, milliseconds),
    do: :sys.replace_state(store, &%{&1 | clock_origin: &1.clock_origin - milliseconds})

  defp timing(db),
    do:
      rows(
        db,
        "SELECT received_store_boot_epoch, received_store_monotonic_ms FROM observation_current"
      )

  defp rows(db, sql) do
    {:ok, result} = SQL.query(db, sql)
    result
  end

  defp report(c, sequence) do
    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => c.thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "source:clock",
          "source_sequence" => sequence,
          "boot_epoch" => "adapter:clock",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_700_000_000_000,
          "received_monotonic_ms" => 999_999_999
        },
        c.capability
      )

    report
  end

  defp thing do
    Thing.new(%{
      "id" => elem(@fact, 0),
      "role" => "Light",
      "profile_ref" => "fixture:clock:1",
      "capabilities" => [
        %{
          "thing_id" => elem(@fact, 0),
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => "fixture:clock:1",
          "evidence_ref" => "fixture:clock",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    })
  end
end
