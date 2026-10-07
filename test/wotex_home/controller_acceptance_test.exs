Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))
Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.ControllerAcceptanceTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}

  alias WotexHome.Durable.Store.{
    ControllerWriter,
    Integrity,
    RecoverySnapshot,
    SQL,
    TransferWriter
  }

  alias WotexHome.Lifx.{ProfileBasis, ProfileCatalogue}
  alias WotexHome.Profiles.{Artifact, Custody}
  alias WotexHome.Recovery.{IsolationDecision, TransferAcceptanceCodec, TransferReviewCodec}
  alias WotexHome.Semantics.Observation

  setup tags do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-accept-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    profiles = Path.join(root, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!({Store, path: path, profile_custody: __MODULE__.Custody})

    _custody =
      start_supervised!({Custody, root: profiles, name: __MODULE__.Custody, store_owner: store})

    authority = Authority.new(store: store, profile_custody: __MODULE__.Custody)

    {:ok, operator, 1} =
      Store.provision_principal(store, "operator:source", ["enroll:review", "profile:manage"], [])

    {:ok, maintainer, 2} = Authority.provision_maintenance(authority)
    {:ok, transfer, 3} = Authority.provision_transfer(authority)
    fixture = WotexHome.Test.PortableProfileFixture.context()
    {:ok, package} = ProfileCatalogue.fetch(fixture.current.profile_ref, fixture.current.id)
    interview = fixture.evidence.interview

    selection = %{
      "operator_id" => "operator:source",
      "candidate_ref" => interview.candidate_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => package.thing.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:compiled"
    }

    {:ok, 4} =
      Store.commit_enrollment(
        store,
        operator,
        fixture.evidence.candidates,
        interview,
        [package.profile],
        package.thing,
        selection
      )

    {:ok, controller, 5} =
      Store.provision_principal(store, "controller:source", ["read", "control:ordinary"], [
        fixture.current.id
      ])

    {:ok, _, 6} = Store.provision_principal(store, "reader:revoked", ["read"], [])
    {:ok, 7} = Store.revoke_principal(store, "reader:revoked")

    {:ok, observation} =
      Observation.new(
        %{
          "thing_id" => fixture.current.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "device:original",
          "source_sequence" => 1,
          "boot_epoch" => "fixture:boot",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000,
          "received_monotonic_ms" => 100
        },
        fixture.current.capabilities["power"]
      )

    {:ok, revision} = Store.record(store, observation, fixture.current.capabilities["power"])

    {:ok, _} =
      Store.authorize_source_epoch(
        store,
        fixture.current.id,
        "power",
        "device:original",
        "device:replacement",
        revision
      )

    {:ok, _, _} =
      Store.issue_override_lease_live(store, controller, fixture.current.id, 1, 0, 60_000)

    if tags[:source_capacity] do
      for index <- 1..59 do
        assert {:ok, _, _} =
                 Store.provision_principal(store, "reader:capacity:#{index}", ["read"], [])
      end
    end

    if tags[:unknown_outcome] do
      {:ok, mutation} =
        WotexHome.Mutation.new(%{
          "api_version" => 1,
          "authority_epoch" => 1,
          "operation_id" => "power:uncertain",
          "expected_revision" => 0,
          "target_id" => fixture.current.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true}
        })

      {:ok, held} = Store.submit_request(store, controller, mutation)

      with_db(path, fn db ->
        # Historical software fixture: no packet, qualification or physical outcome.
        assert {:ok, :ok} =
                 SQL.transaction(db, fn db ->
                   first = held.revision + 1
                   assert :ok = WotexHome.Durable.Store.CausalLedger.reserve(db, held, first)

                   assert {:ok, []} =
                            SQL.query(
                              db,
                              "DELETE FROM request_outbox WHERE operation_id='power:uncertain'"
                            )

                   assert {:ok, []} =
                            SQL.query(
                              db,
                              "UPDATE request_receipts SET disposition='outcome_unknown',reason='fixture_after_handoff',revision=? WHERE operation_id='power:uncertain'",
                              [first + 3]
                            )

                   for {offset, disposition, reason} <- [
                         {0, "queued", nil},
                         {1, "dispatching", nil},
                         {2, "protocol_accepted", nil},
                         {3, "outcome_unknown", "fixture_after_handoff"}
                       ] do
                     assert {:ok, []} =
                              SQL.query(
                                db,
                                "INSERT INTO request_journal VALUES (?,'controller:source',1,'power:uncertain',?,?)",
                                [first + offset, disposition, reason]
                              )
                   end

                   assert {:ok, []} =
                            SQL.query(
                              db,
                              "INSERT INTO request_execution (principal_id,authority_epoch,operation_id,target_id,effect_domain,profile_ref,profile_evidence_ref,resource_revision,rule_generation,baseline_revision,admission_revision,planned_value,state,claim_token,claim_boot_epoch,handoff_revision,attempts,revision) VALUES ('controller:source',1,'power:uncertain',?,?,?, ?,0,0,0,?,x'0101','outcome_unknown',zeroblob(32),'fixture:boot',?,1,?)",
                              [
                                fixture.current.id,
                                fixture.current.id,
                                fixture.current.profile_ref,
                                fixture.current.capabilities["power"].evidence_ref,
                                first,
                                first + 1,
                                first + 3
                              ]
                            )

                   assert {:ok, []} =
                            SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [
                              first + 3
                            ])

                   assert :ok = Integrity.validate_snapshot(db)
                   {:commit, :ok}
                 end)
      end)
    end

    if trigger = tags[:trigger] do
      with_db(path, fn db ->
        condition =
          if tags[:epoch_fault],
            do: "NEW.key='authority_epoch' AND NEW.value=2",
            else: "(SELECT value FROM meta WHERE key='authority_epoch')=2"

        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER acceptance_fault #{trigger} WHEN #{condition} BEGIN SELECT RAISE(ABORT,'injected transfer failure'); END"
                 )
      end)
    end

    if tags[:alter_retained] do
      with_db(path, fn db ->
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER acceptance_fault AFTER INSERT ON controller_acceptances BEGIN UPDATE principals SET credential_hash=zeroblob(32) WHERE principal_id='reader:revoked'; END"
                 )
      end)
    end

    schedule_history =
      if tags[:schedule_history] do
        {:ok, manager, _} =
          Store.provision_principal(
            store,
            "manager:schedule",
            ~w(rule:review rule:manage control:ordinary),
            [fixture.current.id]
          )

        {:ok, expected} = Store.revision(store)

        {:ok, rule} =
          WotexHome.Rules.OperationInput.source("admit", %{
            "authority_epoch" => 1,
            "operation_id" => "rule:body",
            "expected_revision" => expected,
            "rule_id" => "rule:transfer",
            "source_revision" => 1,
            "target_id" => fixture.current.id,
            "on" => true
          })

        {:ok, source} =
          WotexHome.Schedules.Codec.encode(%{
            "id" => "schedule:transfer",
            "source_revision" => 1,
            "author_id" => "manager:schedule",
            "rule_id" => "rule:transfer",
            "rule_source_digest" => WotexHome.Schedules.Codec.hash(rule),
            "target_id" => fixture.current.id,
            "resource_revision" => 0,
            "late_window_ms" => 10_000,
            "uncertainty_tolerance_ms" => 100,
            "trigger" => ["interval", 100_000, 60_000, 0, nil]
          })

        {:ok, original} =
          WotexHome.Schedules.OperationInput.encode("admit", %{
            "authority_epoch" => 1,
            "operation_id" => "schedule:admission",
            "expected_revision" => expected,
            "source_document" => source,
            "rule_document" => rule
          })

        {:ok, receipt} = Store.retain_schedule_content(store, manager, original)
        {original, receipt, manager}
      end

    {:ok, revision} = Store.revision(store)
    {:ok, barrier} = Store.begin_maintenance(store, maintainer, 1, "maint:source", revision)
    destination_owner = String.duplicate("a", 64)

    {:ok, retired} =
      Store.retire_controller(store, transfer, %{
        "authority_epoch" => 1,
        "operation_id" => "retire:source",
        "expected_revision" => barrier.revision,
        "destination_owner_id" => destination_owner
      })

    if tags[:historical] do
      :ok = GenServer.stop(store)

      with_db(path, fn db ->
        assert :ok =
                 Sqlite3.execute(
                   db,
                   WotexHome.Test.SchemaFixtures.drop_transfer_acceptance() <>
                     "PRAGMA user_version=21"
                 )
      end)
    end

    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(root, "retired.woh")

    if tags[:historical] do
      with_db(path, fn db ->
        assert {:ok, _} = Backup.export_profiles(db, archive, key, __MODULE__.Custody)
      end)
    else
      assert {:ok, _} = Store.export_profile_backup(store, archive, key)
    end

    {:ok, basis} = Backup.retired_transfer_basis(archive, key)
    destination = Path.join(root, "destination")
    {:ok, _} = Backup.stage_profile_restore(archive, key, destination)
    credential = :crypto.strong_rand_bytes(32)
    {:ok, hash} = WotexHome.Durable.Registry.credential_hash(credential)
    {:ok, runtime} = ProfileBasis.runtime_digest()

    review = %{
      "deployment_id" => retired["deployment_id"],
      "source_owner_id" => retired["source_owner_id"],
      "destination_owner_id" => destination_owner,
      "source_epoch" => 1,
      "retirement_revision" => retired["revision"],
      "source_maintenance_revision" => barrier.revision,
      "source_rule_generation" => barrier.rule_generation,
      "archive_digest" => basis.archive_digest,
      "snapshot_digest" => basis.snapshot_digest,
      "runtime_digest" => runtime,
      "owner_custody_digest" => String.duplicate("b", 64),
      "challenge_id" => "challenge:original",
      "principal_id" => "operator:fresh",
      "credential_hash" => Base.encode16(hash, case: :lower),
      "permissions_document" =>
        "[\"read\",\"host:maintain\",\"profile:manage\",\"enroll:review\"]",
      "domain_digest" => basis.domains.domain_digest,
      "domain_count" => basis.domains.domain_count,
      "counter_state" => basis.domains.counter_state,
      "counter_state_digest" => nil,
      "issued_at_utc_ms" => 1_000,
      "expires_at_utc_ms" => 61_000
    }

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      public_key: public,
      generation: 1,
      method: "physical_disconnection",
      procedure_ref: "procedure:fixture",
      policy_digest: String.duplicate("c", 64),
      counter_state: "no_radio_state"
    }

    {:ok, review_document} = TransferReviewCodec.encode(review)
    {:ok, scope} = TransferReviewCodec.isolation_scope(review)

    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => policy.method,
        "procedure_ref" => policy.procedure_ref,
        "issuer_id" => "issuer:fixture",
        "issuer_generation" => 1,
        "isolation_policy_digest" => policy.policy_digest,
        "issued_at_utc_ms" => 1_000,
        "expires_at_utc_ms" => 61_000
      })

    {:ok, payload} = IsolationDecision.signing_payload(decision)

    {:ok, package} =
      IsolationDecision.encode(
        decision,
        :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      )

    {:ok, policy_document} = TransferAcceptanceCodec.policy_document("issuer:fixture", policy)

    guard = fn ->
      with {:ok, isolated} <-
             IsolationDecision.verify(package, scope, %{"issuer:fixture" => policy}, %{
               confidence: :trusted,
               now_utc_ms: 2_000
             }),
           do: {:ok, isolated, policy_document}
    end

    input = %{
      "principal_id" => "operator:fresh",
      "source_epoch" => 1,
      "operation_id" => "accept:original",
      "retirement_revision" => retired["revision"],
      "destination_owner_id" => destination_owner,
      "review_digest" => Artifact.digest(review_document),
      "isolation_package_digest" => Artifact.digest(package)
    }

    %{
      root: root,
      store: store,
      source: path,
      path: Path.join(destination, "home.sqlite"),
      credential: credential,
      old_credential: controller,
      input: input,
      guard: guard,
      review: review,
      review_document: review_document,
      domains: basis.domains.document,
      retired: retired,
      schedule_history: schedule_history,
      key: key
    }
  end

  test "destination acceptance advances exactly three revisions and preserves source history",
       c do
    receipt = accept(c)
    assert receipt["authority_epoch"] == 2 and receipt["revision"] == c.retired["revision"] + 3
    assert receipt["revoked_principals"] == 4 and receipt["revoked_qualifications"] == 0

    assert Enum.all?(
             ~w(cleared_observations cleared_target_grants cleared_source_grants cleared_override_leases),
             &(receipt[&1] == 1)
           )

    with_db(c.path, fn db ->
      assert :ok = Integrity.validate_snapshot(db)
      assert {:ok, [[24]]} = SQL.query(db, "PRAGMA user_version")

      assert {:ok, [[1, 1, 1]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM controller_acceptances),(SELECT COUNT(*) FROM controller_retirements),(SELECT COUNT(*) FROM journal)"
               )

      assert {:ok, ^receipt} = TransferWriter.existing(db, c.credential, c.input)
      assert {:error, :unauthorized} = TransferWriter.existing(db, c.old_credential, c.input)

      assert :not_found =
               TransferWriter.existing(db, c.credential, %{
                 c.input
                 | "principal_id" => "operator:other"
               })

      assert {:error, :controller_operation_conflict} =
               TransferWriter.existing(db, c.credential, %{
                 c.input
                 | "review_digest" => String.duplicate("e", 64)
               })

      assert {:ok, %{state: "active", authority_epoch: 2, retirement_revision: revision}} =
               ControllerWriter.identity(db)

      assert revision == receipt["revision"]
      assert {:ok, [[1]]} = SQL.query(db, "SELECT COUNT(*) FROM principals WHERE status='active'")
    end)

    destination = start_supervised!({Store, path: c.path}, id: :destination)

    assert {:ok, %{writable: true, dispatch_enabled: false, authority_epoch: 2}} =
             Store.health(destination)

    assert {:ok, %{state: :maintenance, begin_revision: revision}} =
             Store.maintenance_status(destination, c.credential)

    assert revision == receipt["revision"]
    assert {:error, :unauthorized} = Store.maintenance_status(destination, c.old_credential)

    assert {:ok, %{state: :normal, rule_generation: generation}} =
             Store.end_maintenance(
               destination,
               c.credential,
               2,
               "maintenance:end",
               receipt["revision"],
               receipt["revision"]
             )

    assert generation == receipt["rule_generation"]
    archive = Path.join(c.root, "accepted.woh")
    assert {:ok, _} = Store.export_backup(destination, archive, c.key)
    assert {:ok, %{authority_epoch: 2}} = Backup.verify(archive, c.key)
  end

  @tag schedule_history: true
  test "retained temporal admission survives owner transfer without reactivating the old author",
       c do
    {original, admission, old_manager} = c.schedule_history
    receipt = accept(c)
    assert receipt["authority_epoch"] == 2

    with_db(c.path, fn db ->
      assert :ok = Integrity.validate_snapshot(db)
      assert :ok = WotexHome.Durable.Store.ScheduleWriter.validate(db)

      assert {:ok, [[^original, revision, "manager:schedule", 1]]} =
               SQL.query(
                 db,
                 "SELECT input_document,revision,principal_id,authority_epoch FROM schedule_admissions"
               )

      assert revision == admission.revision

      assert {:error, :schedule_basis_changed} =
               WotexHome.Durable.Store.ScheduleWriter.current_admission(db, revision)
    end)

    destination = start_supervised!({Store, path: c.path}, id: :destination)

    assert {:error, :unauthorized} =
             Store.original_schedule_status(destination, old_manager, original)

    assert {:ok, %{authority_epoch: 2, held_requests: 0, dispatch_enabled: false}} =
             Store.health(destination)

    archive = Path.join(c.root, "accepted-schedule.woh")
    assert {:ok, _} = Store.export_backup(destination, archive, c.key)
    assert {:ok, %{authority_epoch: 2}} = Backup.verify(archive, c.key)
  end

  @tag historical: true
  test "historical schema twenty one accepts with schema installation in the same transaction",
       c do
    assert receipt = accept(c)
    assert receipt["revision"] == c.retired["revision"] + 3
    with_db(c.path, fn db -> assert {:ok, [[24]]} = SQL.query(db, "PRAGMA user_version") end)
  end

  for {label, trigger} <- [
        {"epoch", "BEFORE UPDATE OF value ON meta"},
        {"fence", "BEFORE INSERT ON authority_journal"},
        {"principal withdrawal", "BEFORE UPDATE OF status ON principals"},
        {"reports", "BEFORE DELETE ON observation_current"},
        {"target grants", "BEFORE DELETE ON principal_targets"},
        {"source grants", "BEFORE DELETE ON source_epoch_grants"},
        {"leases", "BEFORE DELETE ON operator_override_leases"},
        {"fresh principal", "BEFORE INSERT ON principals"},
        {"acceptance row", "BEFORE INSERT ON controller_acceptances"},
        {"maintenance", "BEFORE INSERT ON host_maintenance_operations"},
        {"owner", "BEFORE UPDATE ON controller_identity"},
        {"quarantine", "BEFORE DELETE ON meta"}
      ] do
    @tag trigger: trigger
    @tag epoch_fault: label == "epoch"
    test "#{label} failure rolls back every row and leaves original quarantine", c do
      with_db(c.path, fn db ->
        assert {:ok, before} = RecoverySnapshot.commitment(db, :quarantine)
        assert {:error, _} = commit(db, c, c.guard)
        assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)

        assert {:ok, [[1, 0]]} =
                 SQL.query(
                   db,
                   "SELECT (SELECT value FROM meta WHERE key='authority_epoch'),(SELECT COUNT(*) FROM controller_acceptances)"
                 )
      end)
    end
  end

  @tag alter_retained: true
  test "unexpected retained credential changes roll back even when row integrity still passes",
       c do
    with_db(c.path, fn db ->
      assert {:ok, before} = RecoverySnapshot.commitment(db, :quarantine)
      assert {:error, :transfer_review_changed} = commit(db, c, c.guard)
      assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)
    end)
  end

  test "changed or failed owner context before commit rolls back the completed transition", c do
    with_db(c.path, fn db ->
      assert {:ok, before} = RecoverySnapshot.commitment(db, :quarantine)

      for denied <- [
            fn -> {:error, :isolation_trust_unavailable} end,
            fn -> raise "fixture unavailable" end,
            fn -> {:ok, %{}, nil} end
          ] do
        assert {:error, _} = commit(db, c, denied)
        assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)
      end

      counter = :counters.new(1, [])

      guard = fn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: c.guard.(),
          else: {:error, :isolation_decision_expired}
      end

      assert {:error, :isolation_decision_expired} = commit(db, c, guard)
      assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)
    end)
  end

  test "a second reviewed transfer retains both original histories and transfers the active barrier",
       c do
    first = accept(c)
    source = start_supervised!({Store, path: c.path}, id: :accepted_source)

    {:ok, transfer, revision} =
      Store.provision_principal(source, "transfer:next", ["host:transfer"], [])

    {:ok, retired} =
      Store.retire_controller(source, transfer, %{
        "authority_epoch" => 2,
        "operation_id" => "retire:next",
        "expected_revision" => revision,
        "destination_owner_id" => String.duplicate("d", 64)
      })

    assert retired["maintenance_revision"] == first["revision"]
    archive = Path.join(c.root, "second-source.woh")
    {:ok, _} = Store.export_profile_backup(source, archive, c.key)
    {:ok, basis} = Backup.retired_transfer_basis(archive, c.key)
    destination = Path.join(c.root, "second-destination")
    {:ok, _} = Backup.stage_profile_restore(archive, c.key, destination)
    credential = :crypto.strong_rand_bytes(32)
    {:ok, hash} = WotexHome.Durable.Registry.credential_hash(credential)

    review =
      Map.merge(c.review, %{
        "source_owner_id" => retired["source_owner_id"],
        "destination_owner_id" => retired["destination_owner_id"],
        "source_epoch" => 2,
        "retirement_revision" => retired["revision"],
        "source_maintenance_revision" => first["revision"],
        "source_rule_generation" => first["rule_generation"],
        "archive_digest" => basis.archive_digest,
        "snapshot_digest" => basis.snapshot_digest,
        "challenge_id" => "challenge:second",
        "principal_id" => "operator:second",
        "credential_hash" => Base.encode16(hash, case: :lower),
        "domain_digest" => basis.domains.domain_digest
      })

    {:ok, document} = TransferReviewCodec.encode(review)
    {guard, package_digest} = signed_guard(review)

    input =
      Map.merge(c.input, %{
        "principal_id" => "operator:second",
        "source_epoch" => 2,
        "operation_id" => "accept:second",
        "retirement_revision" => retired["revision"],
        "destination_owner_id" => retired["destination_owner_id"],
        "review_digest" => Artifact.digest(document),
        "isolation_package_digest" => package_digest
      })

    next = %{
      c
      | path: Path.join(destination, "home.sqlite"),
        input: input,
        review: review,
        review_document: document,
        domains: basis.domains.document,
        guard: guard,
        credential: credential
    }

    second = accept(next)

    assert second["authority_epoch"] == 3 and
             second["source_maintenance_revision"] == first["revision"]

    assert second["revoked_principals"] == 2

    with_db(next.path, fn db ->
      assert :ok = Integrity.validate_snapshot(db)

      assert {:ok, [[2, 2]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM controller_acceptances),(SELECT COUNT(*) FROM controller_retirements)"
               )

      assert {:ok, ^first} = TransferWriter.existing(db, c.credential, c.input)
      assert {:ok, ^second} = TransferWriter.existing(db, credential, input)
    end)

    final = start_supervised!({Store, path: next.path}, id: :second_owner)

    assert {:ok, %{state: :maintenance, begin_revision: barrier}} =
             Store.maintenance_status(final, credential)

    assert barrier == second["revision"]
    {:ok, rotated, _} = Store.rotate_principal_credential(final, "operator:second")
    assert {:error, :unauthorized} = Store.maintenance_status(final, credential)
    assert {:ok, %{state: :maintenance}} = Store.maintenance_status(final, rotated)

    {:ok, granted, _} = Store.grant_target_and_rotate(final, "operator:second", "light:fixture")
    assert {:error, :unauthorized} = Store.maintenance_status(final, rotated)
    assert {:ok, %{state: :maintenance}} = Store.maintenance_status(final, granted)
    with_db(next.path, fn db -> assert :ok = Integrity.validate_snapshot(db) end)
    archive = Path.join(c.root, "second-accepted.woh")
    assert {:ok, _} = Store.export_backup(final, archive, c.key)
    assert {:ok, %{authority_epoch: 3}} = Backup.verify(archive, c.key)
  end

  test "accepted ownership rejects altered retained documents, principal and barrier correspondence",
       c do
    accept(c)

    with_db(c.path, fn db ->
      for statement <- [
            "UPDATE controller_acceptances SET review_document=review_document||' '",
            "UPDATE controller_acceptances SET isolation_package=isolation_package||' '",
            "UPDATE controller_acceptances SET isolation_document=isolation_document||' '",
            "UPDATE controller_acceptances SET issuer_policy_document=issuer_policy_document||' '",
            "UPDATE controller_acceptances SET domain_document=domain_document||' '",
            "UPDATE principals SET credential_hash=zeroblob(32) WHERE principal_id='operator:fresh'",
            "UPDATE principals SET permissions='[\"read\"]' WHERE principal_id='operator:fresh'",
            "UPDATE host_maintenance_operations SET begin_revision=1 WHERE action='transfer'",
            "UPDATE authority_journal SET entity_id='controller:wrong' WHERE event_type='controller_destination_accepted'",
            "DELETE FROM controller_acceptances"
          ] do
        assert {:error, :fixture_rollback} =
                 SQL.transaction(db, fn db ->
                   assert :ok = Sqlite3.execute(db, statement)
                   assert {:error, _} = Integrity.validate_snapshot(db)
                   {:rollback, :fixture_rollback}
                 end)

        assert :ok = Integrity.validate_snapshot(db)
      end
    end)
  end

  @tag unknown_outcome: true
  test "unknown handoff receipts and spent causal roots survive acceptance without replay", c do
    before =
      with_db(c.path, fn db ->
        for table <- ~w(request_receipts request_execution request_journal request_causal_roots) do
          {:ok, rows} = SQL.query(db, "SELECT * FROM #{table} ORDER BY 1")
          {table, rows}
        end
      end)

    accept(c)

    with_db(c.path, fn db ->
      for {table, rows} <- before do
        assert {:ok, ^rows} = SQL.query(db, "SELECT * FROM #{table} ORDER BY 1")
      end

      assert {:ok, [[1]]} = SQL.query(db, "SELECT reserved_effects FROM request_causal_roots")
      assert {:ok, [["outcome_unknown"]]} = SQL.query(db, "SELECT state FROM request_execution")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  @tag source_capacity: true
  test "full retained principal capacity refuses a fresh receiving principal without truncation",
       c do
    with_db(c.path, fn db ->
      assert {:ok, before} = RecoverySnapshot.commitment(db, :quarantine)
      assert {:error, :transfer_review_changed} = commit(db, c, c.guard)
      assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)
      assert {:ok, [[64]]} = SQL.query(db, "SELECT COUNT(*) FROM principals")
    end)
  end

  @tag historical: true
  test "final context expiry restores historical schema and original source rows", c do
    with_db(c.path, fn db ->
      assert {:ok, before} = RecoverySnapshot.commitment(db, :quarantine)
      counter = :counters.new(1, [])

      guard = fn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: c.guard.(),
          else: {:error, :isolation_decision_expired}
      end

      assert {:error, :isolation_decision_expired} = commit(db, c, guard)
      assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version")
      assert {:ok, ^before} = RecoverySnapshot.commitment(db, :quarantine)
    end)
  end

  defp accept(c) do
    with_db(c.path, fn db ->
      assert {:ok, {:ok, receipt}} = commit(db, c, c.guard)
      receipt
    end)
  end

  defp commit(db, c, guard),
    do:
      SQL.transaction(
        db,
        &TransferWriter.accept_tx(&1, c.review_document, c.domains, c.input, guard)
      )

  defp signed_guard(review) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      public_key: public,
      generation: 1,
      method: "physical_disconnection",
      procedure_ref: "procedure:fixture",
      policy_digest: String.duplicate("c", 64),
      counter_state: "no_radio_state"
    }

    {:ok, scope} = TransferReviewCodec.isolation_scope(review)

    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => policy.method,
        "procedure_ref" => policy.procedure_ref,
        "issuer_id" => "issuer:fixture",
        "issuer_generation" => 1,
        "isolation_policy_digest" => policy.policy_digest,
        "issued_at_utc_ms" => 1_000,
        "expires_at_utc_ms" => 61_000
      })

    {:ok, payload} = IsolationDecision.signing_payload(decision)

    {:ok, package} =
      IsolationDecision.encode(
        decision,
        :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      )

    {:ok, policy_document} = TransferAcceptanceCodec.policy_document("issuer:fixture", policy)

    guard = fn ->
      with {:ok, isolated} <-
             IsolationDecision.verify(package, scope, %{"issuer:fixture" => policy}, %{
               confidence: :trusted,
               now_utc_ms: 2_000
             }),
           do: {:ok, isolated, policy_document}
    end

    {guard, Artifact.digest(package)}
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
