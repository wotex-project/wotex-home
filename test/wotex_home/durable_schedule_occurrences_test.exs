defmodule WotexHome.DurableScheduleOccurrencesTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Recovery.PrivateFile
  alias WotexHome.Durable.{Backup, Store}

  alias WotexHome.Durable.Store.{
    ClockContext,
    Integrity,
    ScheduleLifecycle,
    ScheduleOccurrences,
    SQL
  }

  alias WotexHome.Rules.OperationInput, as: RuleInput
  alias WotexHome.Schedules.{ActivationClock, ClockCodec, ClockOwner, Codec, OperationInput}
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

  test "actual private clock polling consumes a due occurrence once without creating effects",
       c do
    activate(c, 96_000)
    assert {:ok, %{state: :idle, watermark: watermark}} = Store.consider_schedule(c.store)
    assert {:ok, 6} = Store.revision(c.store)
    Process.sleep(4_300)

    assert {:ok,
            %{
              state: :blocked,
              decision: "eligible",
              reason: "temporal_execution_unavailable",
              revision: 7
            } = receipt} = Store.consider_schedule(c.store)

    assert receipt.previous_watermark == watermark
    assert receipt.occurrence_id =~ "occ:"
    assert receipt.causal_id =~ "cause:schedule:"
    assert {:ok, %{state: :idle}} = Store.consider_schedule(c.store)
    assert {:ok, 7} = Store.revision(c.store)

    assert {:ok, ^receipt} =
             Store.original_schedule_occurrence(c.store, c.manager, receipt.occurrence_id)

    assert :not_found =
             Store.original_schedule_occurrence(c.store, c.other, receipt.occurrence_id)

    assert {:error, :invalid_schedule_occurrence} =
             Store.original_schedule_occurrence(c.store, c.manager, "occ:bad")

    with_db(c.path, fn db ->
      assert {:ok, [[0, 0, 0]]} =
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
    assert 1 == Enum.count(receipts, &match?({:ok, %{state: :blocked}}, &1))
    assert 7 == Enum.count(receipts, &match?({:ok, %{state: :idle}}, &1))
    assert {:ok, 7} = Store.revision(c.store)
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
    assert {:ok, 7} = Store.revision(restarted)
    with_db(c.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
  end

  test "grant loss stays suspended after restoration and original occurrence remains private history",
       c do
    activate(c)
    assert {:ok, receipt} = consider(c, snapshot(c, 100_001, 0, 10))
    assert {:ok, 8} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert {:ok, 10} = Store.revision(c.store)
    assert {:ok, %{state: :inactive}} = Store.consider_schedule(c.store)

    assert {:ok, replacement, 11} =
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

    assert {:ok, %{revision: 7}} = consider(c, snapshot(c, 100_001, 0, 20))
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
      assert {:ok, [[receipt.watermark, receipt.revision]]} ==
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

  test "actual schema 25 migration creates only empty occurrence tables", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; PRAGMA user_version=25"
        )
    end)

    restarted =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: :restarted
      )

    assert {:ok, 3} = Store.revision(restarted)

    with_db(c.path, fn db ->
      assert {:ok, [[26]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM schedule_watermarks),(SELECT value FROM meta WHERE key='rule_generation')"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "unexplained occurrence journal rolls back actual migration DDL", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; PRAGMA user_version=25; UPDATE meta SET value=4 WHERE key='revision'; INSERT INTO authority_journal VALUES (4,'schedule_occurrence_considered','occ:unexplained')"
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
        {:ok, activation} = ScheduleLifecycle.retained_activation(db, 6)
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
        {reference, SQL.transaction(state.db, &ScheduleOccurrences.consider(&1, context))}
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
