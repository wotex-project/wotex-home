defmodule WotexHome.DurableScheduleAdmissionTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, ScheduleWriter, SQL}
  alias WotexHome.Rules.OperationInput, as: RuleInput
  alias WotexHome.Schedules.{Codec, OperationInput, Tzif}
  alias WotexHome.Semantics.Thing
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "woh-schedule-#{System.unique_integer([:positive])}")
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

  test "exact immutable review/admission receipts never create a timer, generation or held effect",
       c do
    original = original("admit", "schedule:admit", 3)
    assert {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, original)
    assert receipt.state == :admitted && receipt.revision == 4 && receipt.authority_epoch == 1
    assert receipt.principal_id == "manager:one" && receipt.input_digest == Codec.hash(original)
    assert {:ok, ^receipt} = Store.retain_schedule_content(c.store, c.manager, original)
    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, %{state: :inactive, rule_generation: 0}} = Store.rule_status(c.store, c.manager)

    assert {:ok, %{held_requests: 0, queued_requests: 0, dispatch_enabled: false}} =
             Store.health(c.store)

    review = original("review", "schedule:review", 4)

    assert {:ok, %{state: :reviewed, revision: 5}} =
             Store.retain_schedule_content(c.store, c.manager, review)

    assert :ok = with_db(c.path, &Integrity.validate_snapshot/1)
    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, original)
  end

  test "lookup is exact, principal-private and can recover without today's target grant or timezone",
       c do
    original = original("admit", "schedule:admit", 3)
    assert :not_found = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, 3} = Store.revision(c.store)
    {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, original)
    assert :not_found = Store.original_schedule_status(c.store, c.other, original)
    {:ok, 5} = Store.revoke_target_grant(c.store, "manager:one", "light:one")
    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, ^receipt} = Store.retain_schedule_content(c.store, c.manager, original)
    assert {:ok, 5} = Store.revision(c.store)

    assert {:error, :permission_denied} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, 4))

    assert {:error, :permission_denied} =
             Store.retain_schedule_content(
               c.store,
               c.manager,
               original("admit", "schedule:new", 5)
             )
  end

  test "current lookup distinguishes an absent admission from a reviewed or changed basis", c do
    assert {:error, :schedule_admission_not_found} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, 999))

    assert {:error, :schedule_basis_changed} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, 0))

    {:ok, %{revision: 4}} =
      Store.retain_schedule_content(c.store, c.manager, original("review", "schedule:review", 3))

    assert {:error, :schedule_basis_changed} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, 4))

    {:ok, %{revision: 5}} =
      Store.retain_schedule_content(c.store, c.manager, original("admit", "schedule:admit", 4))

    assert {:ok, artifact, "manager:one"} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, 5))

    assert artifact.source["id"] == "schedule:one"
    assert {:ok, 5} = Store.revision(c.store)
  end

  test "changed operation input or kind cannot renew the original decision", c do
    original = original("admit", "schedule:one", 3)
    {:ok, _} = Store.retain_schedule_content(c.store, c.manager, original)

    for changed <- [
          original("admit", "schedule:one", 4),
          original("review", "schedule:one", 3),
          original("admit", "schedule:one", 3, %{"late_window_ms" => 11_000})
        ] do
      assert {:error, :schedule_operation_conflict} =
               Store.retain_schedule_content(c.store, c.manager, changed)

      assert {:error, :schedule_operation_conflict} =
               Store.original_schedule_status(c.store, c.manager, changed)
    end

    assert {:ok, 4} = Store.revision(c.store)
  end

  test "nonexample bounded interval evidence survives SQLite retention and same-owner restart",
       c do
    trigger = ["interval", 7_777, 60_001, 67_779, 187_781]
    original = original("admit", "schedule:actual", 3, %{"trigger" => trigger})
    assert {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, original)

    assert {:ok, artifact, "manager:one"} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, receipt.revision))

    assert artifact.source["trigger"] == trigger
    assert artifact.temporal_basis["profile"] == "single-schedule-temporal-v2"
    assert :ok = with_db(c.path, &Integrity.validate_snapshot/1)
    :ok = GenServer.stop(c.store)
    restarted = start_supervised!({Store, path: c.path}, id: :actual_restarted)
    assert {:ok, ^receipt} = Store.original_schedule_status(restarted, c.manager, original)
    assert {:ok, ^receipt} = Store.retain_schedule_content(restarted, c.manager, original)

    assert {:ok, ^artifact, "manager:one"} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, receipt.revision))

    assert {:ok, %{state: :inactive, rule_generation: 0}} =
             Store.rule_status(restarted, c.manager)

    assert {:ok, %{dispatch_enabled: false}} = Store.health(restarted)
    assert :ok = with_db(c.path, &Integrity.validate_snapshot/1)
  end

  test "the Store rejects stale revisions, forged authors, changed declarations and countdowns without a clock owner",
       c do
    for {original, expected} <- [
          {original("admit", "schedule:stale", 2), :resnapshot_required},
          {original("admit", "schedule:author", 3, %{"author_id" => "manager:other"}),
           :schedule_basis_changed},
          {original("admit", "schedule:resource", 3, %{"resource_revision" => 2}),
           :schedule_basis_changed},
          {original("admit", "schedule:countdown", 3, %{
             "trigger" => ["countdown", "boot:other", 1, 0, 1_000]
           }), :temporal_clock_unavailable}
        ] do
      assert {:error, ^expected} = Store.retain_schedule_content(c.store, c.manager, original)
      assert :not_found = Store.original_schedule_status(c.store, c.manager, original)
    end

    assert {:ok, 3} = Store.revision(c.store)
    assert {:ok, []} = with_db(c.path, &SQL.query(&1, "SELECT * FROM schedule_admissions"))
  end

  test "calendar history retains complete original bytes and recovery lookup needs no replacement zone",
       c do
    record = JSON.decode!(File.read!(@fixture))["zones"] |> hd()
    {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))

    original =
      original("admit", "schedule:daily", 3, %{
        "trigger" => ["daily", zone.name, zone.digest, "02:30:00", 0, nil]
      })

    assert {:error, :unsupported_schedule_admission} =
             Store.retain_schedule_content(c.store, c.manager, original)

    assert {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, original, zone)
    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, original)

    assert {:ok, ^receipt} =
             Store.retain_schedule_content(c.store, c.manager, original, %{
               zone
               | digest: String.duplicate("a", 64)
             })

    assert {:ok, %{timezone: ^zone}, "manager:one"} =
             with_db(c.path, &ScheduleWriter.current_admission(&1, 4))

    assert :ok = with_db(c.path, &Integrity.validate_snapshot/1)
  end

  test "maintenance blocks new temporal content and retains private original recovery", c do
    original = original("admit", "schedule:before", 3)
    {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, original)

    {:ok, maintenance, 5} =
      Store.provision_principal(c.store, "maintainer:one", ["host:maintain"], [])

    {:ok, _} = Store.begin_maintenance(c.store, maintenance, 1, "maint:begin", 5)
    {:ok, revision} = Store.revision(c.store)

    assert {:error, :maintenance_active} =
             Store.retain_schedule_content(
               c.store,
               c.manager,
               original("admit", "schedule:during", revision)
             )

    assert {:ok, ^receipt} = Store.retain_schedule_content(c.store, c.manager, original)
    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, ^revision} = Store.revision(c.store)
  end

  test "failed multi-row publication rolls back journal, input and revision together", c do
    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER fail_schedule BEFORE INSERT ON schedule_admissions BEGIN SELECT RAISE(ABORT,'injected_schedule_failure'); END"
        )
    end)

    original = original("admit", "schedule:rollback", 3)

    assert {:error, :store_unavailable} =
             Store.retain_schedule_content(c.store, c.manager, original)

    assert {:ok, 3} = Store.revision(c.store)
    assert :not_found = Store.original_schedule_status(c.store, c.manager, original)
    assert {:ok, %{writable: false, held_requests: 0}} = Store.health(c.store)

    with_db(c.path, fn db ->
      assert {:ok, []} =
               SQL.query(db, "SELECT * FROM authority_journal WHERE event_type LIKE 'schedule_%'")

      assert {:ok, []} = SQL.query(db, "SELECT * FROM schedule_admissions")
      assert :ok = Integrity.validate_snapshot(db)
      :ok = Sqlite3.execute(db, "DROP TRIGGER fail_schedule")
    end)

    :ok = GenServer.stop(c.store)
    restarted = start_supervised!({Store, path: c.path}, id: :restarted)
    assert {:ok, %{revision: 4}} = Store.retain_schedule_content(restarted, c.manager, original)
  end

  test "restart preserves exact decisions and encrypted restoration stays quarantined", c do
    original = original("admit", "schedule:restart", 3)
    {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, original)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.root, "schedule.woh")
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:ok, %{store_revision: 4, authority_epoch: 1}} = Backup.verify(archive, key)
    destination = Path.join(c.root, "quarantined.sqlite")
    assert {:ok, _} = Backup.stage_restore(archive, key, destination)
    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: destination)

    assert {:ok, ^receipt} =
             with_db(destination, &ScheduleWriter.original_status(&1, c.manager, original))

    assert :ok = GenServer.stop(c.store)
    restarted = start_supervised!({Store, path: c.path}, id: :restarted)
    assert {:ok, ^receipt} = Store.retain_schedule_content(restarted, c.manager, original)

    assert {:ok, %{state: :inactive, rule_generation: 0}} =
             Store.rule_status(restarted, c.manager)
  end

  test "damaged history fails live lookup, ordinary writes, startup and encrypted archive verification",
       c do
    original = original("admit", "schedule:damage", 3)
    {:ok, _} = Store.retain_schedule_content(c.store, c.manager, original)

    with_db(c.path, fn db ->
      {:ok, []} = SQL.query(db, "DELETE FROM schedule_admissions")
      assert {:error, :corrupt_schedule_admission} = Integrity.validate_snapshot(db)

      key = :crypto.strong_rand_bytes(32)
      archive = Path.join(c.root, "bad.woh")
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
    end)

    assert {:error, :corrupt_schedule_admission} = Store.schedule_source(c.store, c.manager, 0)

    assert {:error, :corrupt_schedule_admission} =
             Store.original_schedule_status(c.store, c.manager, original)

    assert {:ok, %{writable: false}} = Store.health(c.store)
    assert {:ok, 4} = Store.revision(c.store)

    assert {:error, :store_unavailable} =
             Store.provision_principal(c.store, "new:principal", ["read"], [])

    :ok = GenServer.stop(c.store)
    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
  end

  test "an ordinary authority mutation cannot conceal a damaged admission before a schedule lookup",
       c do
    original = original("admit", "schedule:damage", 3)
    {:ok, _} = Store.retain_schedule_content(c.store, c.manager, original)

    with_db(c.path, fn db ->
      {:ok, []} =
        SQL.query(db, "UPDATE schedule_admissions SET artifact_digest=?", [
          String.duplicate("a", 64)
        ])
    end)

    assert {:error, :corrupt_schedule_admission} =
             Store.revoke_target_grant(c.store, "manager:one", "light:one")

    assert {:ok, 4} = Store.revision(c.store)
    assert {:ok, %{writable: false}} = Store.health(c.store)

    assert {:ok, [["manager:one"], ["manager:other"]]} =
             with_db(
               c.path,
               &SQL.query(&1, "SELECT principal_id FROM principal_targets ORDER BY principal_id")
             )
  end

  test "schema twenty three migrates with empty temporal history and no new authority", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_effect_operations; DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions; PRAGMA user_version=23"
        )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    migrated = start_supervised!({Store, path: c.path}, id: :migrated)
    assert {:ok, 3} = Store.revision(migrated)

    with_db(c.path, fn db ->
      assert {:ok, [[27]]} = SQL.query(db, "PRAGMA user_version")
      assert {:ok, []} = SQL.query(db, "SELECT * FROM schedule_admissions")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, %{state: :inactive, rule_generation: 0, admission_revision: 0}} =
             Store.rule_status(migrated, c.manager)
  end

  test "unexplained temporal journals roll back the actual migration DDL", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_effect_operations; DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions; PRAGMA user_version=23; INSERT INTO authority_journal VALUES (4,'schedule_admitted','unexplained'); UPDATE meta SET value=4 WHERE key='revision'"
        )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, {:schema_failed, _}}} = Store.start_link(path: c.path)

    with_db(c.path, fn db ->
      assert {:ok, [[23]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM sqlite_master WHERE name='schedule_admissions'"
               )

      assert {:ok, [[4]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
    end)
  end

  test "row capacity refuses new content while retaining exact original recovery", c do
    first = original("admit", "schedule:first", 3)
    {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, first)
    assert {1_024, 1_027} = with_db(c.path, &fill_history(&1, 1_024, 8_388_608))
    next = original("admit", "schedule:capacity:new", 1_027)

    assert {:error, :schedule_admission_capacity} =
             Store.retain_schedule_content(c.store, c.manager, next)

    assert :not_found = Store.original_schedule_status(c.store, c.manager, next)
    assert {:ok, ^receipt} = Store.retain_schedule_content(c.store, c.manager, first)
    assert {:ok, 1_027} = Store.revision(c.store)
    assert :ok = with_db(c.path, &Integrity.validate_snapshot/1)
  end

  test "the aggregate byte ceiling applies before row capacity and retains every historical row",
       c do
    record = JSON.decode!(File.read!(@fixture))["zones"] |> hd()
    original_bytes = Base.decode64!(record["data_base64"])
    # A bounded synthetic TZif with a large legacy block exercises the original
    # complete-byte custody, without installing or changing any host timezone.
    legacy =
      <<"TZif2", 0::120, 0::96, 4_096::unsigned-big-32, 1::unsigned-big-32, 4::unsigned-big-32>> <>
        :binary.copy(<<0>>, 4_096 * 5) <> <<0::signed-big-32, 0, 0, "STD", 0>>

    bytes = legacy <> binary_part(original_bytes, 54, byte_size(original_bytes) - 54)
    {:ok, zone} = Tzif.decode(record["name"], bytes)
    changes = %{"trigger" => ["daily", zone.name, zone.digest, "02:30:00", 0, nil]}
    first = original("admit", "schedule:first", 3, changes)
    {:ok, receipt} = Store.retain_schedule_content(c.store, c.manager, first, zone)
    {count, revision} = with_db(c.path, &fill_history(&1, 1_024, 8_388_608))
    assert count < 1_024 && count > 1
    next = original("admit", "schedule:capacity:new", revision, changes)

    assert {:error, :schedule_admission_capacity} =
             Store.retain_schedule_content(c.store, c.manager, next, zone)

    assert {:ok, ^receipt} = Store.original_schedule_status(c.store, c.manager, first)
    assert {:ok, ^revision} = Store.revision(c.store)

    assert {:ok, [[^count]]} =
             with_db(c.path, &SQL.query(&1, "SELECT COUNT(*) FROM schedule_admissions"))
  end

  defp fill_history(db, row_limit, byte_limit) do
    {:ok, [[principal, epoch, _, kind, _, input, artifact, digest, first_revision]]} =
      SQL.query(db, "SELECT * FROM schedule_admissions ORDER BY revision LIMIT 1")

    {:ok, ^kind, original} = OperationInput.decode(input)
    initial_bytes = byte_size(input) + byte_size(artifact)

    {:ok, result} =
      SQL.transaction(db, fn db ->
        {count, revision, _} =
          Enum.reduce_while(1..(row_limit - 1), {1, first_revision, initial_bytes}, fn index,
                                                                                       {count,
                                                                                        revision,
                                                                                        bytes} ->
            operation = "schedule:capacity:#{index}"

            {:ok, input} =
              OperationInput.encode(kind, %{
                original
                | "operation_id" => operation,
                  "expected_revision" => revision
              })

            extra = byte_size(input) + byte_size(artifact)

            if bytes + extra <= byte_limit do
              {:ok, []} =
                SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
                  revision + 1,
                  "schedule_admitted",
                  "#{principal}/#{epoch}/#{operation}"
                ])

              {:ok, []} =
                SQL.query(db, "INSERT INTO schedule_admissions VALUES (?,?,?,?,?,?,?,?,?)", [
                  principal,
                  epoch,
                  operation,
                  kind,
                  revision,
                  input,
                  artifact,
                  digest,
                  revision + 1
                ])

              {:cont, {count + 1, revision + 1, bytes + extra}}
            else
              {:halt, {count, revision, bytes}}
            end
          end)

        {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [revision])
        assert :ok = Integrity.validate_snapshot(db)
        {:commit, {count, revision}}
      end)

    result
  end

  defp original(kind, operation, expected, changes \\ %{}) do
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

    source =
      %{
        "id" => "schedule:one",
        "source_revision" => 1,
        "author_id" => "manager:one",
        "rule_id" => "rule:one",
        "rule_source_digest" => Codec.hash(rule),
        "target_id" => "light:one",
        "resource_revision" => 0,
        "late_window_ms" => 10_000,
        "uncertainty_tolerance_ms" => 100,
        "trigger" => ["interval", 100_000, 60_000, 0, nil]
      }
      |> Map.merge(changes)

    {:ok, source} = Codec.encode(source)

    {:ok, original} =
      OperationInput.encode(kind, %{
        "authority_epoch" => 1,
        "operation_id" => operation,
        "expected_revision" => expected,
        "source_document" => source,
        "rule_document" => rule
      })

    original
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
