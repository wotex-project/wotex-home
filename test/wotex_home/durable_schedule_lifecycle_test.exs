defmodule WotexHome.DurableScheduleLifecycleTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.{Mutation, Recovery.PrivateFile}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{ClockContext, Integrity, ScheduleLifecycle, SQL}
  alias WotexHome.Rules.OperationInput, as: RuleInput

  alias WotexHome.Schedules.{
    ActivationClock,
    ClockCodec,
    ClockOwner,
    Codec,
    OperationInput,
    Timezone
  }

  alias WotexHome.Semantics.Thing

  setup do
    Process.flag(:trap_exit, true)
    root = Path.join("/private/tmp", "woh-schedule-life-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:one",
        "role" => "Light",
        "profile_ref" => "fixture:power",
        "capabilities" => [
          %{
            "thing_id" => "light:one",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:power",
            "evidence_ref" => "fixture:one",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, manager, 2} =
      Store.provision_principal(
        store,
        "manager:one",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    {:ok, other, 3} =
      Store.provision_principal(
        store,
        "manager:other",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    %{root: root, path: path, store: store, manager: manager, other: other, thing: thing}
  end

  test "activation and suspension retain exact originals with a shared generation barrier", c do
    clock(c)
    admit(c)
    original = operation("activate", "schedule:activate", 4, 4)
    assert :not_found = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, active} = Store.change_schedule(c.store, c.manager, original)
    assert active.state == :activated && active.rule_generation == 1
    assert active.barrier_revision == 5 && active.revision == 6
    assert active.affected_requests == 0 && active.unknown_outcomes == 0
    assert {:ok, ^active} = Store.change_schedule(c.store, c.manager, original)
    assert {:ok, ^active} = Store.original_schedule_status(c.store, c.manager, original)

    assert {:ok, %{state: :active, rule_generation: 1}} =
             Store.schedule_status(c.store, c.manager)

    assert :not_found = Store.original_schedule_status(c.store, c.other, original)

    assert {:ok, %{dispatch_enabled: false, held_requests: 0, queued_requests: 0}} =
             Store.health(c.store)

    with_db(c.path, fn db ->
      assert {:ok, [[0]]} =
               SQL.query(db, "SELECT value FROM meta WHERE key='active_rule_admission'")

      assert {:ok, [[document, watermark]]} =
               SQL.query(
                 db,
                 "SELECT clock_document,initial_watermark FROM schedule_lifecycle_operations"
               )

      assert {:ok, snapshot, ^watermark} = ActivationClock.decode(document)
      assert elem(snapshot.interval, 1) == watermark
      assert :ok = Integrity.validate_snapshot(db)
    end)

    suspend = operation("suspend", "schedule:suspend", 6)

    assert {:ok, %{state: :suspended, rule_generation: 2, revision: 8} = receipt} =
             Store.change_schedule(c.store, c.manager, suspend)

    assert {:ok, ^receipt} = Store.change_schedule(c.store, c.manager, suspend)
    assert {:ok, ^active} = Store.original_schedule_status(c.store, c.manager, original)

    assert {:ok, %{state: :suspended, reason: :explicit_suspension}} =
             Store.schedule_status(c.store, c.manager)

    assert {:ok, 8} = Store.revision(c.store)
  end

  test "current author, qualified owned clock and exact CAS are required before fencing", c do
    admit(c)

    assert {:error, :temporal_clock_unavailable} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "activate:no-clock", 4, 4)
             )

    assert {:ok, 4} = Store.revision(c.store)
    clock(c)

    assert {:error, :resnapshot_required} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "activate:stale", 5, 4)
             )

    assert {:error, :permission_denied} =
             Store.change_schedule(
               c.store,
               c.other,
               operation("activate", "activate:other", 4, 4)
             )

    assert {:error, :stale_authority_epoch} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "activate:epoch", 4, 4, 2)
             )

    assert {:ok, 4} = Store.revision(c.store)
    assert {:ok, %{state: :inactive, rule_generation: 0}} = Store.rule_status(c.store, c.manager)
  end

  test "operation identity cannot cross the immutable admission and lifecycle ledgers", c do
    clock(c)
    admit(c)

    assert {:error, :schedule_operation_conflict} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "schedule:admit", 4, 4)
             )

    original = operation("activate", "schedule:activate", 4, 4)
    {:ok, receipt} = Store.change_schedule(c.store, c.manager, original)

    assert {:error, :schedule_operation_conflict} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("suspend", "schedule:activate", 4)
             )

    assert {:error, :schedule_operation_conflict} =
             Store.retain_schedule_content(
               c.store,
               c.manager,
               admission_document("schedule:activate", 6)
             )

    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, original)

    assert {:error, :schedule_operation_conflict} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("suspend", "schedule-withdraw:caller", 6)
             )

    assert {:ok, 6} = Store.revision(c.store)
  end

  test "activation rejects old held work and never refunds its causal root", c do
    clock(c)
    admit(c)

    {:ok, mutation} =
      Mutation.new(%{
        "api_version" => 1,
        "operation_id" => "manual:old",
        "authority_epoch" => 1,
        "expected_revision" => 0,
        "target_id" => "light:one",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, %{disposition: :held, revision: 5}} =
             Store.submit_request(c.store, c.manager, mutation)

    assert {:ok, %{affected_requests: 1, barrier_revision: 6, revision: 8}} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "schedule:activate", 5, 4)
             )

    assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced", revision: 7}} =
             Store.submit_request(c.store, c.manager, mutation)

    with_db(c.path, fn db ->
      assert {:ok, [[1]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM request_causal_roots WHERE operation_id='manual:old'"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "grant loss is durably withdrawn in the same transaction and restoration cannot resume it",
       c do
    clock(c)
    admit(c)
    original = operation("activate", "schedule:activate", 4, 4)
    {:ok, active} = Store.change_schedule(c.store, c.manager, original)
    assert {:ok, 7} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert {:ok, 9} = Store.revision(c.store)

    assert {:ok,
            %{
              state: :suspended,
              kind: "withdraw",
              reason: "permission_denied",
              rule_generation: 2
            }} = Store.schedule_status(c.store, c.manager)

    assert {:ok, ^active} = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, ^active} = Store.change_schedule(c.store, c.manager, original)

    assert {:ok, replacement, 10} =
             Store.grant_target_and_rotate(c.store, "manager:one", "light:one")

    assert {:ok, %{state: :suspended, kind: "withdraw", rule_generation: 2}} =
             Store.schedule_status(c.store, replacement)

    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "an existing rule generation barrier supersedes a schedule without fencing the replacement",
       c do
    clock(c)
    admit(c)

    {:ok, _} =
      Store.change_schedule(c.store, c.manager, operation("activate", "schedule:activate", 4, 4))

    assert {:ok, %{rule_generation: 2, store_revision: 7}} =
             Store.fence_rule_generation(c.store, 6, 1)

    assert {:ok, %{state: :suspended, reason: :stale_rule_generation}} =
             Store.schedule_status(c.store, c.manager)

    assert {:ok, 7} = Store.revision(c.store)

    with_db(c.path, fn db ->
      assert {:ok, [[1]]} = SQL.query(db, "SELECT COUNT(*) FROM schedule_lifecycle_operations")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "a failed immutable publication rolls back the barrier and survives restart", c do
    clock(c)
    admit(c)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER lifecycle_fault BEFORE INSERT ON schedule_lifecycle_operations BEGIN SELECT RAISE(ABORT,'injected_lifecycle_fault'); END"
        )
    end)

    assert {:error, :store_unavailable} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "schedule:activate", 4, 4)
             )

    with_db(c.path, fn db ->
      assert {:ok, [[4, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='rule_generation'),(SELECT COUNT(*) FROM schedule_lifecycle_operations)"
               )

      :ok = Sqlite3.execute(db, "DROP TRIGGER lifecycle_fault")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    :ok = GenServer.stop(c.store)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :restarted
      )

    assert {:ok, 4} = Store.revision(restarted)

    assert :not_found =
             Store.original_schedule_status(
               restarted,
               c.manager,
               operation("activate", "schedule:activate", 4, 4)
             )
  end

  test "same-owner restart retains immutable activation but requires fresh private clock custody",
       c do
    clock(c)
    admit(c)
    original = operation("activate", "schedule:activate", 4, 4)
    {:ok, active} = Store.change_schedule(c.store, c.manager, original)
    :ok = GenServer.stop(c.store)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :restarted
      )

    assert {:ok, ^active} = Store.original_schedule_status(restarted, c.manager, original)

    assert {:ok, %{state: :suspended, reason: :temporal_clock_unavailable}} =
             Store.schedule_status(restarted, c.manager)

    clock(%{c | store: restarted}, :clock_restart)

    assert {:ok, %{state: :active, initial_watermark: watermark}} =
             Store.schedule_status(restarted, c.manager)

    assert watermark == active.initial_watermark
    assert {:ok, 6} = Store.revision(restarted)
  end

  test "clock withdrawal blocks current readiness while exact original recovery needs no clock",
       c do
    clock(c)
    admit(c)
    original = operation("activate", "schedule:activate", 4, 4)
    {:ok, active} = Store.change_schedule(c.store, c.manager, original)
    assert :ok = Store.invalidate_temporal_clock(c.store)

    assert {:ok, %{state: :suspended, reason: :temporal_clock_unavailable}} =
             Store.schedule_status(c.store, c.manager)

    assert {:ok, ^active} = Store.change_schedule(c.store, c.manager, original)
    assert {:ok, ^active} = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, 6} = Store.revision(c.store)
  end

  test "reviewed calendar bytes must equal the actual installed timezone at activation", c do
    clock(c)
    {:ok, zone} = Timezone.read("Etc/UTC")

    document =
      admission_document("schedule:calendar", 3, [
        "daily",
        "Etc/UTC",
        zone.digest,
        "12:00:00",
        0,
        nil
      ])

    assert {:ok, %{revision: 4}} =
             Store.retain_schedule_content(c.store, c.manager, document, zone)

    assert {:ok, %{revision: 6}} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "schedule:activate", 4, 4)
             )

    assert :ok = with_db(c.path, &Integrity.validate_snapshot/1)
  end

  test "full archive preserves lifecycle and quarantine never restores active clock authority",
       c do
    clock(c)
    admit(c)

    {:ok, _} =
      Store.change_schedule(c.store, c.manager, operation("activate", "schedule:activate", 4, 4))

    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "home.wohb")
    assert {:ok, _} = with_db(c.path, &Backup.export(&1, archive, key))
    assert {:ok, %{store_revision: 6, authority_epoch: 1}} = Backup.verify(archive, key)
    restored = Path.join(c.root, "quarantine.sqlite")
    assert {:ok, _} = Backup.stage_restore(archive, key, restored)

    with_db(restored, fn db ->
      assert {:ok, [[1]]} = SQL.query(db, "SELECT COUNT(*) FROM schedule_lifecycle_operations")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: restored)
  end

  test "actual schema 24 migration adds no authority and damaged lifecycle rolls back DDL", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(db, "DROP TABLE schedule_lifecycle_operations; PRAGMA user_version=24")

      assert :ok = Integrity.validate_snapshot(db)
    end)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :migrated
      )

    assert {:ok, 3} = Store.revision(restarted)

    assert {:ok, %{state: :inactive, rule_generation: 0}} =
             Store.rule_status(restarted, c.manager)

    :ok = GenServer.stop(restarted)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_lifecycle_operations; PRAGMA user_version=24; INSERT INTO authority_journal VALUES (4,'schedule_activated','unexplained'); UPDATE meta SET value=4 WHERE key='revision'"
        )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:error, {:store_open_failed, {:schema_failed, _}}} = Store.start_link(path: c.path)

    with_db(c.path, fn db ->
      assert {:ok, [[24]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name='schedule_lifecycle_operations'"
               )
    end)
  end

  test "damaged historical input, barrier and clock watermark fail live writes and restart", c do
    clock(c)
    admit(c)

    {:ok, _} =
      Store.change_schedule(c.store, c.manager, operation("activate", "schedule:activate", 4, 4))

    with_db(c.path, fn db ->
      assert {:ok, []} =
               SQL.query(
                 db,
                 "UPDATE schedule_lifecycle_operations SET initial_watermark=initial_watermark+1"
               )

      assert {:error, :corrupt_schedule_lifecycle} = Integrity.validate_snapshot(db)
    end)

    assert {:error, :corrupt_schedule_lifecycle} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("suspend", "schedule:suspend", 6)
             )

    assert {:ok, %{writable: false}} = Store.health(c.store)
    :ok = GenServer.stop(c.store)

    assert {:error, {:store_open_failed, :corrupt_schedule_lifecycle}} =
             Store.start_link(path: c.path)
  end

  test "clock loss after the generation barrier rolls back the complete activation", c do
    clock(c)
    admit(c)
    {:ok, snapshot} = Store.temporal_clock_snapshot(c.store)
    reads = :counters.new(1, [])

    {:ok, context} =
      ClockContext.new(
        fn -> {snapshot.sample["boot_epoch"], snapshot.now_ms} end,
        fn ->
          :counters.add(reads, 1, 1)

          if :counters.get(reads, 1) == 1,
            do: {:ok, snapshot},
            else: {:error, :temporal_clock_unavailable}
        end,
        fn _ -> {:ok, nil} end
      )

    original = operation("activate", "schedule:clock-lost", 4, 4)

    with_db(c.path, fn db ->
      assert {:error, {:policy, :temporal_clock_unavailable}} =
               SQL.transaction(db, &ScheduleLifecycle.change(&1, c.manager, original, context))

      assert {:ok, [[4, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='rule_generation'),(SELECT COUNT(*) FROM schedule_lifecycle_operations)"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert :not_found = Store.original_schedule_status(c.store, c.manager, original)
  end

  test "public capacity preserves exact recovery and reserves withdrawal history", c do
    clock(c)
    admit(c)

    with_db(c.path, fn db ->
      {:ok, 1_922} =
        SQL.transaction(db, fn db ->
          Enum.each(1..959, fn index ->
            expected = 4 + (index - 1) * 2
            operation = "schedule:capacity:#{index}"
            document = operation("suspend", operation, expected)

            {:ok, []} =
              SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
                expected + 1,
                "rule_generation_fenced",
                "rules:empty"
              ])

            {:ok, []} =
              SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
                expected + 2,
                "schedule_suspended",
                "manager:one/1/#{operation}"
              ])

            {:ok, []} =
              SQL.query(
                db,
                "INSERT INTO schedule_lifecycle_operations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                [
                  "manager:one",
                  1,
                  operation,
                  "suspend",
                  expected,
                  document,
                  0,
                  index - 1,
                  index,
                  expected + 1,
                  expected + 2,
                  0,
                  0,
                  nil,
                  nil,
                  -1
                ]
              )
          end)

          {:ok, []} = SQL.query(db, "UPDATE meta SET value=1922 WHERE key='revision'")
          {:ok, []} = SQL.query(db, "UPDATE meta SET value=959 WHERE key='rule_generation'")
          assert :ok = Integrity.validate_snapshot(db)
          {:commit, 1_922}
        end)
    end)

    original = operation("activate", "schedule:capacity:active", 1_922, 4)

    assert {:ok, %{rule_generation: 960, revision: 1_924} = active} =
             Store.change_schedule(c.store, c.manager, original)

    assert {:error, :schedule_lifecycle_capacity} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("suspend", "schedule:capacity:full", 1_924)
             )

    assert {:ok, ^active} = Store.change_schedule(c.store, c.manager, original)
    assert {:ok, 1_925} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert {:ok, 1_927} = Store.revision(c.store)

    assert {:ok, %{kind: "withdraw", state: :suspended, rule_generation: 961}} =
             Store.schedule_status(c.store, c.manager)

    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  defp admit(c),
    do: Store.retain_schedule_content(c.store, c.manager, admission_document("schedule:admit", 3))

  defp admission_document(operation, expected, trigger \\ ["interval", 100_000, 60_000, 0, nil]) do
    {:ok, rule} =
      RuleInput.source("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "rule:body",
        "expected_revision" => 3,
        "rule_id" => "rule:one",
        "source_revision" => 1,
        "target_id" => "light:one",
        "on" => true
      })

    {:ok, source} =
      Codec.encode(%{
        "id" => "schedule:one",
        "source_revision" => 1,
        "author_id" => "manager:one",
        "rule_id" => "rule:one",
        "rule_source_digest" => Codec.hash(rule),
        "target_id" => "light:one",
        "resource_revision" => 0,
        "late_window_ms" => 10_000,
        "uncertainty_tolerance_ms" => 1_000,
        "trigger" => trigger
      })

    {:ok, document} =
      OperationInput.encode("admit", %{
        "authority_epoch" => 1,
        "operation_id" => operation,
        "expected_revision" => expected,
        "source_document" => source,
        "rule_document" => rule
      })

    document
  end

  defp operation(kind, operation, expected, admission \\ nil, epoch \\ 1) do
    input = %{
      "authority_epoch" => epoch,
      "operation_id" => operation,
      "expected_revision" => expected
    }

    input =
      if kind == "activate", do: Map.put(input, "admission_revision", admission), else: input

    {:ok, document} = OperationInput.encode(kind, input)
    document
  end

  defp clock(c, id \\ :clock) do
    requests = Path.join(c.root, Atom.to_string(id))
    File.mkdir!(requests)
    File.chmod!(requests, 0o700)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, runtime} = ClockOwner.runtime_digest()

    policy = %{
      source_id: "clock:software-fixture",
      issuer_id: "issuer:software-fixture",
      public_key: public,
      issuer_generation: 1,
      procedure_ref: "procedure:software-only",
      qualification_digest: String.duplicate("a", 64),
      runtime_digest: runtime,
      maximum_response_ms: 30_000,
      maximum_age_ms: 120_000,
      maximum_error_ms: 0,
      drift_ppm: 10,
      maximum_discontinuity_ms: 20,
      monotonic_policy: "invalidate_on_discontinuity"
    }

    {:ok, document} = ClockCodec.policy_document(policy)
    file = Path.join(c.root, Atom.to_string(id) <> ".policy")
    :ok = PrivateFile.write(file, document, 4_096)

    owner =
      start_supervised!(
        Supervisor.child_spec(
          {ClockOwner, store: c.store, operator: self(), root: requests, policy_file: file},
          id: id,
          restart: :temporary
        )
      )

    {:ok, request} = ClockOwner.request(owner)
    {:ok, document} = PrivateFile.read(request.request_file, 4_096)
    {:ok, input} = ClockCodec.decode_request(document)

    record =
      Map.merge(input, %{
        "procedure_ref" => policy.procedure_ref,
        "observed_utc_ms" => System.system_time(:millisecond)
      })

    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(record, :crypto.sign(:eddsa, :none, payload, [private, :ed25519]))

    assert {:ok, _} = ClockOwner.approve(owner, request.request_digest, package)
    assert :ok = Store.attach_temporal_clock(c.store, owner)
    owner
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
