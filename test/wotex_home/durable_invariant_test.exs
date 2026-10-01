defmodule WotexHome.DurableInvariantTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, InvariantWriter}
  alias WotexHome.Rules.Predicate
  alias WotexHome.Semantics.{Observation, Thing}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "home-invariant-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!({Store, path: path})
    {:ok, thing} = thing()
    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, credential, 2} =
      Store.provision_principal(store, "policy:owner", ["read", "policy:manage"], [thing.id])

    %{
      directory: directory,
      path: path,
      store: store,
      thing: thing,
      credential: credential,
      authority: Authority.new(store: store)
    }
  end

  test "replacement is revision fenced, immutable and retryable across restart", c do
    predicate = predicate(c.thing.id, true)
    assert {:ok, receipt} = install(c, "policy:1", 2, 0, predicate)
    assert receipt.revision == 3 and receipt.scope == :reported_constraint_only
    assert {:ok, ^receipt} = install(c, "policy:1", 2, 0, predicate)

    assert {:error, :invariant_operation_conflict} =
             install(c, "policy:1", 2, 0, predicate(c.thing.id, false))

    assert {:error, :resnapshot_required} = install(c, "policy:2", 2, 3, predicate)
    assert {:error, :invariant_revision_changed} = install(c, "policy:2", 3, 0, predicate)

    assert {:error, :stale_authority_epoch} =
             Authority.set_invariant(
               c.authority,
               c.credential,
               2,
               "policy:2",
               3,
               c.thing.id,
               3,
               predicate
             )

    assert {:ok, 3} = Store.revision(c.store)
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, path: c.path})
    authority = Authority.new(store: store)

    assert {:ok, ^receipt} =
             Authority.set_invariant(
               authority,
               c.credential,
               1,
               "policy:1",
               2,
               c.thing.id,
               0,
               predicate
             )

    assert {:ok, ^receipt} = Authority.invariant_status(authority, c.credential, 1, "policy:1")

    assert {:ok, %{revision: 4, previous_revision: 3}} =
             Authority.set_invariant(
               authority,
               c.credential,
               1,
               "policy:2",
               3,
               c.thing.id,
               3,
               literal()
             )

    assert :allow = decision(c.path, store, c.thing.id)
    assert :ok = integrity(c.path)
  end

  test "reported facts distinguish allow, deny, unknown, expiry and lab origin", c do
    assert {:ok, _} = install(c, "policy:1", 2, 0, predicate(c.thing.id, true))
    assert :unknown = decision(c.path, c.store, c.thing.id)
    assert {:ok, _} = record(c, 1, false)
    assert :deny = decision(c.path, c.store, c.thing.id)
    assert {:ok, _} = record(c, 2, true)
    assert :allow = decision(c.path, c.store, c.thing.id)
    :sys.replace_state(c.store, &%{&1 | clock_origin: &1.clock_origin - 5_001})
    assert :unknown = decision(c.path, c.store, c.thing.id)
    assert {:ok, _} = record(c, 3, true, "synthetic_lab")
    assert :unknown = decision(c.path, c.store, c.thing.id)
    assert {:ok, _} = record(c, 4, true)
    assert :allow = decision(c.path, c.store, c.thing.id)
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, path: c.path})
    assert :unknown = decision(c.path, store, c.thing.id)
  end

  test "negation preserves missing facts and cannot authorize from absence", c do
    {:ok, predicate} =
      Predicate.new(%{
        "op" => "not",
        "predicate" => %{
          "op" => "eq",
          "fact" => %{"thing_id" => c.thing.id, "capability_key" => "power"},
          "value" => %{"type" => "boolean", "value" => false}
        }
      })

    assert {:ok, _} = install(c, "policy:1", 2, 0, predicate)
    assert :unknown = decision(c.path, c.store, c.thing.id)
  end

  test "policy authority, explicit grants and exact typed readable declarations are required",
       c do
    for {id, permissions} <- [
          {"reader:1", ["read"]},
          {"controller:1", ["control:ordinary"]},
          {"policy:no-read", ["policy:manage"]}
        ] do
      {:ok, credential, revision} =
        Store.provision_principal(c.store, id, permissions, [c.thing.id])

      assert {:error, :permission_denied} =
               Authority.set_invariant(
                 c.authority,
                 credential,
                 1,
                 "policy:1",
                 revision,
                 c.thing.id,
                 0,
                 literal()
               )
    end

    {:ok, revision} = Store.revision(c.store)

    assert {:error, :permission_denied} =
             install(c, "policy:1", revision, 0, predicate("light:ungranted", true))

    {:ok, wrong_type} =
      Predicate.new(%{
        "op" => "eq",
        "fact" => %{"thing_id" => c.thing.id, "capability_key" => "power"},
        "value" => %{"type" => "kelvin", "kelvin" => 3000}
      })

    assert {:error, :invalid_invariant_artifact} = install(c, "policy:1", revision, 0, wrong_type)

    assert {:error, :invalid_invariant_artifact} =
             install(c, "policy:1", revision, 0, predicate(c.thing.id, true, "absent"))

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  test "author revocation and declaration drift keep a retained restriction unknown", c do
    assert {:ok, receipt} = install(c, "policy:1", 2, 0, literal())
    assert :allow = decision(c.path, c.store, c.thing.id)
    assert {:ok, _} = Store.revoke_target_grant(c.store, "policy:owner", c.thing.id)
    assert :unknown = decision(c.path, c.store, c.thing.id)
    assert {:ok, ^receipt} = Authority.invariant_status(c.authority, c.credential, 1, "policy:1")
    assert {:ok, _} = Store.revoke_principal(c.store, "policy:owner")
    assert :unknown = decision(c.path, c.store, c.thing.id)

    assert {:error, :unauthorized} =
             Authority.invariant_status(c.authority, c.credential, 1, "policy:1")

    assert :ok = integrity(c.path)
  end

  test "encrypted recovery retains history but does not renew reports or remove quarantine", c do
    assert {:ok, _} = install(c, "policy:1", 2, 0, predicate(c.thing.id, true))
    assert {:ok, _} = record(c, 1, true)
    archive = Path.join(c.directory, "policy.backup")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Store.export_backup(c.store, archive, key)

    assert {:ok,
            %{
              dependencies: %{
                invariant_policy_operation_rows: 1,
                invariant_reports_reactivate_on_restore: false
              }
            }} = Backup.verify(archive, key)

    destination = Path.join(c.directory, "restore.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(archive, key, destination)
    assert :ok = integrity(destination)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: destination)
  end

  for {name, sql} <- [
        {"missing journal",
         "DELETE FROM authority_journal WHERE event_type='invariant_policy_set'"},
        {"changed source", "UPDATE invariant_policy_operations SET source_document='{}'"},
        {"changed digest",
         "UPDATE invariant_policy_operations SET artifact_digest=lower(hex(zeroblob(32)))"},
        {"wrong predecessor", "UPDATE invariant_policy_operations SET previous_revision=1"}
      ] do
    @sql sql
    test "#{name} blocks live decisions, backup and startup", c do
      assert {:ok, _} = install(c, "policy:1", 2, 0, literal())
      {:ok, db} = Sqlite3.open(c.path)
      :ok = Sqlite3.execute(db, @sql)

      assert {:error, :corrupt_invariant} =
               InvariantWriter.decision(db, c.thing.id, {"store:fixture", 0})

      assert {:error, _} = Integrity.validate_snapshot(db)
      archive = Path.join(c.directory, "invalid.backup")
      key = :crypto.strong_rand_bytes(32)
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      :ok = Sqlite3.close(db)
      :ok = stop_supervised(Store)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  test "version fifteen migrates with an empty policy history and no new authority", c do
    :ok = stop_supervised(Store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE request_rule_origins; DROP TABLE rule_activations; DROP TABLE rule_admissions; ALTER TABLE request_causal_roots DROP COLUMN rule_generation; ALTER TABLE request_causal_roots DROP COLUMN rule_admission_revision; DELETE FROM meta WHERE key='active_rule_admission'; DROP TABLE invariant_policy_operations; PRAGMA user_version=15"
      )

    assert :ok = Integrity.validate_snapshot(db)
    :ok = Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path})
    assert {:ok, 2} = Store.revision(store)
    assert :allow = decision(c.path, store, c.thing.id)
    assert :ok = integrity(c.path)
  end

  defp install(c, id, revision, previous, predicate),
    do:
      Authority.set_invariant(
        c.authority,
        c.credential,
        1,
        id,
        revision,
        c.thing.id,
        previous,
        predicate
      )

  defp literal do
    {:ok, predicate} = Predicate.new(%{"op" => "literal_true"})
    predicate
  end

  defp predicate(id, value, key \\ "power") do
    {:ok, predicate} =
      Predicate.new(%{
        "op" => "eq",
        "fact" => %{"thing_id" => id, "capability_key" => key},
        "value" => %{"type" => "boolean", "value" => value}
      })

    predicate
  end

  defp decision(path, store, id) do
    state = :sys.get_state(store)
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, decision} =
        InvariantWriter.decision(
          db,
          id,
          {state.clock_epoch, System.monotonic_time(:millisecond) - state.clock_origin}
        )

      decision
    after
      Sqlite3.close(db)
    end
  end

  defp integrity(path) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      Integrity.validate_snapshot(db)
    after
      Sqlite3.close(db)
    end
  end

  defp record(c, sequence, value, trust \\ "unauthenticated_local") do
    capability = c.thing.capabilities["power"]

    {:ok, observation} =
      Observation.new(
        %{
          "thing_id" => c.thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => value},
          "quality" => "reported",
          "trust" => trust,
          "source_epoch" => "device:1",
          "source_sequence" => sequence,
          "boot_epoch" => "adapter:1",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000_000,
          "received_monotonic_ms" => 0
        },
        capability
      )

    Store.record(c.store, observation, capability)
  end

  defp thing,
    do:
      Thing.new(%{
        "id" => "light:policy",
        "role" => "Light",
        "profile_ref" => "fixture:policy:1",
        "capabilities" => [
          %{
            "thing_id" => "light:policy",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:policy:1",
            "evidence_ref" => "cohort:policy",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })
end
