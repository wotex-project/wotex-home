defmodule WotexHome.ControllerRetirementTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{ControllerWriter, Integrity, SQL}
  alias WotexHome.Recovery.ControllerCodec

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    directory = Path.join(temporary, "woh-transfer-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    authority = Authority.new(store: store)
    assert {:ok, transfer, 1} = Authority.provision_transfer(authority)
    assert {:ok, maintenance, 2} = Authority.provision_maintenance(authority)

    %{
      directory: directory,
      path: path,
      store: store,
      authority: authority,
      transfer: transfer,
      maintenance: maintenance,
      destination: String.duplicate("a", 64)
    }
  end

  test "local origin is persistent, independent and creates no epoch, revision or grants", c do
    assert {:ok, identity} = Authority.controller_status(c.authority, c.transfer)
    assert identity.state == "active" and identity.retirement_revision == 0
    assert identity.authority_epoch == 1 and identity.store_revision == 2
    assert byte_size(identity.deployment_id) == 64 and byte_size(identity.owner_id) == 64
    refute identity.deployment_id == identity.owner_id
    assert {:error, :principal_exists} = Authority.provision_transfer(c.authority)

    assert {:error, :invalid_provisioning} =
             Store.provision_principal(
               c.store,
               "transfer:combined",
               ["host:transfer", "host:maintain"],
               []
             )

    with_db(c.path, fn db ->
      assert [["[\"host:transfer\"]", "active"]] =
               rows(
                 db,
                 "SELECT permissions,status FROM principals WHERE principal_id='transfer:local'"
               )

      assert [[0]] = rows(db, "SELECT COUNT(*) FROM principal_targets")
      assert [[2]] = rows(db, "SELECT COUNT(*) FROM authority_journal")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    :ok = GenServer.stop(c.store)
    store = start_supervised!({Store, path: c.path}, id: :restarted)
    assert {:ok, ^identity} = Store.controller_status(store, c.transfer)
    assert {:ok, %{dispatch_enabled: false, writable: true}} = Store.health(store)
  end

  test "retirement requires separate permission, active maintenance and current exact scope", c do
    input = input(c, 2)

    assert {:error, :permission_denied} =
             Authority.retire_controller(c.authority, c.maintenance, input)

    assert {:error, :permission_denied} = Authority.controller_status(c.authority, c.maintenance)
    assert {:error, :maintenance_required} = retire(c, input)
    assert {:error, :stale_authority_epoch} = retire(c, %{input | "authority_epoch" => 2})
    assert {:error, :resnapshot_required} = retire(c, %{input | "expected_revision" => 1})
    {:ok, identity} = Store.controller_status(c.store, c.transfer)

    assert {:error, :invalid_destination_owner} =
             retire(c, %{input | "destination_owner_id" => identity.owner_id})

    assert {:error, :invalid_controller_record} = retire(c, Map.put(input, "isolated", true))
    assert {:error, :invalid_controller_record} = retire(c, %{input | "authority_epoch" => true})

    assert {:error, :unauthorized} =
             Store.retire_controller(c.store, :binary.copy(<<0>>, 32), input)

    assert {:error, :invalid_controller_record} =
             Store.retirement_status(c.store, c.transfer, %{}, [])

    assert {:ok, 2} = Store.revision(c.store)
    assert :not_found = Store.retirement_status(c.store, c.transfer, 1, "retire:original")
  end

  test "original private retirement retry is immutable and every new source mutation is blocked",
       c do
    {:ok, other, 3} = Store.provision_principal(c.store, "transfer:other", ["host:transfer"], [])
    {:ok, barrier} = Store.begin_maintenance(c.store, c.maintenance, 1, "maintenance:begin", 3)
    input = input(c, barrier.revision)
    assert {:ok, receipt} = retire(c, input)
    assert receipt["revision"] == barrier.revision + 1
    assert receipt["maintenance_revision"] == barrier.revision
    assert receipt["destination_owner_id"] == c.destination
    assert {:ok, ^receipt} = retire(c, input)

    assert {:ok, ^receipt} =
             Authority.retirement_status(c.authority, c.transfer, 1, "retire:original")

    assert :not_found = Store.retirement_status(c.store, other, 1, "retire:original")

    assert {:error, :controller_operation_conflict} =
             retire(c, %{input | "destination_owner_id" => String.duplicate("b", 64)})

    assert {:error, :controller_operation_conflict} =
             retire(c, %{input | "expected_revision" => receipt["revision"]})

    assert {:error, :source_retired} = Store.retire_controller(c.store, other, input)
    assert {:error, :source_retired} = retire(c, %{input | "operation_id" => "retire:new"})

    for request <- [
          {:record, nil, nil},
          {:record_batch, nil, []},
          {:provision_principal, "new:one", ["read"], []},
          {:revoke_principal, "transfer:local"},
          {:rotate_principal_credential, "transfer:local"},
          {:enroll_thing, nil},
          {:revoke_thing, "thing:one"},
          {:profile_change, c.transfer, %{}},
          {:collect_profiles, c.transfer},
          {:authorize_capture, c.transfer},
          {:submit_request, c.transfer, nil},
          {:cancel_request, c.transfer, 1, "request:one"},
          {:handoff_claimed_power, nil, nil, nil, nil, nil, nil},
          {:accept_power_ack, nil, nil, nil, nil},
          {:mark_power_outcome_unknown, nil, nil, nil, nil, nil},
          {:fence_rule_generation, receipt["revision"], 1},
          {:maintenance_change, c.maintenance, 1, "maintenance:end", receipt["revision"], "end",
           barrier.revision}
        ] do
      assert {:error, :source_retired} = GenServer.call(c.store, request)
    end

    assert {:ok, receipt["revision"]} == Store.revision(c.store)
    assert {:ok, %{state: "retired"}} = Store.controller_status(c.store, c.transfer)
    assert {:ok, %{writable: false, dispatch_enabled: false}} = Store.health(c.store)
    assert {:ok, %{state: :maintenance}} = Store.maintenance_status(c.store, c.maintenance)
    with_db(c.path, &assert(:ok == Integrity.validate_snapshot(&1)))
  end

  test "retired archives preserve source identity and remain quarantined with startup refused",
       c do
    input = begin_input(c)
    {:ok, receipt} = retire(c, input)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "retired.woh")
    assert {:ok, %{store_revision: revision}} = Store.export_profile_backup(c.store, archive, key)
    assert revision == receipt["revision"]
    assert {:ok, %{authority_epoch: 1, store_revision: ^revision}} = Backup.verify(archive, key)
    directory = Path.join(c.directory, "quarantine")
    assert {:ok, %{quarantined: true}} = Backup.stage_profile_restore(archive, key, directory)
    staged = Path.join(directory, "home.sqlite")

    with_db(staged, fn db ->
      assert :ok = Integrity.validate_snapshot(db)

      assert {:ok, %{state: "retired", retirement_revision: ^revision}} =
               ControllerWriter.identity(db)

      assert [[1]] == rows(db, "SELECT value FROM meta WHERE key='restore_quarantine'")
      assert [[1]] == rows(db, "SELECT COUNT(*) FROM controller_retirements")
    end)

    :ok = GenServer.stop(c.store)
    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, :source_retired}} = Store.start_link(path: c.path)

    assert {:error, {:store_open_failed, :restore_requires_transfer}} =
             Store.start_link(path: staged)
  end

  test "retirement preserves an unknown handed-off outcome and its already spent root", c do
    {:ok, thing} =
      WotexHome.Semantics.Thing.new(%{
        "id" => "light:transfer",
        "role" => "Light",
        "profile_ref" => "fixture:transfer:1",
        "capabilities" => [
          %{
            "thing_id" => "light:transfer",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:transfer:1",
            "evidence_ref" => "fixture:power",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    assert {:ok, 3} = Store.enroll_thing(c.store, thing)

    assert {:error, :invalid_provisioning} =
             Store.provision_principal(c.store, "transfer:target", ["host:transfer"], [thing.id])

    assert {:error, :transfer_target_forbidden} =
             Store.grant_target_and_rotate(c.store, "transfer:local", thing.id)

    assert {:ok, control, 4} =
             Store.provision_principal(
               c.store,
               "operator:fixture",
               ["read", "control:ordinary"],
               [thing.id]
             )

    {:ok, mutation} =
      WotexHome.Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "power:uncertain",
        "expected_revision" => 0,
        "target_id" => thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, held} = Store.submit_request(c.store, control, mutation)
    assert held.revision == 5

    # Historical software fixture only: no packet, qualification or physical result.
    with_db(c.path, fn db ->
      :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
      :ok = WotexHome.Durable.Store.CausalLedger.reserve(db, held, 6)

      :ok =
        Sqlite3.execute(db, """
        DELETE FROM request_outbox WHERE operation_id='power:uncertain';
        UPDATE request_receipts SET disposition='outcome_unknown',reason='fixture_after_handoff',revision=9 WHERE operation_id='power:uncertain';
        INSERT INTO request_journal VALUES (6,'operator:fixture',1,'power:uncertain','queued',NULL);
        INSERT INTO request_journal VALUES (7,'operator:fixture',1,'power:uncertain','dispatching',NULL);
        INSERT INTO request_journal VALUES (8,'operator:fixture',1,'power:uncertain','protocol_accepted',NULL);
        INSERT INTO request_journal VALUES (9,'operator:fixture',1,'power:uncertain','outcome_unknown','fixture_after_handoff');
        INSERT INTO request_execution
          (principal_id,authority_epoch,operation_id,target_id,effect_domain,profile_ref,profile_evidence_ref,
           resource_revision,rule_generation,baseline_revision,admission_revision,planned_value,state,
           claim_token,claim_boot_epoch,handoff_revision,attempts,revision)
          VALUES ('operator:fixture',1,'power:uncertain','light:transfer','light:transfer','fixture:transfer:1',
            'fixture:power',0,0,0,6,x'0101','outcome_unknown',zeroblob(32),'fixture:boot',7,1,9);
        UPDATE meta SET value=9 WHERE key='revision';
        COMMIT;
        """)

      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, original} = Store.request_status(c.store, control, 1, "power:uncertain")
    assert original.disposition == :outcome_unknown

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, c.maintenance, 1, "maintenance:begin", 9)

    assert {:ok, _} = retire(c, input(c, barrier.revision))
    assert {:ok, ^original} = Store.request_status(c.store, control, 1, "power:uncertain")

    with_db(c.path, fn db ->
      assert [[1, 6]] ==
               rows(db, "SELECT reserved_effects,reservation_revision FROM request_causal_roots")

      assert [["outcome_unknown", 7, 9]] ==
               rows(db, "SELECT state,handoff_revision,revision FROM request_execution")

      assert {:error, :causal_budget_exhausted} =
               WotexHome.Durable.Store.CausalLedger.reserve(db, held, 13)

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  for {name, sql} <- [
        {"changed owner",
         "UPDATE controller_identity SET owner_id='#{String.duplicate("b", 64)}'"},
        {"changed deployment",
         "UPDATE controller_identity SET deployment_id='#{String.duplicate("b", 64)}'"},
        {"removed origin", "DELETE FROM controller_identity"},
        {"cleared retirement", "UPDATE controller_identity SET state='active',head_revision=0"},
        {"wrong head", "UPDATE controller_identity SET head_revision=1"},
        {"removed receipt", "DELETE FROM controller_retirements"},
        {"detached retirement journal",
         "UPDATE authority_journal SET entity_id='controller:forged' WHERE event_type='controller_source_retired'"},
        {"altered receipt bytes",
         "UPDATE controller_retirements SET receipt_document=receipt_document||' '"},
        {"floating retirement revision",
         "UPDATE controller_retirements SET receipt_document=SUBSTR(receipt_document,1,LENGTH(receipt_document)-2)||'.0]]'"},
        {"altered original input",
         "UPDATE controller_retirements SET input_document=input_document||' '"},
        {"post-retirement revision", "UPDATE meta SET value=value+1 WHERE key='revision'"},
        {"substituted epoch", "UPDATE meta SET value=2 WHERE key='authority_epoch'"}
      ] do
    @sql sql
    test "#{name} rejects live mutation, encrypted archive and startup", c do
      {:ok, _} = retire(c, begin_input(c))

      with_db(c.path, fn db ->
        :ok = Sqlite3.execute(db, @sql)
        assert {:error, :corrupt_controller_history} = ControllerWriter.validate(db)
        assert {:error, _} = Integrity.validate_snapshot(db)
        archive = Path.join(c.directory, "invalid.woh")
        key = :crypto.strong_rand_bytes(32)
        assert {:ok, _} = Backup.export(db, archive, key)
        assert {:error, :invalid_backup} = Backup.verify(archive, key)
      end)

      assert {:error, :corrupt_controller_history} =
               Store.revoke_principal(c.store, "transfer:local")

      assert {:ok, %{writable: false}} = Store.health(c.store)
      :ok = GenServer.stop(c.store)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  for {name, target} <- [
        {"journal insert",
         "BEFORE INSERT ON authority_journal WHEN NEW.event_type='controller_source_retired'"},
        {"receipt insert", "BEFORE INSERT ON controller_retirements"},
        {"head update", "BEFORE UPDATE ON controller_identity"},
        {"revision update", "BEFORE UPDATE ON meta WHEN NEW.key='revision'"}
      ] do
    @target target
    test "failed #{name} rolls back the entire retirement and original operation retries", c do
      input = begin_input(c)

      with_db(c.path, fn db ->
        :ok =
          Sqlite3.execute(
            db,
            "CREATE TRIGGER fail_retirement #{@target} BEGIN SELECT RAISE(ABORT,'fixture failure'); END"
          )

        assert {:error, :store_unavailable} = retire(c, input)
        assert [[0]] = rows(db, "SELECT COUNT(*) FROM controller_retirements")
        assert [["active", 0]] = rows(db, "SELECT state,head_revision FROM controller_identity")

        assert [[0]] =
                 rows(
                   db,
                   "SELECT COUNT(*) FROM authority_journal WHERE event_type='controller_source_retired'"
                 )

        assert [[input["expected_revision"]]] ==
                 rows(db, "SELECT value FROM meta WHERE key='revision'")

        :ok = Sqlite3.execute(db, "DROP TRIGGER fail_retirement")
        assert :ok = Integrity.validate_snapshot(db)
      end)

      assert :not_found = Store.retirement_status(c.store, c.transfer, 1, "retire:original")
      :ok = GenServer.stop(c.store)
      store = start_supervised!({Store, path: c.path}, id: :retried)
      assert {:ok, receipt} = Store.retire_controller(store, c.transfer, input)
      assert receipt["revision"] == input["expected_revision"] + 1
    end
  end

  test "schema twenty archive is retained and migration adds only fresh local ownership", c do
    :ok = GenServer.stop(c.store)

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions; DROP TABLE native_target_operations; DROP TABLE controller_acceptances; DROP TABLE controller_retirements; DROP TABLE controller_identity; PRAGMA user_version=20"
        )

      assert :ok = Integrity.validate_snapshot(db)
      archive = Path.join(c.directory, "historical.woh")
      key = :crypto.strong_rand_bytes(32)
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:ok, %{authority_epoch: 1, store_revision: 2}} = Backup.verify(archive, key)
    end)

    store = start_supervised!({Store, path: c.path}, id: :migrated)

    assert {:ok, %{state: "active", authority_epoch: 1, store_revision: 2}} =
             Store.controller_status(store, c.transfer)

    with_db(c.path, fn db ->
      assert [[25]] = rows(db, "PRAGMA user_version")
      assert [[2]] = rows(db, "SELECT COUNT(*) FROM authority_journal")
      assert [[0]] = rows(db, "SELECT COUNT(*) FROM principal_targets")
      assert [[0]] = rows(db, "SELECT COUNT(*) FROM controller_retirements")
      assert [[document]] = rows(db, "SELECT origin_document FROM controller_identity")

      assert {:ok, %{"store_revision" => 2, "authority_epoch" => 1}} =
               ControllerCodec.decode("origin", document)

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  defp begin_input(c) do
    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, c.maintenance, 1, "maintenance:begin", 2)

    input(c, barrier.revision)
  end

  defp input(c, revision),
    do: %{
      "authority_epoch" => 1,
      "operation_id" => "retire:original",
      "expected_revision" => revision,
      "destination_owner_id" => c.destination
    }

  defp retire(c, input), do: Authority.retire_controller(c.authority, c.transfer, input)

  defp rows(db, sql) do
    assert {:ok, rows} = SQL.query(db, sql)
    rows
  end

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end
end
