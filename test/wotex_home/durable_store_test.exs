Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableStoreTest do
  @moduledoc false

  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Semantics.{Capability, Observation, Thing, Value}

  @capability %{
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

  @report %{
    "thing_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => false},
    "quality" => "reported",
    "trust" => "unauthenticated_local",
    "source_epoch" => "device:1",
    "source_sequence" => 7,
    "boot_epoch" => "boot:1",
    "source_time_utc_ms" => nil,
    "received_time_utc_ms" => 1_000_000,
    "received_monotonic_ms" => 100
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = Path.join(directory, "home.sqlite")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: path}
  end

  test "recording requires active enrollment and its exact capability", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    assert {:ok, store} = Store.start_link(path: path)
    assert {:error, :target_unavailable} = Store.record(store, observation, capability)
    assert {:ok, 0} = Store.revision(store)

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@capability]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, changed_capability} =
             Capability.new(%{@capability | "evidence_ref" => "fixture:power:2"})

    assert {:error, :capability_mismatch} =
             Store.record(store, observation, changed_capability)

    assert {:ok, 2} = Store.record(store, observation, capability)
    assert {:ok, 3} = Store.revoke_thing(store, "light:desk")
    assert {:error, :target_unavailable} = Store.record(store, observation, capability)
    assert {:ok, 3} = Store.revision(store)
    :ok = GenServer.stop(store)
  end

  test "one multi-capability reply commits together or rolls back together", %{path: path} do
    brightness = %{
      @capability
      | "key" => "brightness",
        "value_kind" => "fraction",
        "unit" => "ppm",
        "evidence_ref" => "fixture:brightness:1"
    }

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@capability, brightness]
             })

    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, 1} = Store.enroll_thing(store, thing)
    power_capability = thing.capabilities["power"]
    brightness_capability = thing.capabilities["brightness"]

    power = fn sequence ->
      {:ok, report} =
        Observation.new(
          %{
            @report
            | "source_sequence" => sequence,
              "received_time_utc_ms" => 1_000_000 + sequence,
              "received_monotonic_ms" => 100 + sequence
          },
          power_capability
        )

      report
    end

    level = fn sequence ->
      {:ok, report} =
        Observation.new(
          %{
            @report
            | "capability_key" => "brightness",
              "value" => %{"type" => "fraction", "ppm" => 500_000},
              "source_sequence" => sequence,
              "received_time_utc_ms" => 1_000_000 + sequence,
              "received_monotonic_ms" => 100 + sequence
          },
          brightness_capability
        )

      report
    end

    assert {:ok, 2} = Store.record(store, power.(1), power_capability)
    assert {:ok, 3} = Store.record(store, level.(3), brightness_capability)

    assert {:error, :stale_sequence} =
             Store.record_batch(store, thing, [power.(2), level.(2)])

    assert {:ok, 3} = Store.revision(store)
    assert {:ok, persisted, 2} = Store.current(store, "light:desk", "power")
    assert persisted.source_sequence == 1

    assert {:ok, [4, 5]} = Store.record_batch(store, thing, [power.(4), level.(4)])
    {:ok, clock_db} = Sqlite3.open(path, mode: :readonly)

    {:ok, [[4, epoch, stamp], [5, epoch, stamp]]} =
      WotexHome.Durable.Store.SQL.query(
        clock_db,
        "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM journal WHERE revision IN (4,5) ORDER BY revision"
      )

    assert epoch == :sys.get_state(store).clock_epoch and is_integer(stamp)
    assert {:duplicate, [4, 5]} = Store.record_batch(store, thing, [power.(4), level.(4)])

    {:ok, [[4, ^epoch, ^stamp], [5, ^epoch, ^stamp]]} =
      WotexHome.Durable.Store.SQL.query(
        clock_db,
        "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM journal WHERE revision IN (4,5) ORDER BY revision"
      )

    assert {:ok, 6} = Store.record(store, power.(5), power_capability)

    assert {:error, :partial_batch_replay} =
             Store.record_batch(store, thing, [power.(5), level.(5)])

    assert {:ok, 6} = Store.revision(store)
    assert {:ok, persisted, 5} = Store.current(store, "light:desk", "brightness")
    assert persisted.source_sequence == 4
    assert {:error, :invalid_observation_batch} = Store.record_batch(store, thing, [nil])

    assert {:ok, [[5, ^epoch, ^stamp]]} =
             WotexHome.Durable.Store.SQL.query(
               clock_db,
               "SELECT revision, received_store_boot_epoch, received_store_monotonic_ms FROM observation_current WHERE capability_key='brightness'"
             )

    assert :ok = Store.validate_snapshot(clock_db)
    :ok = Sqlite3.close(clock_db)
    :ok = GenServer.stop(store)
  end

  test "one observation commits projection, journal and revision together", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    store = open_enrolled(path)

    assert {:ok, 1} = Store.revision(store)
    assert :not_found = Store.current(store, "light:desk", "power")
    assert {:ok, 2} = Store.record(store, observation, capability)
    assert {:ok, 2} = Store.revision(store)
    assert {:ok, persisted, 2} = Store.current(store, "light:desk", "power")
    assert persisted == observation
    assert {:duplicate, 2} = Store.record(store, observation, capability)
    assert {:ok, 2} = Store.revision(store)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "SELECT COUNT(*) FROM journal")
    assert {:ok, [[1]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
  end

  test "same sequence with changed content conflicts; older sequence is stale", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)

    assert {:ok, changed} =
             Observation.new(
               %{@report | "value" => %{"type" => "boolean", "value" => true}},
               capability
             )

    assert {:ok, older} = Observation.new(%{@report | "source_sequence" => 6}, capability)
    store = open_enrolled(path)

    assert {:ok, 2} = Store.record(store, observation, capability)
    assert {:error, :sequence_conflict} = Store.record(store, changed, capability)
    assert {:error, :stale_sequence} = Store.record(store, older, capability)

    assert {:error, :invalid_observation} =
             Store.record(
               store,
               %{observation | source_sequence: 9_223_372_036_854_775_808},
               capability
             )

    assert {:ok, 2} = Store.revision(store)
    assert {:ok, ^observation, 2} = Store.current(store, "light:desk", "power")
    :ok = GenServer.stop(store)
  end

  test "restart keeps source identity and refuses silent profile or epoch changes", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    first = open_enrolled(path)
    assert {:ok, 2} = Store.record(first, observation, capability)
    :ok = GenServer.stop(first)

    assert {:ok, second} = Store.start_link(path: path)
    assert {:ok, ^observation, 2} = Store.current(second, "light:desk", "power")

    assert {:error, :source_epoch_changed} =
             Store.record(
               second,
               %{observation | source_epoch: "device:2", source_sequence: 8},
               capability
             )

    assert {:ok, newer_profile} = Capability.new(%{@capability | "profile_ref" => "lifx.old:2"})

    assert {:error, :capability_mismatch} =
             Store.record(second, %{observation | source_sequence: 8}, newer_profile)

    next = %{
      observation
      | source_sequence: 8,
        received_time_utc_ms: 1_000_001,
        received_monotonic_ms: 101,
        value: %Value{kind: :boolean, data: true}
    }

    assert {:ok, 3} = Store.record(second, next, capability)
    assert {:ok, ^next, 3} = Store.current(second, "light:desk", "power")
    :ok = GenServer.stop(second)
  end

  test "a one-use epoch grant survives restart and rejects old-source replay", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, first_report} = Observation.new(@report, capability)
    first = open_enrolled(path)
    assert {:ok, 2} = Store.record(first, first_report, capability)

    assert {:error, :stale_source_epoch} =
             Store.authorize_source_epoch(first, "light:desk", "power", "device:1", "device:2", 1)

    assert {:ok, 3} =
             Store.authorize_source_epoch(first, "light:desk", "power", "device:1", "device:2", 2)

    assert {:ok, 3} =
             Store.authorize_source_epoch(first, "light:desk", "power", "device:1", "device:2", 2)

    :ok = GenServer.stop(first)
    assert {:ok, second} = Store.start_link(path: path)

    assert {:ok, rebooted} =
             Observation.new(
               %{
                 @report
                 | "source_epoch" => "device:2",
                   "source_sequence" => 0,
                   "received_time_utc_ms" => 1_000_100,
                   "received_monotonic_ms" => 200
               },
               capability
             )

    assert {:ok, 4} = Store.record(second, rebooted, capability)
    assert {:duplicate, 4} = Store.record(second, rebooted, capability)
    assert {:error, :source_epoch_changed} = Store.record(second, first_report, capability)
    assert {:ok, ^rebooted, 4} = Store.current(second, "light:desk", "power")
    :ok = GenServer.stop(second)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "SELECT COUNT(*) FROM source_epoch_grants")
    assert {:ok, [[0]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
  end

  test "a newer old-epoch report invalidates its pending grant", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, first_report} = Observation.new(@report, capability)
    store = open_enrolled(path)
    assert {:ok, 2} = Store.record(store, first_report, capability)

    assert {:ok, 3} =
             Store.authorize_source_epoch(store, "light:desk", "power", "device:1", "device:2", 2)

    assert {:ok, later_old} =
             Observation.new(
               %{@report | "source_sequence" => 8, "received_time_utc_ms" => 1_000_001},
               capability
             )

    assert {:ok, 4} = Store.record(store, later_old, capability)

    assert {:ok, rebooted} =
             Observation.new(
               %{
                 @report
                 | "source_epoch" => "device:2",
                   "source_sequence" => 0,
                   "received_time_utc_ms" => 1_000_100
               },
               capability
             )

    assert {:error, :source_epoch_changed} = Store.record(store, rebooted, capability)

    assert {:ok, 5} =
             Store.authorize_source_epoch(store, "light:desk", "power", "device:1", "device:2", 4)

    assert {:ok, 6} = Store.record(store, rebooted, capability)
    :ok = GenServer.stop(store)
  end

  test "revocation clears a pending source grant before restart", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    store = open_enrolled(path)
    assert {:ok, 2} = Store.record(store, observation, capability)

    assert {:ok, 3} =
             Store.authorize_source_epoch(store, "light:desk", "power", "device:1", "device:2", 2)

    assert {:ok, 4} = Store.revoke_thing(store, "light:desk")
    :ok = GenServer.stop(store)
    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, %{active_things: 0}} = Store.health(reopened)
    :ok = GenServer.stop(reopened)
  end

  test "in-memory storage is rejected for an authority store" do
    Process.flag(:trap_exit, true)
    assert {:error, :invalid_store_path} = Store.start_link(path: ":memory:")
  end

  test "a second local writer cannot start until the first releases its host lock", %{
    path: path
  } do
    assert {:ok, first} = Store.start_link(path: path)
    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, :already_running}} = Store.start_link(path: path)
    assert {:ok, 0} = Store.revision(first)
    :ok = GenServer.stop(first)
    assert {:ok, second} = Store.start_link(path: path)
    assert {:ok, 0} = Store.revision(second)
    :ok = GenServer.stop(second)
  end

  test "an unknown on-disk schema is refused instead of overwritten", %{path: path} do
    assert {:ok, db} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(db, "PRAGMA user_version=999")
    assert :ok = Sqlite3.close(db)

    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :unsupported_schema_version}} =
             Store.start_link(path: path)
  end

  test "version-three store migrates source grants without losing reports", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    store = open_enrolled(path)
    assert {:ok, 2} = Store.record(store, observation, capability)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               WotexHome.Test.SchemaFixtures.drop_portable_profiles() <>
                 "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; DROP INDEX observation_receipt_time; ALTER TABLE journal DROP COLUMN received_store_monotonic_ms; ALTER TABLE journal DROP COLUMN received_store_boot_epoch; ALTER TABLE observation_current DROP COLUMN received_store_monotonic_ms; ALTER TABLE observation_current DROP COLUMN received_store_boot_epoch; DROP TABLE request_causal_roots; DROP INDEX request_journal_cause; DROP TABLE rule_candidate_reviews; DROP TABLE operator_override_operations; DROP TABLE operator_override_leases; DROP TABLE profile_qualifications; DROP TABLE enrollment_review_history; DROP TABLE enrollment_bindings; DROP TABLE request_execution; DROP TABLE source_epoch_grants"
             )

    assert :ok = Sqlite3.execute(db, "PRAGMA user_version=3")
    :ok = Sqlite3.close(db)

    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, ^observation, 2} = Store.current(migrated, "light:desk", "power")
    :ok = GenServer.stop(migrated)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "PRAGMA user_version")
    assert {:ok, [[23]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
  end

  test "encrypted backup captures a consistent revision and rejects tampering", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    store = open_enrolled(path)
    assert {:ok, 2} = Store.record(store, observation, capability)
    destination = path <> ".backup"
    key = :crypto.strong_rand_bytes(32)

    assert {:ok, %{store_revision: 2, authority_epoch: 1, bytes: bytes}} =
             Store.export_backup(store, destination, key)

    assert bytes > 100
    assert {:ok, %{store_revision: 2, authority_epoch: 1}} = Backup.verify(destination, key)
    assert {:error, :invalid_backup} = Backup.verify(destination, :crypto.strong_rand_bytes(32))
    assert {:error, :backup_exists} = Store.export_backup(store, destination, key)
    assert {:ok, stat} = File.stat(destination)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert {:ok, encrypted} = File.read(destination)
    assert :nomatch == :binary.match(encrypted, "SQLite format 3")

    assert {:ok, 3} =
             Store.record(
               store,
               %{observation | source_sequence: 8, received_time_utc_ms: 1_000_001},
               capability
             )

    assert {:ok, %{store_revision: 2}} = Backup.verify(destination, key)

    prefix_size = byte_size(encrypted) - 1
    <<prefix::binary-size(prefix_size), last>> = encrypted
    File.write!(destination, <<prefix::binary, Bitwise.bxor(last, 1)>>)
    assert {:error, :invalid_backup} = Backup.verify(destination, key)
    :ok = GenServer.stop(store)
  end

  test "backup verification refuses broken foreign keys and missing Home tables", %{path: path} do
    store = open_enrolled(path)
    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path)
    key = :crypto.strong_rand_bytes(32)

    assert :ok = Sqlite3.execute(db, "PRAGMA user_version=3")
    old_schema_archive = path <> ".old-schema.backup"
    assert {:ok, _identity} = Backup.export(db, old_schema_archive, key)
    assert {:error, :invalid_backup} = Backup.verify(old_schema_archive, key)
    assert :ok = Sqlite3.execute(db, "PRAGMA user_version=4")

    assert :ok = Sqlite3.execute(db, "PRAGMA foreign_keys=OFF")

    assert :ok =
             Sqlite3.execute(
               db,
               "INSERT INTO principal_targets VALUES ('missing:principal', 'light:desk')"
             )

    orphan_archive = path <> ".orphan.backup"
    assert {:ok, _identity} = Backup.export(db, orphan_archive, key)
    assert {:error, :invalid_backup} = Backup.verify(orphan_archive, key)

    assert :ok = Sqlite3.execute(db, "DELETE FROM principal_targets")
    assert :ok = Sqlite3.execute(db, "DROP TABLE source_epoch_grants")
    missing_table_archive = path <> ".missing-table.backup"
    assert {:ok, _identity} = Backup.export(db, missing_table_archive, key)
    assert {:error, :invalid_backup} = Backup.verify(missing_table_archive, key)
    :ok = Sqlite3.close(db)
  end

  test "a corrupt current value disables further mutation", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    store = open_enrolled(path)
    assert {:ok, 2} = Store.record(store, observation, capability)

    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "UPDATE observation_current SET value_kind = 'invalid' WHERE thing_id = 'light:desk'"
             )

    assert :ok = Sqlite3.close(db)
    assert {:error, :corrupt_value} = Store.current(store, "light:desk", "power")
    assert {:error, :store_unavailable} = Store.record(store, observation, capability)
    :ok = GenServer.stop(store)
  end

  defp open_enrolled(path) do
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@capability]
             })

    assert {:ok, 1} = Store.enroll_thing(store, thing)
    store
  end
end
