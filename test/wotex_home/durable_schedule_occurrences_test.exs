Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.DurableScheduleOccurrencesTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Recovery.PrivateFile
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}

  alias WotexHome.Durable.Store.{
    ClockContext,
    Integrity,
    ScheduleLifecycle,
    ScheduleOccurrences,
    SQL
  }

  alias WotexHome.Rules.OperationInput, as: RuleInput

  alias WotexHome.Schedules.{
    ActivationClock,
    ClockCodec,
    ClockOwner,
    Codec,
    Consideration,
    OperationInput
  }

  alias WotexHome.Semantics.Thing

  setup do
    Process.flag(:trap_exit, true)

    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "woh-schedule-life-#{System.unique_integer([:positive])}"
      )

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

  test "actual private clock polling creates one held request with temporal provenance",
       c do
    activate(c, 96_000)
    assert {:ok, %{state: :idle, watermark: watermark}} = Store.consider_schedule(c.store)
    assert {:ok, 6} = Store.revision(c.store)
    Process.sleep(4_300)

    assert {:ok,
            %{
              state: :held,
              decision: "eligible",
              reason: nil,
              revision: 9
            } = receipt} = Store.consider_schedule(c.store)

    assert receipt.previous_watermark == watermark
    assert receipt.occurrence_id =~ "occ:"
    assert receipt.causal_id =~ "cause:schedule:"
    assert {:ok, %{state: :idle}} = Store.consider_schedule(c.store)
    assert {:ok, 9} = Store.revision(c.store)

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    assert :not_found =
             Store.original_schedule_occurrence(c.store, c.other, receipt.occurrence_id)

    assert {:error, :invalid_schedule_occurrence} =
             Store.original_schedule_occurrence(c.store, c.manager, "occ:bad")

    with_db(c.path, fn db ->
      assert {:ok, [[1, 1, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM request_receipts),(SELECT COUNT(*) FROM request_causal_roots),(SELECT COUNT(*) FROM request_execution)"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "serialized competing polls and backward correction preserve the retained head", c do
    activate(c)
    snapshot = snapshot(c, 100_001, 0, 10)
    tasks = for _ <- 1..8, do: Task.async(fn -> consider(c, snapshot) end)
    receipts = Enum.map(tasks, &Task.await(&1, 20_000))
    assert 1 == Enum.count(receipts, &match?({:ok, %{state: :held}}, &1))
    assert 7 == Enum.count(receipts, &match?({:ok, %{state: :idle}}, &1))
    assert {:ok, 9} = Store.revision(c.store)
    assert {:ok, %{state: :idle}} = consider(c, snapshot(c, 99_999, 0, 20))
    assert {:ok, %{state: :idle}} = consider(c, snapshot(c, 100_001, 0, 30))

    with_db(c.path, fn db ->
      assert {:ok, [[6, 100_001, 7]]} = SQL.query(db, "SELECT * FROM schedule_watermarks")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "uncertain candidates are consumed and long downtime retains one missed range", c do
    activate(c)

    assert {:ok,
            %{decision: "uncertain", reason: "clock_uncertain", watermark: 100_001, revision: 7}} =
             consider(c, snapshot(c, 100_001, 2_001, 10))

    assert {:ok, %{state: :idle}} = consider(c, snapshot(c, 100_001, 0, 20))

    assert {:ok,
            %{
              state: :missed,
              occurrence_id: nil,
              missed_range: [100_001, 99_989_999],
              watermark: 99_999_999,
              revision: 8
            }} = consider(c, snapshot(c, 99_999_999, 0, 30))

    assert {:ok, %{state: :idle}} = consider(c, snapshot(c, 99_999_999, 0, 40))

    with_db(c.path, fn db ->
      assert {:ok, [[2]]} = SQL.query(db, "SELECT COUNT(*) FROM schedule_considerations")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "same-owner restart requires fresh clock and cannot replay a retained UTC coordinate", c do
    activate(c)
    assert {:ok, receipt} = consider(c, snapshot(c, 100_001, 0, 10))
    :ok = GenServer.stop(c.store)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :restarted
      )

    c = %{c | store: restarted}

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(restarted, c.manager, receipt.occurrence_id)

    assert {:error, :temporal_clock_unavailable} = Store.consider_schedule(restarted)
    clock(c, :restarted_clock, 100_001)
    assert {:ok, %{state: :idle, watermark: 100_001}} = Store.consider_schedule(restarted)
    assert {:ok, 9} = Store.revision(restarted)
    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "grant loss stays suspended after restoration and original occurrence remains private history",
       c do
    activate(c)
    assert {:ok, receipt} = consider(c, snapshot(c, 100_001, 0, 10))
    assert {:ok, 11} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert {:ok, 13} = Store.revision(c.store)
    assert {:ok, %{state: :inactive}} = Store.consider_schedule(c.store)

    assert {:ok, replacement, 14} =
             Store.grant_target_and_rotate(c.store, "manager:one", "light:one")

    assert {:ok, %{state: :inactive}} = Store.consider_schedule(c.store)

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(c.store, replacement, receipt.occurrence_id)

    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "failed cursor publication rolls back occurrence, authority journal and watermark", c do
    activate(c)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER cursor_fault BEFORE INSERT ON schedule_watermarks BEGIN SELECT RAISE(ABORT,'injected_cursor_fault'); END"
        )
    end)

    assert {:error, _} = consider(c, snapshot(c, 100_001, 0, 10))

    with_db(c.path, fn db ->
      assert {:ok, [[6, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks)"
               )

      :ok = Sqlite3.execute(db, "DROP TRIGGER cursor_fault")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, %{state: :held, revision: 9}} = consider(c, snapshot(c, 100_001, 0, 20))
  end

  test "a changed private clock between calculation and publication rolls back consumption", c do
    activate(c)
    original = snapshot(c, 100_001, 0, 10)

    changed = %{
      original
      | scope: Map.put(original.scope, "clock_generation", 2),
        sample: Map.put(original.sample, "generation", 2)
    }

    unavailable = %{
      original
      | reason: :temporal_clock_unavailable,
        interval: nil,
        sample: %{
          original.sample
          | "wall_confidence" => "unqualified",
            "utc_lower_ms" => nil,
            "utc_upper_ms" => nil,
            "qualification_digest" => nil,
            "monotonic_continuous" => false
        }
    }

    for changed <- [changed, unavailable] do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      callback = fn ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        {:ok, if(n == 0, do: original, else: changed)}
      end

      {:ok, context} =
        ClockContext.new(
          fn -> {original.scope["store_boot_epoch"], original.now_ms} end,
          callback,
          fn _ -> {:ok, nil} end
        )

      assert {:error, :clock_changed} = consider_context(c, context)
      assert {:ok, 6} = Store.revision(c.store)
      Agent.stop(counter)
    end

    with_db(c.path, fn db ->
      assert {:ok, [[0]]} = SQL.query(db, "SELECT COUNT(*) FROM schedule_considerations")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "encrypted recovery retains nonempty occurrence and cursor without clock custody", c do
    activate(c)
    assert {:ok, receipt} = consider(c, snapshot(c, 100_001, 0, 10))
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "snapshot.wohbk")
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:ok, %{dependencies: dependencies}} = Backup.verify(archive, key)
    assert dependencies.schedule_consideration_rows == 1
    assert dependencies.schedule_watermark_rows == 1
    assert dependencies.temporal_clock_authority_included == false
    restored = Path.join(c.root, "quarantine.sqlite")
    assert {:ok, _} = Backup.stage_restore(archive, key, restored)

    with_db(restored, fn db ->
      assert {:ok, [[receipt.watermark, receipt.consideration_revision]]} ==
               SQL.query(db, "SELECT considered_through,head_revision FROM schedule_watermarks")

      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: restored)
  end

  @tag timeout: 120_000
  test "real occurrence ceiling refuses new work while preserving every original and cursor", c do
    activate(c)
    first = snapshot(c, 100_000, 0, 10)
    caller = self()

    :sys.replace_state(
      c.store,
      fn state ->
        result =
          SQL.transaction(state.db, fn db ->
            {:ok, activation} = ScheduleLifecycle.retained_activation(db, 6)
            {:ok, artifact} = WotexHome.Durable.Store.ScheduleWriter.retained_admission(db, 4)

            {watermark, first_id} =
              Enum.reduce(0..4_095, {activation.watermark, nil}, fn index, {previous, first_id} ->
                due = 100_000 + index * 60_000
                now = first.now_ms + index

                snapshot = %{
                  first
                  | now_ms: now,
                    interval: {due, due},
                    sample: %{
                      first.sample
                      | "sampled_monotonic_ms" => now,
                        "utc_lower_ms" => due,
                        "utc_upper_ms" => due
                    }
                }

                {:ok, record} =
                  WotexHome.Schedules.Consideration.build(
                    activation,
                    artifact,
                    snapshot,
                    previous
                  )

                {:ok, revision} = WotexHome.Durable.Store.Journal.next_revision(db)

                :ok =
                  WotexHome.Durable.Store.Journal.authority_event(
                    db,
                    revision,
                    "schedule_occurrence_considered",
                    record.occurrence_id
                  )

                values =
                  Enum.map(WotexHome.Schedules.Consideration.fields(), &record[&1]) ++ [revision]

                {:ok, []} =
                  SQL.query(
                    db,
                    "INSERT INTO schedule_considerations VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    values
                  )

                {record.watermark, first_id || record.occurrence_id}
              end)

            {:ok, []} =
              SQL.query(db, "INSERT INTO schedule_watermarks VALUES (?,?,?)", [
                6,
                watermark,
                4_102
              ])

            assert :ok = Integrity.validate_snapshot(db)
            {:commit, {watermark, first_id}}
          end)

        send(caller, {:capacity_seed, result})
        state
      end,
      90_000
    )

    assert_receive {:capacity_seed, {:ok, {watermark, first_id}}}

    assert {:error, :schedule_occurrence_capacity} =
             consider(c, snapshot(c, watermark + 60_000, 0, 5_000))

    assert {:ok, %{revision: 7}} =
             Store.original_schedule_occurrence(c.store, c.manager, first_id)

    assert {:ok, 4_102} = Store.revision(c.store)

    with_db(c.path, fn db ->
      assert {:ok, [[4_096]]} = SQL.query(db, "SELECT COUNT(*) FROM schedule_considerations")

      assert {:ok, [[watermark, 4_102]]} ==
               SQL.query(db, "SELECT considered_through,head_revision FROM schedule_watermarks")
    end)
  end

  @tag scheduled_capture: true
  test "scheduled selection pages original temporal work without author or clock inputs", c do
    activate(c)

    originals =
      for index <- 0..16 do
        assert {:ok, %{state: :held} = original} =
                 consider(c, snapshot(c, 100_001 + index * 60_000, 0, index + 10))

        original
      end

    assert {:ok, before} = Store.revision(c.store)
    authority = Authority.new(store: c.store)

    assert {:ok,
            %{requests: first, has_more: true, next_revision: cursor, window_revision: ^before}} =
             Authority.pending_scheduled_power(authority)

    assert Enum.map(first, & &1.operation_id) ==
             Enum.map(Enum.take(originals, 16), & &1.occurrence_id)

    assert Enum.all?(first, &(&1.principal_id == "manager:one" and &1.authority_epoch == 1))
    final_id = List.last(originals).occurrence_id

    assert {:ok, %{requests: [%{operation_id: ^final_id}], has_more: false, next_revision: last}} =
             Authority.pending_scheduled_power(authority, cursor)

    assert {:ok, %{requests: []}} = Store.pending_scheduled_power(c.store, last)
    assert {:error, :invalid_guard_input} = Store.pending_scheduled_power(c.store, -1)
    assert {:ok, %{requests: []}} = Store.pending_explicit_power(c.store)
    assert {:ok, ^before} = Store.revision(c.store)
    first_id = hd(originals).occurrence_id

    assert {:ok, %{disposition: :rejected}} =
             Store.cancel_request(c.store, c.manager, 1, first_id)

    assert {:ok, %{requests: retained}} = Store.pending_scheduled_power(c.store)
    refute Enum.any?(retained, &(&1.operation_id == first_id))
  end

  test "schedule advancement is bounded to sixteen and a mid-batch failure rolls back every closure",
       c do
    activate(c)

    originals =
      for index <- 0..16 do
        assert {:ok, %{state: :held} = original} =
                 consider(c, snapshot(c, 100_001 + index * 60_000, 0, index + 10))

        original
      end

    {:ok, before} = Store.revision(c.store)

    with_db(c.path, fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER advance_batch_fault BEFORE INSERT ON request_journal WHEN NEW.reason='schedule_blocked:occurrence_expired' AND (SELECT COUNT(*) FROM request_journal WHERE reason='schedule_blocked:occurrence_expired')=1 BEGIN SELECT RAISE(ABORT,'injected_batch_fault'); END"
               )
    end)

    current = snapshot(c, 1_060_001, 0, 40)
    assert {:error, _} = advance(c, current)
    assert {:ok, ^before} = Store.revision(c.store)

    with_db(c.path, fn db ->
      assert {:ok, [[17, 17, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM request_receipts WHERE disposition='held'),(SELECT COUNT(*) FROM request_outbox),(SELECT SUM(reserved_effects) FROM request_causal_roots)"
               )

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER advance_batch_fault")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, %{receipts: closed, has_more: true}} = advance(c, current)
    assert length(closed) == 16

    assert Enum.all?(
             closed,
             &(&1.disposition == :rejected and &1.reason == "schedule_blocked:occurrence_expired")
           )

    assert {:ok,
            %{
              receipts: [
                %{disposition: :rejected, reason: "schedule_blocked:observation_unavailable"}
              ],
              has_more: false
            }} = advance(c, current)

    assert {:ok, %{receipts: [], has_more: false}} = advance(c, current)

    for original <- originals do
      assert {:ok, ^original} =
               Store.original_schedule_occurrence(c.store, c.manager, original.occurrence_id)
    end

    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "actual schema 25 migration creates only empty occurrence tables", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_effect_operations; DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; PRAGMA user_version=25"
        )
    end)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :restarted
      )

    assert {:ok, 3} = Store.revision(restarted)

    with_db(c.path, fn db ->
      assert {:ok, [[27]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks),(SELECT value FROM meta WHERE key='rule_generation')"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "actual schema 26 calculation-only history cannot acquire request authority on upgrade",
       c do
    activate(c)

    with_db(c.path, fn db ->
      assert :ok = Sqlite3.execute(db, WotexHome.Test.SchemaFixtures.downgrade_schedule_effects())
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok,
            %{state: :blocked, reason: "temporal_execution_unavailable", revision: 7} = original} =
             consider(c, snapshot(c, 100_001, 0, 10))

    :ok = GenServer.stop(c.store)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :upgraded
      )

    assert {:ok, ^original} =
             Store.original_schedule_occurrence(restarted, c.manager, original.occurrence_id)

    assert {:ok, 7} = Store.revision(restarted)
    c = %{c | store: restarted}
    clock(c, :upgraded_clock, 100_001)
    assert {:ok, %{state: :idle}} = Store.consider_schedule(restarted)

    with_db(c.path, fn db ->
      assert {:ok, [[27]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_effect_operations),(SELECT COUNT(*) FROM request_causal_roots),(SELECT COUNT(*) FROM request_receipts)"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "unexplained temporal effect journal rolls back the actual causal-root migration", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      assert :ok = Sqlite3.execute(db, WotexHome.Test.SchemaFixtures.downgrade_schedule_effects())

      assert :ok =
               Sqlite3.execute(
                 db,
                 "INSERT INTO authority_journal VALUES (4,'schedule_effect_held','occ:unexplained'); UPDATE meta SET value=4 WHERE key='revision'"
               )
    end)

    assert {:error, {:store_open_failed, {:schema_failed, {:error, :corrupt_schedule_effect}}}} =
             Store.start_link(path: c.path)

    with_db(c.path, fn db ->
      assert {:ok, [[26]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('request_causal_roots_temporal','schedule_effect_operations')"
               )

      assert {:error, _} =
               SQL.query(
                 db,
                 "INSERT INTO request_causal_roots VALUES ('manager:one',1,'occ:bad','schedule_occurrence',4,0,NULL,NULL,NULL)"
               )
    end)
  end

  test "unexplained occurrence journal rolls back actual migration DDL", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_effect_operations; DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; PRAGMA user_version=25; UPDATE meta SET value=4 WHERE key='revision'; INSERT INTO authority_journal VALUES (4,'schedule_occurrence_considered','occ:unexplained')"
        )
    end)

    assert {:error,
            {:store_open_failed, {:schema_failed, {:error, :corrupt_schedule_occurrence}}}} =
             Store.start_link(path: c.path)

    with_db(c.path, fn db ->
      assert {:ok, [[25]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('schedule_considerations','schedule_watermarks')"
               )
    end)
  end

  test "damaged watermark disables live writes, restart and authenticated archive verification",
       c do
    activate(c)
    assert {:ok, receipt} = consider(c, snapshot(c, 100_001, 0, 10))

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "UPDATE schedule_watermarks SET considered_through=considered_through+1"
        )
    end)

    assert {:error, :corrupt_schedule_occurrence} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    assert {:error, :store_unavailable} = Store.consider_schedule(c.store)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "damaged.wohbk")
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:error, :invalid_backup} = Backup.verify(archive, key)
    :ok = GenServer.stop(c.store)

    assert {:error, {:store_open_failed, :corrupt_schedule_occurrence}} =
             Store.start_link(path: c.path)
  end

  test "temporal publication failure rolls back the request, causal root, cursor and all journals",
       c do
    activate(c)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER temporal_fault BEFORE INSERT ON schedule_effect_operations BEGIN SELECT RAISE(ABORT,'injected_temporal_fault'); END"
        )
    end)

    assert {:error, _} = consider(c, snapshot(c, 100_001, 0, 10))

    with_db(c.path, fn db ->
      assert {:ok, [[6, 0, 0, 0, 0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks),(SELECT COUNT(*) FROM schedule_effect_operations),(SELECT COUNT(*) FROM request_receipts),(SELECT COUNT(*) FROM request_causal_roots),(SELECT COUNT(*) FROM request_journal)"
               )

      :ok = Sqlite3.execute(db, "DROP TRIGGER temporal_fault")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, %{state: :held, revision: 9}} = consider(c, snapshot(c, 100_001, 0, 20))
  end

  test "receipt capacity produces one terminal blocked occurrence without a new causal root", c do
    :sys.replace_state(c.store, &%{&1 | receipt_limit: 1})

    {:ok, mutation} =
      WotexHome.Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "manual:capacity",
        "expected_revision" => 0,
        "target_id" => "light:one",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, %{disposition: :held, revision: 4}} =
             Store.submit_request(c.store, c.manager, mutation)

    assert {:ok, _} =
             Store.retain_schedule_content(
               c.store,
               c.manager,
               admission_document("schedule:admit", 4)
             )

    clock(c, :clock, 90_000)

    assert {:ok, %{revision: 8}} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "schedule:activate", 5, 5)
             )

    assert {:ok,
            %{
              state: :blocked,
              reason: "receipt_capacity",
              effect: %{request_revision: nil},
              revision: 10
            } = receipt} = consider(c, snapshot(c, 100_001, 0, 10))

    assert {:ok, %{state: :idle}} = consider(c, snapshot(c, 100_001, 0, 20))

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    with_db(c.path, fn db ->
      assert {:ok, [[1, 1, 0, 1]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM request_receipts),(SELECT COUNT(*) FROM request_causal_roots),(SELECT COUNT(*) FROM request_outbox),(SELECT COUNT(*) FROM schedule_effect_operations)"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "new manual and explicit rule operations cannot occupy the temporal namespace", c do
    id = "occ:" <> Codec.hash("reserved software fixture")

    {:ok, mutation} =
      WotexHome.Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => id,
        "expected_revision" => 0,
        "target_id" => "light:one",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:error, :reserved_operation_id} = Store.submit_request(c.store, c.manager, mutation)

    assert {:error, :reserved_operation_id} =
             Store.invoke_rule(c.store, c.manager, 1, id, 0, "rule:one")

    assert {:ok, 3} = Store.revision(c.store)
  end

  test "a temporal request relabeled as explicit disables writes, startup and archive verification",
       c do
    activate(c)
    assert {:ok, receipt} = consider(c, snapshot(c, 100_001, 0, 10))

    with_db(c.path, fn db ->
      {:ok, []} =
        SQL.query(
          db,
          "UPDATE request_causal_roots SET origin='explicit_request' WHERE operation_id=?",
          [receipt.occurrence_id]
        )
    end)

    assert {:error, :corrupt_schedule_effect} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    assert {:error, :store_unavailable} = Store.consider_schedule(c.store)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "bad-origin.wohbk")
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:error, :invalid_backup} = Backup.verify(archive, key)
    :ok = GenServer.stop(c.store)

    assert {:error, {:store_open_failed, :corrupt_schedule_effect}} =
             Store.start_link(path: c.path)
  end

  test "Authority calculates outside the writer and consumes one actual due occurrence", c do
    assert {:ok, %{state: :inactive}} = Authority.consider_schedule(Authority.new(store: c.store))
    activate(c, 96_000)
    authority = Authority.new(store: c.store)
    assert {:ok, %{state: :idle}} = Authority.consider_schedule(authority)
    assert :sys.get_state(c.store).schedule_poll == nil
    assert {:ok, 6} = Store.revision(c.store)
    Process.sleep(4_300)

    assert {:ok, %{state: :held} = receipt} = Authority.consider_schedule(authority)
    assert {:ok, %{state: :idle}} = Authority.consider_schedule(authority)
    assert {:ok, 9} = Store.revision(c.store)
    assert :sys.get_state(c.store).schedule_poll == nil

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    assert {:ok, %{dispatch_enabled: false}} = Store.health(c.store)
    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "one-use preparation belongs to its caller and cannot be cancelled or consumed by another",
       c do
    activate(c)
    assert {:ok, reference, basis} = Store.prepare_schedule_poll(c.store)
    refute Map.has_key?(basis, :db)
    refute Map.has_key?(basis, :credential)

    assert {:ok, :idle} =
             Consideration.build(
               basis.activation,
               basis.artifact,
               basis.snapshot,
               basis.watermark
             )

    task =
      Task.async(fn ->
        assert {:error, :schedule_poll_busy} = Store.prepare_schedule_poll(c.store)
        assert :ok = Store.cancel_schedule_poll(c.store, reference)
        Store.commit_schedule_poll(c.store, reference, :idle)
      end)

    assert {:error, :schedule_poll_unavailable} = Task.await(task)
    assert {:ok, %{state: :idle}} = Store.commit_schedule_poll(c.store, reference, :idle)

    assert {:error, :schedule_poll_unavailable} =
             Store.commit_schedule_poll(c.store, reference, :idle)

    assert {:ok, 6} = Store.revision(c.store)
  end

  test "prepared due publication is one-use and a competing consumption invalidates its cursor",
       c do
    activate(c, 96_000)
    Process.sleep(4_300)
    assert {:ok, reference, basis} = Store.prepare_schedule_poll(c.store)

    assert {:ok, record} =
             Consideration.build(
               basis.activation,
               basis.artifact,
               basis.snapshot,
               basis.watermark
             )

    refute record == :idle
    assert {:ok, %{state: :held} = receipt} = Store.consider_schedule(c.store)

    assert {:error, :schedule_poll_changed} =
             Store.commit_schedule_poll(c.store, reference, record)

    assert {:error, :schedule_poll_unavailable} =
             Store.commit_schedule_poll(c.store, reference, record)

    assert {:ok, 9} = Store.revision(c.store)

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "caller death frees the bounded preparation without an occurrence or clock authority", c do
    activate(c)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:prepared_poll, self(), Store.prepare_schedule_poll(c.store)})

        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(caller)
    assert_receive {:prepared_poll, ^caller, {:ok, old_reference, _}}, 5_000
    assert {:error, :schedule_poll_busy} = Store.prepare_schedule_poll(c.store)
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5_000
    assert {:ok, reference, _} = prepare_after_down(c.store, 50)
    assert reference != old_reference
    assert :ok = Store.cancel_schedule_poll(c.store, reference)

    assert {:error, :schedule_poll_unavailable} =
             Store.commit_schedule_poll(c.store, old_reference, :idle)

    assert {:ok, 6} = Store.revision(c.store)
  end

  test "expired and cancelled preparations cannot commit or block the next poll", c do
    activate(c)
    assert {:ok, reference, _} = Store.prepare_schedule_poll(c.store)

    :sys.replace_state(c.store, fn state ->
      %{state | schedule_poll: %{state.schedule_poll | issued_ms: -5_000}}
    end)

    assert {:error, :schedule_poll_expired} =
             Store.commit_schedule_poll(c.store, reference, :idle)

    assert {:ok, replacement, _} = Store.prepare_schedule_poll(c.store)
    assert :ok = Store.cancel_schedule_poll(c.store, replacement)
    assert :ok = Store.cancel_schedule_poll(c.store, replacement)

    assert {:error, :schedule_poll_unavailable} =
             Store.commit_schedule_poll(c.store, replacement, :idle)

    assert {:ok, another, _} = Store.prepare_schedule_poll(c.store)

    :sys.replace_state(c.store, fn state ->
      %{state | schedule_poll: %{state.schedule_poll | issued_ms: -5_000}}
    end)

    assert {:ok, renewed, _} = Store.prepare_schedule_poll(c.store)
    assert renewed != another
    assert :ok = Store.cancel_schedule_poll(c.store, renewed)
    assert {:ok, 6} = Store.revision(c.store)
  end

  test "a forged qualified clock and watermark cannot replace the Store-retained calculation basis",
       c do
    activate(c)
    assert {:ok, reference, basis} = Store.prepare_schedule_poll(c.store)
    forged = snapshot(c, 100_001, 0, 10)

    assert {:ok, record} =
             Consideration.build(basis.activation, basis.artifact, forged, basis.watermark)

    assert {:error, :invalid_schedule_consideration} =
             Store.commit_schedule_poll(c.store, reference, record)

    assert {:error, :schedule_poll_unavailable} =
             Store.commit_schedule_poll(c.store, reference, record)

    assert {:ok, %{state: :idle}} = Authority.consider_schedule(Authority.new(store: c.store))
    assert {:ok, 6} = Store.revision(c.store)
    assert {:ok, %{writable: true}} = Store.health(c.store)

    with_db(c.path, fn db ->
      assert {:ok, [[0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks),(SELECT COUNT(*) FROM request_causal_roots)"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "authority lost after preparation remains suspended after grant restoration", c do
    activate(c)
    assert {:ok, reference, _} = Store.prepare_schedule_poll(c.store)
    assert {:ok, _} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert {:ok, before} = Store.revision(c.store)

    assert {:error, :schedule_basis_changed} =
             Store.commit_schedule_poll(c.store, reference, :idle)

    assert {:ok, ^before} = Store.revision(c.store)
    assert {:ok, _, _} = Store.grant_target_and_rotate(c.store, "manager:one", "light:one")
    assert {:ok, %{state: :inactive}} = Authority.consider_schedule(Authority.new(store: c.store))
    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "clock loss between preparation and consumption publishes no cursor or request", c do
    activate(c)
    assert {:ok, reference, _} = Store.prepare_schedule_poll(c.store)
    assert :ok = GenServer.stop(:sys.get_state(c.store).temporal_clock_owner)

    assert {:error, :temporal_clock_unavailable} =
             Store.commit_schedule_poll(c.store, reference, :idle)

    assert :sys.get_state(c.store).schedule_poll == nil
    assert {:ok, 6} = Store.revision(c.store)
    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "publication failure rolls back a prepared occurrence and restart grants no old preparation",
       c do
    activate(c, 96_000)
    Process.sleep(4_300)
    assert {:ok, reference, basis} = Store.prepare_schedule_poll(c.store)

    assert {:ok, record} =
             Consideration.build(
               basis.activation,
               basis.artifact,
               basis.snapshot,
               basis.watermark
             )

    with_db(c.path, fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER prepared_cursor_fault BEFORE INSERT ON schedule_watermarks BEGIN SELECT RAISE(ABORT,'injected_prepared_fault'); END"
               )
    end)

    assert {:error, :store_unavailable} = Store.commit_schedule_poll(c.store, reference, record)
    assert :sys.get_state(c.store).schedule_poll == nil
    assert {:ok, 6} = Store.revision(c.store)

    with_db(c.path, fn db ->
      assert {:ok, [[0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM request_receipts),(SELECT COUNT(*) FROM request_causal_roots)"
               )

      assert :ok = Sqlite3.execute(db, "DROP TRIGGER prepared_cursor_fault")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    :ok = GenServer.stop(c.store)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :prepared_restart
      )

    assert {:error, :schedule_poll_unavailable} =
             Store.commit_schedule_poll(restarted, reference, record)

    assert {:error, :temporal_clock_unavailable} = Store.prepare_schedule_poll(restarted)
    assert {:ok, 6} = Store.revision(restarted)
  end

  for loss <- [:preparation_expiry, :window_expiry, :clock_loss] do
    test "#{loss} at the final enclosing guard rolls back prepared publication", c do
      loss = unquote(loss)
      activate(c, 96_000)
      Process.sleep(4_300)
      assert {:ok, reference, basis} = Store.prepare_schedule_poll(c.store)

      assert {:ok, record} =
               Consideration.build(
                 basis.activation,
                 basis.artifact,
                 basis.snapshot,
                 basis.watermark
               )

      refute record == :idle

      reason =
        unquote(
          case loss do
            :preparation_expiry -> :schedule_poll_expired
            :window_expiry -> :occurrence_expired
            :clock_loss -> :temporal_clock_unavailable
          end
        )

      assert {:error, {:policy, ^reason}} =
               prepared_final_guard_loss(c.store, basis, record, loss)

      assert :ok = Store.cancel_schedule_poll(c.store, reference)
      assert {:ok, 6} = Store.revision(c.store)
      assert {:ok, %{writable: true}} = Store.health(c.store)

      with_db(c.path, fn db ->
        assert {:ok, [[0, 0, 0, 0]]} =
                 SQL.query(
                   db,
                   "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks),(SELECT COUNT(*) FROM request_receipts),(SELECT COUNT(*) FROM request_causal_roots)"
                 )

        assert :ok = Integrity.validate_snapshot(db)
      end)
    end
  end

  # Controlled software clocks at the actual borrowed transaction's final
  # commit guard; not installed source/oscillator or hardware qualification.
  defp prepared_final_guard_loss(store, basis, record, loss) do
    original = basis.snapshot

    changed =
      case loss do
        :preparation_expiry ->
          now = original.now_ms + 5_000
          {lower, upper} = original.interval

          %{
            original
            | now_ms: now,
              sample: %{
                original.sample
                | "sampled_monotonic_ms" => now,
                  "utc_lower_ms" => lower,
                  "utc_upper_ms" => upper
              }
          }

        :window_expiry ->
          now = original.now_ms + 1

          %{
            original
            | now_ms: now,
              interval: {110_000, 110_000},
              sample: %{
                original.sample
                | "sampled_monotonic_ms" => now,
                  "utc_lower_ms" => 110_000,
                  "utc_upper_ms" => 110_000
              }
          }

        :clock_loss ->
          original
      end

    {:ok, before_clock} =
      ClockContext.new(
        fn -> {original.scope["store_boot_epoch"], original.now_ms} end,
        fn -> {:ok, original} end,
        fn _ -> {:ok, nil} end
      )

    {:ok, final_clock} =
      ClockContext.new(
        fn -> {changed.scope["store_boot_epoch"], changed.now_ms} end,
        fn ->
          if loss == :clock_loss, do: {:error, :temporal_clock_unavailable}, else: {:ok, changed}
        end,
        fn _ -> {:ok, nil} end
      )

    caller = self()
    reference = make_ref()

    :sys.replace_state(store, fn state ->
      result =
        SQL.transaction(state.db, fn db ->
          case ScheduleOccurrences.consume_poll(
                 db,
                 before_clock,
                 state.receipt_limit,
                 basis,
                 record
               ) do
            {:commit, _} = published ->
              case ScheduleOccurrences.final_poll_guard(db, final_clock, basis, record) do
                :ok -> published
                {:error, reason} -> {:rollback, {:policy, reason}}
              end

            other ->
              other
          end
        end)

      send(caller, {reference, result})
      state
    end)

    receive do
      {^reference, result} -> result
    after
      20_000 -> flunk("prepared final guard did not return")
    end
  end

  defp prepare_after_down(store, remaining) do
    case Store.prepare_schedule_poll(store) do
      {:error, :schedule_poll_busy} when remaining > 0 ->
        Process.sleep(10)
        prepare_after_down(store, remaining - 1)

      result ->
        result
    end
  end

  defp activate(c, observed \\ 90_000) do
    assert {:ok, _} = admit(c)
    clock(c, :clock, observed)

    assert {:ok, _} =
             Store.change_schedule(
               c.store,
               c.manager,
               operation("activate", "schedule:activate", 4, 4)
             )
  end

  # Controlled software correspondence fixture on the actual Store's borrowed
  # handle. It is not installed-clock evidence or an externally callable clock.
  defp snapshot(c, lower, width, elapsed) do
    original =
      with_db(c.path, fn db ->
        {:ok, [[revision]]} =
          SQL.query(
            db,
            "SELECT MAX(revision) FROM schedule_lifecycle_operations WHERE kind='activate'"
          )

        {:ok, activation} = ScheduleLifecycle.retained_activation(db, revision)
        {:ok, snapshot, _} = ActivationClock.decode(activation.clock_document)
        snapshot
      end)

    now = original.now_ms + elapsed

    sample = %{
      original.sample
      | "sampled_monotonic_ms" => now,
        "utc_lower_ms" => lower,
        "utc_upper_ms" => lower + width
    }

    %{original | sample: sample, now_ms: now, interval: {lower, lower + width}}
  end

  defp advance(c, snapshot) do
    {:ok, context} =
      ClockContext.new(
        fn -> {snapshot.scope["store_boot_epoch"], snapshot.now_ms} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, nil} end
      )

    caller = self()
    reference = make_ref()

    :sys.replace_state(c.store, fn state ->
      result =
        SQL.transaction(
          state.db,
          &WotexHome.Durable.Store.ScheduleEffects.advance(
            &1,
            context,
            Map.take(state, [
              :qualification_claim_root,
              :qualification_case_keys,
              :qualification_decision_keys
            ])
          )
        )

      send(caller, {reference, result})
      state
    end)

    receive do
      {^reference, {:ok, result}} -> result
      {^reference, error} -> error
    after
      20_000 -> flunk("bounded advancement fixture did not return")
    end
  end

  defp consider(c, snapshot) do
    {:ok, context} =
      ClockContext.new(
        fn -> {snapshot.scope["store_boot_epoch"], snapshot.now_ms} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, nil} end
      )

    consider_context(c, context)
  end

  defp consider_context(c, context) do
    caller = self()
    reference = make_ref()

    :sys.replace_state(c.store, fn state ->
      send(
        caller,
        {reference,
         SQL.transaction(
           state.db,
           &ScheduleOccurrences.consider(&1, context, state.receipt_limit)
         )}
      )

      state
    end)

    receive do
      {^reference, {:ok, result}} -> result
      {^reference, {:error, {:policy, reason}}} -> {:error, reason}
      {^reference, error} -> error
    after
      20_000 -> flunk("Store correspondence fixture did not return")
    end
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

  defp operation(kind, operation, expected, admission) do
    input = %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => expected
    }

    input =
      if kind == "activate", do: Map.put(input, "admission_revision", admission), else: input

    {:ok, document} = OperationInput.encode(kind, input)
    document
  end

  defp clock(c, id, observed) do
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
        "observed_utc_ms" => observed
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
