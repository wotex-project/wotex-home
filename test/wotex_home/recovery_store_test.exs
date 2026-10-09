Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))
Code.require_file(Path.expand("../support/schema_fixtures.exs", __DIR__))

defmodule WotexHome.RecoveryStoreTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, RecoverySnapshot, SQL}
  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Profiles.{Artifact, Custody}

  alias WotexHome.Recovery.{
    ClockCodec,
    ClockOwner,
    Destination,
    IsolationDecision,
    IssuerPolicies,
    Owner,
    PrivateFile,
    Receiver,
    ReviewOwner,
    TransferAcceptanceCodec,
    TransferReviewCodec
  }

  setup tags do
    Process.flag(:trap_exit, true)
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-recovery-store-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    profiles = Path.join(root, "profiles")
    File.mkdir!(profiles)
    File.chmod!(profiles, 0o700)
    owner_file = Path.join(root, "owner.json")
    {:ok, owner} = Owner.create(owner_file)
    source = Path.join(root, "home.sqlite")
    store = start_supervised!({Store, path: source, profile_custody: __MODULE__.Custody})

    start_supervised!({Custody, root: profiles, name: __MODULE__.Custody, store_owner: store})
    authority = Authority.new(store: store)

    {:ok, operator, 1} =
      Store.provision_principal(store, "operator:source", ["enroll:review"], [])

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

    if tags[:retained_profile] do
      {:ok, _, _} = Authority.provision_profile_manager(authority)
    end

    {:ok, revision} = Store.revision(store)

    {:ok, _barrier} =
      Store.begin_maintenance(store, maintainer, 1, "maintenance:source", revision)

    if tags[:retained_profile] do
      {:ok, manager, _} = Store.rotate_principal_credential(store, "profiles:local")
      bytes = File.read!(Path.expand("../../priv/profiles/lifx-power-example.json", __DIR__))

      {:ok, digest} =
        Authority.stage_profile(
          %{authority | profile_custody: __MODULE__.Custody},
          manager,
          bytes
        )

      {:ok, revision} = Store.revision(store)

      {:ok, _} =
        Authority.profile_change(authority, manager, %{
          "action" => "approve",
          "authority_epoch" => 1,
          "operation_id" => "profile:source",
          "expected_revision" => revision,
          "artifact_digest" => digest,
          "expected_trust_revision" => 0
        })
    end

    {:ok, revision} = Store.revision(store)

    {:ok, retired} =
      Store.retire_controller(store, transfer, %{
        "authority_epoch" => 1,
        "operation_id" => "retire:source",
        "expected_revision" => revision,
        "destination_owner_id" => owner.owner_id
      })

    if tags[:historical] do
      :ok = GenServer.stop(store)

      with_db(source, fn db ->
        :ok =
          Sqlite3.execute(
            db,
            WotexHome.Test.SchemaFixtures.drop_transfer_acceptance() <>
              "PRAGMA user_version=21"
          )
      end)
    end

    if tags[:write_failure] do
      with_db(source, fn db ->
        assert :ok =
                 Sqlite3.execute(
                   db,
                   "CREATE TRIGGER failed_acceptance BEFORE UPDATE OF value ON meta WHEN NEW.key='authority_epoch' AND NEW.value=2 BEGIN SELECT RAISE(ABORT,'synthetic failure'); END"
                 )
      end)
    end

    archive = Path.join(root, "source.woh")
    key = :crypto.strong_rand_bytes(32)

    if tags[:historical] do
      with_db(source, fn db ->
        {:ok, _} = Backup.export_profiles(db, archive, key, __MODULE__.Custody)
      end)
    else
      {:ok, _} = Store.export_profile_backup(store, archive, key)
    end

    destination = Path.join(root, "destination")
    {:ok, _} = Backup.stage_profile_restore(archive, key, destination)
    reviews = Path.join(root, "reviews")
    File.mkdir!(reviews)
    File.chmod!(reviews, 0o700)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      public_key: public,
      generation: 1,
      method: "physical_disconnection",
      procedure_ref: "procedure:synthetic",
      policy_digest: String.duplicate("c", 64),
      counter_state: "no_radio_state"
    }

    context =
      start_supervised!(
        {Agent,
         fn ->
           %{
             clock: %{confidence: :trusted, now_utc_ms: 2_000},
             trust: %{"issuer:synthetic" => policy}
           }
         end}
      )

    review_owner =
      start_supervised!(
        {ReviewOwner,
         operator: self(),
         root: reviews,
         owner_file: owner_file,
         profile_root: Path.join(destination, "profiles"),
         archive_basis: fn -> Backup.retired_transfer_basis(archive, key) end,
         clock: fn -> Agent.get(context, & &1.clock) end,
         issuer_policies: fn -> Agent.get(context, & &1.trust) end}
      )

    path = Path.join(destination, "home.sqlite")

    recovery =
      start_supervised!(
        Supervisor.child_spec(
          {Store,
           path: path,
           controller_mode: :recovery,
           recovery_operator: self(),
           recovery_reviews: review_owner},
          id: :recovery,
          restart: :temporary
        )
      )

    :ok = ReviewOwner.bind_store(review_owner, recovery)

    %{
      root: root,
      source: source,
      path: path,
      archive: archive,
      key: key,
      retired: retired,
      old_credential: operator,
      private: private,
      policy: policy,
      context: context,
      reviews: reviews,
      owner_file: owner_file,
      review_owner: review_owner,
      recovery: recovery,
      authority: Authority.new(store: recovery, capture: nil)
    }
  end

  test "public Authority acceptance consumes the review and keeps the recovery Store read-only",
       c do
    ready = prepare(c)
    assert {:ok, receipt} = accept(c, ready)
    assert receipt["revision"] == c.retired["revision"] + 3
    assert receipt["authority_epoch"] == 2
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)

    assert {:ok, %{writable: false, dispatch_enabled: false, authority_epoch: 2}} =
             Store.health(c.recovery)

    assert {:ok, ^receipt} = accept(c, ready)

    assert {:ok, ^receipt} =
             Authority.transfer_acceptance_status(c.authority, ready.credential, ready.input)

    assert {:error, :unauthorized} =
             Authority.transfer_acceptance_status(c.authority, c.old_credential, ready.input)

    assert {:error, :controller_operation_conflict} =
             accept(c, %{
               ready
               | input: %{ready.input | "review_digest" => String.duplicate("e", 64)}
             })

    assert {:error, :recovery_already_accepted} =
             accept(c, %{ready | input: %{ready.input | "operation_id" => "accept:other"}})

    for request <- [
          {:provision_principal, "reader:unexpected", ["read"], []},
          {:record, nil, nil},
          {:begin_maintenance, ready.credential, 2, "maint:new", receipt["revision"]},
          {:export_backup, Path.join(c.root, "unrequested.woh"), c.key},
          {:claim_lifx_power, nil, nil, nil, nil},
          :revision
        ] do
      assert {:error, :recovery_operation_forbidden} = GenServer.call(c.recovery, request)
    end

    with_db(c.path, fn db ->
      assert :ok = Integrity.validate_snapshot(db)

      assert {:ok, [[receipt_revision]]} =
               SQL.query(db, "SELECT value FROM meta WHERE key='revision'")

      assert receipt_revision == receipt["revision"]
    end)

    :ok = stop_supervised(:recovery)
    destination = start_supervised!({Store, path: c.path}, id: :normal_destination)
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(destination)

    assert {:ok, %{state: :maintenance, begin_revision: revision}} =
             Store.maintenance_status(destination, ready.credential)

    assert revision == receipt["revision"]
  end

  @tag historical: true
  test "recovery startup leaves retired schema twenty one unchanged until acceptance", c do
    with_db(c.path, fn db -> assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version") end)
    ready = prepare(c)
    assert {:ok, _} = accept(c, ready)
    with_db(c.path, fn db -> assert {:ok, [[28]]} = SQL.query(db, "PRAGMA user_version") end)
  end

  test "accepted ordinary owner bootstraps a separate current transfer role without reviving source",
       c do
    ready = prepare(c)
    {:ok, accepted} = accept(c, ready)
    assert {:error, :recovery_operation_forbidden} = Store.provision_transfer(c.recovery)
    :ok = stop_supervised(:recovery)
    store = start_supervised!({Store, path: c.path}, id: :normal_destination)
    authority = Authority.new(store: store)
    assert {:ok, transfer, revision} = Authority.provision_transfer(authority)
    assert revision == accepted["revision"] + 1
    assert {:error, :principal_exists} = Authority.provision_transfer(authority)

    assert {:ok, %{authority_epoch: 2, state: "active"}} =
             Authority.controller_status(authority, transfer)

    assert {:error, :permission_denied} =
             Store.maintenance_status(store, transfer)

    assert {:error, :transfer_target_forbidden} =
             Store.grant_target_and_rotate(store, "transfer:epoch:2", "light:desk")

    with_db(c.path, fn db ->
      assert {:ok, [["revoked"], ["active"]]} =
               SQL.query(
                 db,
                 "SELECT status FROM principals WHERE principal_id IN ('transfer:local','transfer:epoch:2') ORDER BY principal_id DESC"
               )

      assert {:ok, [["[\"host:transfer\"]"]]} =
               SQL.query(
                 db,
                 "SELECT permissions FROM principals WHERE principal_id='transfer:epoch:2'"
               )

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM principal_targets WHERE principal_id LIKE 'transfer:%'"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    assert {:ok, _} =
             compiled_rereview(
               c,
               store,
               ready.credential,
               ready.input["principal_id"],
               "review:second-owner"
             )

    assert {:ok, native_identity} = Authority.native_setup_identity(authority)
    native_secret = :crypto.strong_rand_bytes(32)

    native_input =
      native_identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => :crypto.hash(:sha256, native_secret) |> Base.encode16(case: :lower)
      })

    assert {:ok, native_receipt} = Authority.ensure_native_principal(authority, native_input)
    assert native_receipt["principal_id"] == "native-setup-v1:2:operator"
    assert {:ok, ^native_receipt} = Authority.ensure_native_principal(authority, native_input)

    {:ok, revision} = Store.revision(store)
    owner_file = Path.join(c.root, "third-owner.json")
    {:ok, third_owner} = Owner.create(owner_file)

    {:ok, retired} =
      Authority.retire_controller(authority, transfer, %{
        "authority_epoch" => 2,
        "operation_id" => "retire:second",
        "expected_revision" => revision,
        "destination_owner_id" => third_owner.owner_id
      })

    assert retired["principal_id"] == "transfer:epoch:2"
    assert retired["maintenance_revision"] == accepted["revision"]
    assert {:error, :source_retired} = Authority.provision_transfer(authority)
    assert {:error, :source_retired} = Authority.ensure_native_principal(authority, native_input)
    assert {:ok, ^retired} = Authority.retirement_status(authority, transfer, 2, "retire:second")
    with_db(c.path, &assert(:ok == Integrity.validate_snapshot(&1)))
    archive = Path.join(c.root, "second-retired.woh")
    assert {:ok, _} = Store.export_profile_backup(store, archive, c.key)
    assert {:ok, %{authority_epoch: 2}} = Backup.verify(archive, c.key)

    directory = Path.join(c.root, "third-destination")
    assert {:ok, _} = Backup.stage_profile_restore(archive, c.key, directory)
    reviews = Path.join(c.root, "third-reviews")
    File.mkdir!(reviews)
    File.chmod!(reviews, 0o700)
    :ok = stop_supervised(ReviewOwner)

    next = %{
      c
      | path: Path.join(directory, "home.sqlite"),
        archive: archive,
        owner_file: owner_file,
        reviews: reviews
    }

    {:ok, session} = Destination.start_link(destination_options(next))
    on_exit(fn -> if Process.alive?(session), do: Supervisor.stop(session) end)
    {:ok, third_authority} = Destination.authority(session)

    next = %{
      next
      | authority: third_authority,
        recovery: third_authority.store,
        review_owner: third_authority.recovery_reviews
    }

    third = prepare(next)
    assert {:ok, third_receipt} = accept(next, third)
    assert third_receipt["authority_epoch"] == 3
    assert third_receipt["source_epoch"] == 2
    assert third_receipt["destination_owner_id"] == third_owner.owner_id

    assert {:ok, ^accepted} =
             Authority.transfer_acceptance_status(third_authority, ready.credential, ready.input)

    with_db(next.path, &assert(:ok == Integrity.validate_snapshot(&1)))
    :ok = Supervisor.stop(session)
    third_store = start_supervised!({Store, path: next.path}, id: :third_normal)
    assert {:ok, %{authority_epoch: 3, dispatch_enabled: false}} = Store.health(third_store)
    native_authority = Authority.new(store: third_store)

    assert {:error, :native_owner_changed} =
             Authority.ensure_native_principal(native_authority, native_input)

    assert {:error, :unauthorized} = Authority.health(native_authority, native_secret)
    assert {:ok, third_identity} = Authority.native_setup_identity(native_authority)
    third_secret = :crypto.strong_rand_bytes(32)

    third_input =
      third_identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => :crypto.hash(:sha256, third_secret) |> Base.encode16(case: :lower)
      })

    assert {:ok, third_native} = Authority.ensure_native_principal(native_authority, third_input)
    assert third_native["principal_id"] == "native-setup-v1:3:operator"
    assert {:ok, ^third_native} = Authority.ensure_native_principal(native_authority, third_input)
    assert {:ok, %{dispatch_enabled: false}} = Authority.health(native_authority, third_secret)

    with_db(next.path, fn db ->
      assert {:ok, [["revoked"], ["active"]]} =
               SQL.query(
                 db,
                 "SELECT status FROM principals WHERE principal_id IN ('native-setup-v1:2:operator','native-setup-v1:3:operator') ORDER BY principal_id"
               )

      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM principal_targets WHERE principal_id LIKE 'native-setup-v1:%'"
               )
    end)

    assert {:ok, _} =
             compiled_rereview(
               next,
               third_store,
               third.credential,
               third.input["principal_id"],
               "review:third-owner"
             )

    assert {:ok, third_transfer, _} =
             Authority.provision_transfer(Authority.new(store: third_store))

    assert {:ok, %{authority_epoch: 3}} = Store.controller_status(third_store, third_transfer)
    assert {:error, :unauthorized} = Store.controller_status(third_store, transfer)

    with_db(next.path, fn db ->
      assert {:ok, [["active"]]} =
               SQL.query(
                 db,
                 "SELECT status FROM principals WHERE principal_id='transfer:epoch:3'"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "fresh transfer bootstrap failure rolls back the new role and authority revision", c do
    ready = prepare(c)
    {:ok, _} = accept(c, ready)
    :ok = stop_supervised(:recovery)
    store = start_supervised!({Store, path: c.path}, id: :normal_destination)

    snapshot = fn ->
      with_db(c.path, fn db ->
        for table <- ["meta", "principals", "authority_journal"],
            do: SQL.query(db, "SELECT * FROM #{table} ORDER BY 1")
      end)
    end

    before = snapshot.()

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER failed_transfer_role BEFORE INSERT ON authority_journal WHEN NEW.event_type='principal_provisioned' AND NEW.entity_id='transfer:epoch:2' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END"
        )
    end)

    assert {:error, _} = Authority.provision_transfer(Authority.new(store: store))
    assert snapshot.() == before

    with_db(c.path, fn db ->
      assert {:ok, [[0]]} =
               SQL.query(
                 db,
                 "SELECT COUNT(*) FROM principals WHERE principal_id='transfer:epoch:2'"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "accepted reviewer rechecks retained compiled identity with private retry and restart history",
       c do
    c = normal_destination(c)
    principal = c.ready.input["principal_id"]

    assert {:ok, revision} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               principal,
               "review:destination"
             )

    assert {:ok, ^revision} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               principal,
               "review:destination"
             )

    assert {:error, :review_conflict} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               principal,
               "review:destination",
               %{"candidate_ref" => "capture:changed"}
             )

    assert {:ok, %{state: :current, review_revision: ^revision}} =
             Store.enrollment_review_status(
               c.normal_store,
               c.ready.credential,
               "review:destination"
             )

    assert :not_found =
             Store.enrollment_review_status(c.normal_store, c.ready.credential, "review:compiled")

    assert {:error, :unauthorized} =
             Store.enrollment_review_status(c.normal_store, c.old_credential, "review:compiled")

    with_db(c.path, fn db ->
      assert {:ok, [[^principal]]} = SQL.query(db, "SELECT operator_id FROM enrollment_bindings")

      assert {:ok, [["operator:source"], [^principal]]} =
               SQL.query(
                 db,
                 "SELECT operator_id FROM enrollment_review_history ORDER BY revision"
               )

      assert {:ok, [[0, 0, 0]]} =
               SQL.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM principal_targets),(SELECT COUNT(*) FROM observation_current),(SELECT COUNT(*) FROM profile_qualifications WHERE status='qualified')"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)

    archive = Path.join(c.root, "reviewed-destination.woh")
    assert {:ok, _} = Store.export_profile_backup(c.normal_store, archive, c.key)
    assert {:ok, %{authority_epoch: 2}} = Backup.verify(archive, c.key)
    :ok = stop_supervised(:normal_destination)
    restarted = start_supervised!({Store, path: c.path}, id: :reviewed_restart)
    assert {:ok, %{dispatch_enabled: false, writable: true}} = Store.health(restarted)

    assert {:ok, ^revision} =
             compiled_rereview(c, restarted, c.ready.credential, principal, "review:destination")

    assert {:error, :recovery_operation_required} =
             Store.transfer_acceptance_status(restarted, c.ready.credential, c.ready.input)

    :ok = stop_supervised(:reviewed_restart)

    {:ok, session} =
      Destination.start_link(
        directory: Path.dirname(c.path),
        owner_file: c.owner_file,
        review_root: c.reviews,
        archive_basis: fn -> {:error, :archive_unavailable} end
      )

    on_exit(fn -> if Process.alive?(session), do: Supervisor.stop(session) end)
    {:ok, authority} = Destination.authority(session)

    assert {:ok, receipt} =
             Authority.transfer_acceptance_status(authority, c.ready.credential, c.ready.input)

    assert receipt == c.accepted
  end

  test "review permission does not let unrelated reviewers or copied credentials take an enrollment",
       c do
    c = normal_destination(c)

    {:ok, other, _} =
      Store.provision_principal(c.normal_store, "reviewer:other", ["enroll:review"], [])

    assert {:error, :review_binding_mismatch} =
             compiled_rereview(c, c.normal_store, other, "reviewer:other", "review:other")

    assert {:error, :permission_denied} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               "operator:source",
               "review:forged-source"
             )

    assert {:error, :unauthorized} =
             compiled_rereview(
               c,
               c.normal_store,
               c.old_credential,
               "operator:source",
               "review:copied"
             )

    assert {:ok, _} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               c.ready.input["principal_id"],
               "review:destination"
             )

    assert {:error, :review_binding_mismatch} =
             compiled_rereview(c, c.normal_store, other, "reviewer:other", "review:other")

    with_db(c.path, &assert(:ok == Integrity.validate_snapshot(&1)))
  end

  test "current succession refuses substituted binding or retained head bytes", c do
    c = normal_destination(c)
    principal = c.ready.input["principal_id"]

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "UPDATE enrollment_review_history SET firmware='1.23' WHERE review_ref='review:compiled'"
        )
    end)

    assert {:error, :review_binding_mismatch} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               principal,
               "review:changed-head"
             )

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "UPDATE enrollment_review_history SET firmware='1.22' WHERE review_ref='review:compiled'; UPDATE enrollment_bindings SET candidate_ref='capture:substituted'; UPDATE enrollment_review_history SET candidate_ref='capture:substituted' WHERE review_ref='review:compiled'"
        )
    end)

    assert {:error, :review_binding_mismatch} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               principal,
               "review:changed-binding"
             )

    with_db(c.path, fn db ->
      assert {:ok, [[1]]} = SQL.query(db, "SELECT COUNT(*) FROM enrollment_review_history")
    end)
  end

  test "accepted review permission cannot take another operator's later enrollment", c do
    c = normal_destination(c)
    fixture = WotexHome.Test.PortableProfileFixture.context()

    {:ok, other, _} =
      Store.provision_principal(c.normal_store, "reviewer:later", ["enroll:review"], [])

    {:ok, package} = ProfileCatalogue.fetch(fixture.current.profile_ref, "light:later")

    candidate = %{
      hd(fixture.evidence.candidates)
      | raw_ref: "capture:later",
        claimed_identifiers: %{"stable_id" => "lifx:d073d5000002"}
    }

    interview = %{
      fixture.evidence.interview
      | candidate_ref: candidate.raw_ref,
        stable_id: "lifx:d073d5000002"
    }

    selection = %{
      "operator_id" => "reviewer:later",
      "candidate_ref" => candidate.raw_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => package.thing.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:later"
    }

    assert {:ok, _} =
             Store.commit_enrollment(
               c.normal_store,
               other,
               [candidate],
               interview,
               [package.profile],
               package.thing,
               selection
             )

    takeover = %{
      selection
      | "operator_id" => c.ready.input["principal_id"],
        "review_ref" => "review:takeover"
    }

    assert {:error, :review_binding_mismatch} =
             Store.rereview_enrollment(
               c.normal_store,
               c.ready.credential,
               [candidate],
               interview,
               [package.profile],
               package.thing,
               takeover
             )

    assert {:ok, _} =
             Store.rereview_enrollment(
               c.normal_store,
               other,
               [candidate],
               interview,
               [package.profile],
               package.thing,
               %{selection | "review_ref" => "review:later:current"}
             )

    with_db(c.path, &assert(:ok == Integrity.validate_snapshot(&1)))
  end

  test "succession cannot reuse an archived declaration after its resource changed", c do
    c = normal_destination(c)
    fixture = WotexHome.Test.PortableProfileFixture.context()
    capability = fixture.current.capabilities["power"]

    narrowed = %{
      fixture.current
      | capabilities: %{"power" => %{capability | operations: ["read"]}}
    }

    assert {:ok, _} = Store.narrow_thing(c.normal_store, narrowed, 0)
    {:ok, package} = ProfileCatalogue.fetch(fixture.current.profile_ref, fixture.current.id)
    interview = fixture.evidence.interview

    selection = %{
      "operator_id" => c.ready.input["principal_id"],
      "candidate_ref" => interview.candidate_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => package.thing.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:changed-declaration"
    }

    assert {:error, :review_binding_mismatch} =
             Store.rereview_enrollment(
               c.normal_store,
               c.ready.credential,
               fixture.evidence.candidates,
               interview,
               [package.profile],
               narrowed,
               selection
             )

    with_db(c.path, fn db ->
      assert {:ok, [[1]]} = SQL.query(db, "SELECT COUNT(*) FROM enrollment_review_history")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  test "succession journal failure rolls back reviewer, history and revision together", c do
    c = normal_destination(c)

    snapshot = fn ->
      with_db(c.path, fn db ->
        for table <- [
              "meta",
              "enrollment_bindings",
              "enrollment_review_history",
              "authority_journal",
              "source_epoch_grants",
              "observation_current",
              "profile_qualifications"
            ],
            do: SQL.query(db, "SELECT * FROM #{table} ORDER BY 1")
      end)
    end

    before = snapshot.()

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "CREATE TRIGGER failed_succession BEFORE INSERT ON authority_journal WHEN NEW.event_type='thing_enrollment_rereviewed' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END"
        )
    end)

    assert {:error, _} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               c.ready.input["principal_id"],
               "review:failed"
             )

    assert snapshot.() == before
    with_db(c.path, &assert(:ok == Integrity.validate_snapshot(&1)))
  end

  test "historical succession rejects replacing its receiving reviewer with another principal",
       c do
    c = normal_destination(c)

    assert {:ok, _} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               c.ready.input["principal_id"],
               "review:destination"
             )

    {:ok, _, _} =
      Store.provision_principal(c.normal_store, "reviewer:substituted", ["enroll:review"], [])

    with_db(c.path, fn db ->
      :ok =
        Sqlite3.execute(
          db,
          "UPDATE enrollment_bindings SET operator_id='reviewer:substituted'; UPDATE enrollment_review_history SET operator_id='reviewer:substituted' WHERE review_ref='review:destination'"
        )

      assert {:error, _} = Integrity.validate_snapshot(db)
    end)

    :ok = stop_supervised(:normal_destination)
    assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
  end

  test "retained compiled succession can precede a fully reviewed portable profile selection",
       c do
    alias WotexHome.Profiles.{Review, ReviewSession}
    root = Path.join(Path.dirname(c.path), "profiles")

    custody =
      start_supervised!({Custody, root: root, store_owner: __MODULE__.DestinationStore},
        id: :destination_custody
      )

    reviews = start_supervised!({ReviewSession, custody: custody}, id: :destination_profiles)

    c =
      normal_destination(c,
        profile_custody: custody,
        profile_reviews: reviews,
        name: __MODULE__.DestinationStore
      )

    principal = c.ready.input["principal_id"]

    {:ok, binding} =
      compiled_rereview(c, c.normal_store, c.ready.credential, principal, "review:destination")

    fixture = WotexHome.Test.PortableProfileFixture.context()
    {:ok, digest} = Custody.stage(custody, fixture.artifact.bytes)
    {:ok, revision} = Store.revision(c.normal_store)

    {:ok, approved} =
      Store.profile_change(c.normal_store, c.ready.credential, %{
        "action" => "approve",
        "authority_epoch" => 2,
        "operation_id" => "profile:destination:approve",
        "expected_revision" => revision,
        "artifact_digest" => digest,
        "expected_trust_revision" => 0
      })

    {:ok, maintenance} = Store.maintenance_status(c.normal_store, c.ready.credential)

    input = %{
      fixture.input
      | "authority_epoch" => 2,
        "expected_revision" => approved.final_revision,
        "expected_trust_revision" => approved.final_revision,
        "expected_binding_revision" => binding,
        "expected_rule_generation" => maintenance.rule_generation
    }

    {:ok, :new, basis} = Store.profile_selection_basis(c.normal_store, c.ready.credential, input)
    {:ok, runtime} = WotexHome.Lifx.ProfileBasis.runtime_digest()
    {:ok, review} = Review.new(basis, fixture.artifact, fixture.evidence, input, runtime)
    {:ok, _} = ReviewSession.hold(reviews, principal, review)
    assert {:ok, selected} = Store.profile_change(c.normal_store, c.ready.credential, input)
    assert selected.changed_targets == 1

    assert {:error, :profile_lifecycle_required} =
             compiled_rereview(
               c,
               c.normal_store,
               c.ready.credential,
               principal,
               "review:ordinary-blocked"
             )

    with_db(c.path, &assert(:ok == Integrity.validate_snapshot(&1)))
    archive = Path.join(c.root, "selected-destination.woh")
    assert {:ok, _} = Store.export_profile_backup(c.normal_store, archive, c.key)

    assert {:ok, %{authority_epoch: 2, dependencies: %{profile_artifacts: [_]}}} =
             Backup.verify(archive, c.key)

    assert {:ok, identity} = Store.native_setup_identity(c.normal_store)
    secret = :crypto.strong_rand_bytes(32)

    original =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      })

    assert {:ok, native} = Store.ensure_native_principal(c.normal_store, original)
    assert {:ok, revision} = Store.revision(c.normal_store)

    assert {:ok, _} =
             Store.end_maintenance(
               c.normal_store,
               c.ready.credential,
               2,
               "maint:native:normal",
               revision,
               c.accepted["revision"]
             )

    assert {:ok, snapshot} = Store.profile_target(c.normal_store, secret, fixture.current.id)

    grant =
      original
      |> Map.delete("role")
      |> Map.merge(%{
        "creation_revision" => native["revision"],
        "operation_id" => "access:receiving:grant",
        "expected_revision" => snapshot.store_revision,
        "target_id" => snapshot.target_id,
        "resource_revision" => snapshot.resource_revision,
        "binding_revision" => snapshot.binding_revision,
        "selection_generation" => snapshot.selection_generation,
        "artifact_digest" => snapshot.artifact_digest
      })

    assert {:ok, access} = Store.native_target_change(c.normal_store, "grant", grant)
    assert {:ok, %{items: [_]}} = Store.catalogue_page(c.normal_store, secret, nil, nil, 10)
    assert {:ok, transfer, revision} = Store.provision_transfer(c.normal_store)

    assert {:ok, _} =
             Store.begin_maintenance(
               c.normal_store,
               c.ready.credential,
               2,
               "maint:native:transfer",
               revision
             )

    owner_file = Path.join(c.root, "native-third-owner.json")
    assert {:ok, owner} = Owner.create(owner_file)
    assert {:ok, revision} = Store.revision(c.normal_store)

    assert {:ok, _} =
             Store.retire_controller(c.normal_store, transfer, %{
               "authority_epoch" => 2,
               "operation_id" => "retire:native:access",
               "expected_revision" => revision,
               "destination_owner_id" => owner.owner_id
             })

    archive = Path.join(c.root, "retired-native-access.woh")
    assert {:ok, _} = Store.export_profile_backup(c.normal_store, archive, c.key)
    assert {:ok, %{authority_epoch: 2}} = Backup.verify(archive, c.key)
    directory = Path.join(c.root, "native-third-destination")
    assert {:ok, _} = Backup.stage_profile_restore(archive, c.key, directory)
    review_root = Path.join(c.root, "native-third-reviews")
    File.mkdir!(review_root)
    File.chmod!(review_root, 0o700)
    :ok = stop_supervised(ReviewOwner)

    next = %{
      c
      | path: Path.join(directory, "home.sqlite"),
        archive: archive,
        owner_file: owner_file,
        reviews: review_root
    }

    assert {:ok, session} = Destination.start_link(destination_options(next))
    on_exit(fn -> if Process.alive?(session), do: Supervisor.stop(session) end)
    assert {:ok, authority} = Destination.authority(session)

    next = %{
      next
      | authority: authority,
        recovery: authority.store,
        review_owner: authority.recovery_reviews
    }

    ready = prepare(next)
    assert {:ok, accepted} = accept(next, ready)
    assert accepted["authority_epoch"] == 3
    # The receiving owner's exact native grant is withdrawn during acceptance.
    assert accepted["cleared_target_grants"] == 1

    with_db(next.path, fn db ->
      assert {:ok, [[document]]} =
               SQL.query(db, "SELECT receipt_document FROM native_target_operations")

      assert {:ok, ^access} = WotexHome.NativeSetup.TargetCodec.decode("receipt", document)
      assert {:ok, []} = SQL.query(db, "SELECT * FROM principal_targets")
      assert :ok = Integrity.validate_snapshot(db)
    end)

    :ok = Supervisor.stop(session)
    third = start_supervised!({Store, path: next.path}, id: :native_third_owner)
    assert {:error, :native_owner_changed} = Store.native_target_change(third, "grant", grant)
    assert {:error, :unauthorized} = Store.catalogue_page(third, secret, nil, nil, 10)
    assert {:ok, identity} = Store.native_setup_identity(third)

    fresh =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" =>
          Base.encode16(:crypto.hash(:sha256, :crypto.strong_rand_bytes(32)), case: :lower)
      })

    assert {:ok, _} = Store.ensure_native_principal(third, fresh)

    with_db(next.path, fn db ->
      assert {:ok, []} = SQL.query(db, "SELECT * FROM principal_targets")
      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  defp normal_destination(c, options \\ []) do
    ready = prepare(c)
    {:ok, accepted} = accept(c, ready)
    :ok = stop_supervised(:recovery)
    store = start_supervised!({Store, [path: c.path] ++ options}, id: :normal_destination)

    Map.merge(c, %{
      normal_store: store,
      normal_authority: Authority.new(store: store),
      ready: ready,
      accepted: accepted
    })
  end

  defp compiled_rereview(_c, store, credential, principal, reference, changes \\ %{}) do
    fixture = WotexHome.Test.PortableProfileFixture.context()
    {:ok, package} = ProfileCatalogue.fetch(fixture.current.profile_ref, fixture.current.id)
    interview = fixture.evidence.interview
    candidate_ref = Map.get(changes, "candidate_ref", interview.candidate_ref)
    interview = %{interview | candidate_ref: candidate_ref}
    candidates = Enum.map(fixture.evidence.candidates, &%{&1 | raw_ref: candidate_ref})

    selection =
      Map.merge(
        %{
          "operator_id" => principal,
          "candidate_ref" => interview.candidate_ref,
          "stable_id" => interview.stable_id,
          "profile_ref" => package.thing.profile_ref,
          "qualification_ref" => package.profile.qualification_ref,
          "method" => "legacy_tofu",
          "review_ref" => reference
        },
        changes
      )

    Store.rereview_enrollment(
      store,
      credential,
      candidates,
      interview,
      [package.profile],
      package.thing,
      selection
    )
  end

  test "unrelated processes cannot inspect or accept even with the fresh credential", c do
    ready = prepare(c)

    for call <- [
          fn -> Store.health(c.recovery) end,
          fn -> accept(c, ready) end,
          fn ->
            Authority.transfer_acceptance_status(c.authority, ready.credential, ready.input)
          end
        ] do
      assert {:error, :recovery_operation_forbidden} = Task.async(call) |> Task.await()
    end

    assert {:ok, %{state: :approved}} =
             ReviewOwner.status(c.review_owner, ready.summary.review_token)

    assert {:ok, _} = accept(c, ready)
  end

  test "wrong receiving credential consumes checkout and preserves the exact source", c do
    ready = prepare(c)
    before = commitment(c.path)

    assert {:error, :unauthorized} =
             accept(c, %{ready | credential: :crypto.strong_rand_bytes(32)})

    assert commitment(c.path) == before
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)
    assert {:error, :recovery_review_consumed} = accept(c, ready)
  end

  @tag historical: true
  test "current guard expiry after writes rolls back schema installation and every source row",
       c do
    ready = prepare(c)
    before = commitment(c.path)
    Agent.update(c.context, &Map.put(&1, :calls, 0))
    # Checkout, first in-transaction guard, final in-transaction guard.
    :sys.replace_state(c.review_owner, fn state ->
      %{
        state
        | clock: fn ->
            Agent.get_and_update(c.context, fn context ->
              calls = context.calls + 1

              {%{confidence: :trusted, now_utc_ms: if(calls < 3, do: 2_001, else: 62_000)},
               %{context | calls: calls}}
            end)
          end
      }
    end)

    assert {:error, :recovery_review_changed_or_expired} = accept(c, ready)
    assert commitment(c.path) == before
    with_db(c.path, fn db -> assert {:ok, [[21]]} = SQL.query(db, "PRAGMA user_version") end)
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)
  end

  test "changed source schema finishes the challenge without changing quarantine", c do
    ready = prepare(c)

    with_db(c.path, fn db ->
      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER failed_acceptance BEFORE INSERT ON controller_acceptances BEGIN SELECT RAISE(ABORT,'synthetic failure'); END"
               )
    end)

    before = commitment(c.path)
    # The added trigger first invalidates the exact authenticated source schema.
    assert {:error, :transfer_review_changed} = accept(c, ready)
    assert commitment(c.path) == before
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)
  end

  @tag write_failure: true
  test "an authenticated source trigger rolls back a real SQLite write failure", c do
    ready = prepare(c)
    before = commitment(c.path)
    assert {:error, :store_unavailable} = accept(c, ready)
    assert commitment(c.path) == before
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)
    assert {:error, :recovery_review_consumed} = accept(c, ready)
  end

  test "foreground operator death closes its recovery Store and releases ownership", c do
    directory = Path.join(c.root, "operator-destination")
    {:ok, _} = Backup.stage_profile_restore(c.archive, c.key, directory)
    path = Path.join(directory, "home.sqlite")

    operator =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    store =
      start_supervised!(
        Supervisor.child_spec(
          {Store,
           path: path,
           controller_mode: :recovery,
           recovery_operator: operator,
           recovery_reviews: c.review_owner},
          id: :operator_store,
          restart: :temporary
        )
      )

    ref = Process.monitor(store)
    send(operator, :finish)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(path)
    assert :ok = WotexHome.Durable.HostLock.release(lock)
  end

  test "recovery construction requires both live distinct private process identities", c do
    for options <- [
          [],
          [recovery_operator: self()],
          [recovery_operator: self(), recovery_reviews: self()],
          [recovery_operator: "operator:caller", recovery_reviews: c.review_owner]
        ] do
      assert {:error, :invalid_store_options} =
               Store.start_link([path: c.path, controller_mode: :recovery] ++ options)
    end
  end

  @tag retained_profile: true
  test "actual inclusive retained profile bytes survive reviewed destination acceptance", c do
    root = Path.join(Path.dirname(c.path), "profiles")
    assert [name] = File.ls!(root)
    bytes = File.read!(Path.join(root, name))
    ready = prepare(c)
    assert {:ok, _} = accept(c, ready)
    assert File.read!(Path.join(root, name)) == bytes
    assert Bitwise.band(File.stat!(Path.join(root, name)).mode, 0o777) == 0o400
  end

  @tag retained_profile: true
  test "identical-byte staged profile replacement during the final guard rolls back", c do
    ready = prepare(c)
    before = commitment(c.path)
    root = Path.join(Path.dirname(c.path), "profiles")
    [name] = File.ls!(root)
    path = Path.join(root, name)
    bytes = File.read!(path)
    Agent.update(c.context, &Map.put(&1, :calls, 0))

    :sys.replace_state(c.review_owner, fn state ->
      %{
        state
        | clock: fn ->
            calls =
              Agent.get_and_update(c.context, fn context ->
                {context.calls + 1, %{context | calls: context.calls + 1}}
              end)

            if calls == 3 do
              File.rename!(path, path <> ".original")
              :ok = PrivateFile.write(path, bytes, 32_768)
              File.rm!(path <> ".original")
            end

            %{confidence: :trusted, now_utc_ms: 2_001}
          end
      }
    end)

    assert {:error, _} = accept(c, ready)
    assert commitment(c.path) == before
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)
  end

  test "accepted restart resolves the original receipt with no live clock, issuer or source archive",
       c do
    ready = prepare(c)
    assert {:ok, receipt} = accept(c, ready)
    :ok = stop_supervised(:recovery)
    :ok = stop_supervised(ReviewOwner)
    File.rm!(c.archive)

    owner =
      start_supervised!(
        {ReviewOwner,
         operator: self(),
         root: c.reviews,
         owner_file: c.owner_file,
         archive_basis: fn -> {:error, :archive_unavailable} end},
        id: :restarted_review
      )

    store =
      start_supervised!(
        {Store,
         path: c.path,
         controller_mode: :recovery,
         recovery_operator: self(),
         recovery_reviews: owner},
        id: :restarted_store
      )

    authority = Authority.new(store: store, capture: nil)

    assert {:ok, ^receipt} =
             Authority.accept_controller_transfer(
               authority,
               ready.summary.review_token,
               ready.credential,
               ready.input
             )

    assert {:ok, ^receipt} =
             Authority.transfer_acceptance_status(authority, ready.credential, ready.input)

    assert {:error, :recovery_already_accepted} =
             Authority.accept_controller_transfer(
               authority,
               ready.summary.review_token,
               ready.credential,
               %{ready.input | "operation_id" => "accept:new"}
             )

    assert {:ok, %{writable: false}} = Store.health(store)
  end

  test "the recovery Store holds the same host lock and redacts private process status", c do
    ready = prepare(c)
    assert {:error, {:store_open_failed, :already_running}} = Store.start_link(path: c.path)
    status = inspect(:sys.get_status(c.recovery), limit: :infinity)
    refute status =~ inspect(ready.credential)
    assert status =~ "private_recovery_store"
  end

  test "death of the bound review owner closes the Store and releases its lock", c do
    ref = Process.monitor(c.recovery)
    :ok = stop_supervised(ReviewOwner)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    # This foreground session does not resurrect a dead owner or its Store.
    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(c.path)
    assert :ok = WotexHome.Durable.HostLock.release(lock)
  end

  test "unmarked active source and unmarked retired source cannot start in recovery mode", c do
    for source <- [c.source] do
      copy = Path.join(c.root, "unmarked.sqlite")
      with_db(source, fn db -> assert :ok = Sqlite3.execute(db, "VACUUM INTO '#{copy}'") end)

      assert {:error, {:store_open_failed, :invalid_recovery_source}} =
               Store.start_link(
                 path: copy,
                 controller_mode: :recovery,
                 recovery_operator: self(),
                 recovery_reviews: c.review_owner
               )
    end

    active = Path.join(c.root, "active.sqlite")
    active_store = start_supervised!({Store, path: active}, id: :plain_active)
    :ok = stop_supervised(:plain_active)
    refute Process.alive?(active_store)

    assert {:error, {:store_open_failed, :invalid_recovery_source}} =
             Store.start_link(
               path: active,
               controller_mode: :recovery,
               recovery_operator: self(),
               recovery_reviews: c.review_owner
             )
  end

  @tag retained_profile: true
  test "foreground destination supervision publishes the exact original operation and receipt",
       c do
    c = destination(c)

    assert Enum.sort(Enum.map(Supervisor.which_children(c.session), &elem(&1, 0))) ==
             Enum.sort([Store, ReviewOwner])

    assert c.authority.capture == nil and c.authority.power_supervisor == nil and
             c.authority.profile_custody == nil

    ready = prepare(c)

    assert {:ok, _} =
             Destination.approve(
               c.session,
               ready.summary.review_token,
               ready.summary.review_digest,
               ready.package
             )

    assert {:ok, delivery} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert delivery.receipt_delivery == :published and delivery.dispatch_enabled == false
    assert {:ok, document} = PrivateFile.read(delivery.operation_file, 4_096)
    assert {:ok, input} = TransferAcceptanceCodec.decode("operation", document)
    assert input == ready.input
    assert {:ok, receipt_document} = PrivateFile.read(delivery.receipt_file, 4_096)
    assert {:ok, receipt} = TransferAcceptanceCodec.decode("acceptance", receipt_document)
    assert receipt == delivery.receipt
    refute inspect(delivery) =~ Base.url_encode64(ready.credential, padding: false)
    assert {:ok, ^receipt} = Destination.recover(c.session, ready.summary.review_file)

    assert {:ok, %{receipt: ^receipt}} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert {:error, :recovery_operation_file_conflict} =
             Destination.accept(c.session, ready.summary.review_file, "accept:changed")
  end

  test "destination entry points refuse unrelated callers before creating an operation file", c do
    c = destination(c)
    ready = prepare(c)

    assert {:error, :recovery_operation_forbidden} =
             Task.async(fn ->
               Destination.accept(c.session, ready.summary.review_file, "accept:interloper")
             end)
             |> Task.await()

    refute File.exists?(
             Path.join(Path.dirname(ready.summary.review_file), "acceptance-operation.json")
           )

    assert {:error, :recovery_operation_forbidden} =
             Task.async(fn ->
               Destination.prepare(c.session)
             end)
             |> Task.await()

    assert {:ok, _} = Destination.accept(c.session, ready.summary.review_file, "accept:original")
  end

  test "operation publication failure leaves the approved review and original quarantine", c do
    c = destination(c)
    ready = prepare(c)
    before = commitment(c.path)
    operation = Path.join(Path.dirname(ready.summary.review_file), "acceptance-operation.json")
    :ok = PrivateFile.write(operation, "inert conflicting fixture", 4_096)

    assert {:error, :recovery_operation_file_conflict} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert commitment(c.path) == before

    assert {:ok, %{state: :approved}} =
             Authority.controller_transfer_review_status(
               c.authority,
               ready.summary.review_token
             )
  end

  test "receipt file delivery failure preserves the committed result and original recovery", c do
    c = destination(c)
    ready = prepare(c)
    receipt_file = Path.join(Path.dirname(ready.summary.review_file), "acceptance-receipt.json")
    :ok = PrivateFile.write(receipt_file, "inert conflicting fixture", 4_096)

    assert {:ok, %{receipt: receipt, receipt_delivery: :unavailable, receipt_file: nil}} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert {:ok, ^receipt} = Destination.recover(c.session, ready.summary.review_file)
    assert {:ok, %{authority_epoch: 2, writable: false}} = Store.health(c.recovery)
  end

  test "fresh foreground reopening recovers an accepted operation without renewing its review",
       c do
    c = destination(c)
    ready = prepare(c)

    assert {:ok, %{receipt: receipt}} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    :ok = Supervisor.stop(c.session)
    Agent.update(c.context, &%{&1 | trust: %{}, clock: %{confidence: :unknown, now_utc_ms: 0}})
    File.rm!(c.archive)
    {:ok, session} = Destination.start_link(destination_options(c))
    on_exit(fn -> if Process.alive?(session), do: Supervisor.stop(session) end)
    assert {:ok, ^receipt} = Destination.recover(session, ready.summary.review_file)

    assert {:ok, %{receipt: ^receipt}} =
             Destination.accept(session, ready.summary.review_file, "accept:original")

    assert {:error, :invalid_backup} = Destination.prepare(session)
  end

  test "destination owner death leaves an unavailable session with no resurrected children", c do
    c = destination(c)
    ready = prepare(c)
    ref = Process.monitor(c.recovery)
    :ok = Supervisor.terminate_child(c.session, ReviewOwner)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert {:error, :recovery_destination_unavailable} = Destination.authority(c.session)

    assert {:error, :recovery_destination_unavailable} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(c.path)
    :ok = WotexHome.Durable.HostLock.release(lock)
  end

  @tag retained_profile: true
  test "missing staged retained bytes refuse preparation before publishing a credential", c do
    root = Path.join(Path.dirname(c.path), "profiles")
    [name] = File.ls!(root)
    File.rm!(Path.join(root, name))

    assert {:error, :destination_profile_custody_unavailable} =
             ReviewOwner.prepare(c.review_owner)

    assert File.ls!(c.reviews) == []
  end

  defp destination(c) do
    :ok = stop_supervised(:recovery)
    :ok = stop_supervised(ReviewOwner)
    {:ok, session} = Destination.start_link(destination_options(c))
    on_exit(fn -> if Process.alive?(session), do: Supervisor.stop(session) end)
    {:ok, authority} = Destination.authority(session)

    %{
      c
      | recovery: authority.store,
        review_owner: authority.recovery_reviews,
        authority: authority
    }
    |> Map.put(:session, session)
  end

  defp destination_options(c),
    do: [
      directory: Path.dirname(c.path),
      review_root: c.reviews,
      owner_file: c.owner_file,
      archive_basis: fn -> Backup.retired_transfer_basis(c.archive, c.key) end,
      issuer_policies: fn -> Agent.get(c.context, & &1.trust) end,
      clock: fn -> Agent.get(c.context, & &1.clock) end
    ]

  test "actual signed boot clock intervals guard a complete receiving Store transaction", c do
    c = destination(c)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      issuer_id: "clock:synthetic",
      public_key: public,
      generation: 1,
      procedure_ref: "procedure:synthetic-utc",
      policy_digest: String.duplicate("d", 64),
      maximum_response_ms: 10_000,
      maximum_age_ms: 60_000,
      maximum_error_ms: 5
    }

    {:ok, policy_document} = ClockCodec.policy_document(policy)
    policy_file = Path.join(c.root, "clock-policy.json")
    :ok = PrivateFile.write(policy_file, policy_document, 4_096)

    clock =
      start_supervised!(
        {ClockOwner,
         root: c.reviews, operator: self(), owner_file: c.owner_file, policy_file: policy_file}
      )

    {:ok, request} = ClockOwner.request(clock)
    {:ok, document} = PrivateFile.read(request.request_file, 4_096)
    {:ok, scope} = ClockCodec.decode_request(document)

    record =
      Map.merge(scope, %{"procedure_ref" => policy.procedure_ref, "observed_utc_ms" => 10_000})

    {:ok, payload} = ClockCodec.signing_payload(record)

    {:ok, package} =
      ClockCodec.encode(record, :crypto.sign(:eddsa, :none, payload, [private, :ed25519]))

    {:ok, _} = ClockOwner.approve(clock, request.request_digest, package)

    :sys.replace_state(c.review_owner, fn state ->
      %{state | clock: fn -> ClockOwner.current(clock) end}
    end)

    %{earliest_utc_ms: earliest, latest_utc_ms: latest} = ClockOwner.current(clock)
    ready = prepare(c, approval_delay_ms: latest - earliest + 10)

    assert {:ok, %{receipt: receipt}} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert receipt["authority_epoch"] == 2
    assert {:ok, ^receipt} = Destination.recover(c.session, ready.summary.review_file)
    assert {:ok, %{dispatch_enabled: false, writable: false}} = Store.health(c.recovery)
  end

  test "removing actual current issuer custody during the final guard rolls back the Store", c do
    c = destination(c)
    path = Path.join(c.root, "current-issuers.json")
    {:ok, document} = IssuerPolicies.encode(%{"issuer:synthetic" => c.policy})
    :ok = PrivateFile.write(path, document, 65_536)
    {:ok, provider} = IssuerPolicies.open(path)
    :sys.replace_state(c.review_owner, fn state -> %{state | trust: provider} end)
    ready = prepare(c)
    before = commitment(c.path)
    Agent.update(c.context, &Map.put(&1, :calls, 0))

    :sys.replace_state(c.review_owner, fn state ->
      %{
        state
        | clock: fn ->
            calls =
              Agent.get_and_update(c.context, fn context ->
                {context.calls + 1, %{context | calls: context.calls + 1}}
              end)

            if calls == 3, do: File.rm!(path)
            %{confidence: :trusted, now_utc_ms: 2_001}
          end
      }
    end)

    assert {:error, _} =
             Destination.accept(c.session, ready.summary.review_file, "accept:original")

    assert commitment(c.path) == before
    assert :not_found = ReviewOwner.status(c.review_owner, ready.summary.review_token)

    assert {:ok, document} =
             PrivateFile.read(
               Path.join(
                 Path.dirname(ready.summary.review_file),
                 "acceptance-operation.json"
               ),
               4_096
             )

    assert {:ok, _} = TransferAcceptanceCodec.decode("operation", document)
  end

  test "timed foreground receiver accepts only actual private signed files and closes its owners",
       c do
    c = receiver(c)
    assert {:ok, delivery} = Receiver.run(c.receiving_paths, c.key, c.receiving_io)
    assert delivery.receipt["authority_epoch"] == 2 and delivery.dispatch_enabled == false
    events = Agent.get(c.receiving_state, & &1.events)
    assert Enum.map(events, & &1.phase) == ["clock_request", "transfer_review"]
    refute inspect(events) =~ Base.url_encode64(c.key, padding: false)
    assert nil == Process.whereis(WotexHome.Recovery.Destination.Reviews)

    status_paths = [
      Path.dirname(c.path),
      c.owner_file,
      c.reviews,
      Enum.at(events, 1).summary.review_file
    ]

    assert {:ok, receipt} = Receiver.status(status_paths)
    assert receipt == delivery.receipt
    assert {:ok, ^receipt} = WotexHome.Recovery.run(["receive-status" | status_paths], "")
    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(c.path)
    :ok = WotexHome.Durable.HostLock.release(lock)
  end

  test "receiver EOF and noncanonical input leave quarantine and close every owner", c do
    c = receiver(c)
    before = commitment(c.path)

    for answer <- [:eof, "{}\n", String.duplicate(" ", 4_097)] do
      options = Keyword.put(c.receiving_io, :read_line, fn -> answer end)
      assert {:error, reason} = Receiver.run(c.receiving_paths, c.key, options)
      assert reason in [:receiving_input_eof, :invalid_receiving_input]
      assert commitment(c.path) == before
      assert nil == Process.whereis(WotexHome.Recovery.Destination.Reviews)
    end
  end

  test "receiving current custody cannot be chosen from the staged directory", c do
    c = receiver(c)
    [directory, archive, _owner, clock, issuers, root] = c.receiving_paths

    assert {:error, :invalid_receiving_request} =
             Receiver.run(
               [directory, archive, Path.join(directory, "owner.json"), clock, issuers, root],
               c.key,
               c.receiving_io
             )

    assert Agent.get(c.receiving_state, & &1.events) == []
  end

  test "receiver EOF after clock approval retains only inert review custody", c do
    c = receiver(c)
    before = commitment(c.path)

    read = fn ->
      state = Agent.get(c.receiving_state, & &1)
      if length(state.events) == 1, do: state.line, else: :eof
    end

    assert {:error, :receiving_input_eof} =
             Receiver.run(c.receiving_paths, c.key, Keyword.put(c.receiving_io, :read_line, read))

    assert commitment(c.path) == before
    assert nil == Process.whereis(WotexHome.Recovery.Destination.Reviews)
    events = Agent.get(c.receiving_state, & &1.events)
    assert Enum.map(events, & &1.phase) == ["clock_request", "transfer_review"]
    assert File.exists?(Enum.at(events, 1).summary.credential_file)
    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(c.path)
    :ok = WotexHome.Durable.HostLock.release(lock)
  end

  test "receiver enforces original input timeout and kills its blocked reader", c do
    c = receiver(c)
    [_, _, _, clock_file, _, _] = c.receiving_paths
    {:ok, document} = PrivateFile.read(clock_file, 4_096)
    {:ok, policy} = ClockCodec.decode_policy(document)
    File.rm!(clock_file)

    {:ok, document} =
      ClockCodec.policy_document(%{policy | maximum_response_ms: 200, maximum_age_ms: 2_000})

    :ok = PrivateFile.write(clock_file, document, 4_096)
    before = commitment(c.path)
    parent = self()

    read = fn ->
      send(parent, {:blocked_reader, self()})
      Process.sleep(1_000)
      :eof
    end

    assert {:error, :receiving_input_timeout} =
             Receiver.run(c.receiving_paths, c.key, Keyword.put(c.receiving_io, :read_line, read))

    assert_receive {:blocked_reader, reader}
    refute Process.alive?(reader)
    assert commitment(c.path) == before
  end

  test "receiver output failure closes context and never treats it as acceptance", c do
    c = receiver(c)
    before = commitment(c.path)

    assert {:error, :receiving_output_unavailable} =
             Receiver.run(
               c.receiving_paths,
               c.key,
               Keyword.put(c.receiving_io, :write, fn _ -> {:error, :synthetic_failure} end)
             )

    assert commitment(c.path) == before
    assert nil == Process.whereis(WotexHome.Recovery.Destination.Reviews)
  end

  test "wrong archive key and unsupported I/O options create no live clock challenge", c do
    c = receiver(c)

    assert {:error, _} =
             Receiver.run(c.receiving_paths, :crypto.strong_rand_bytes(32), c.receiving_io)

    assert File.ls!(c.reviews) == []

    assert {:error, :invalid_receiving_io} =
             Receiver.run(c.receiving_paths, c.key, clock: %{confidence: :trusted})

    assert File.ls!(c.reviews) == []
  end

  test "actual foreground CLI consumes private stdin frames and delivers its original receipt",
       c do
    c = receiver(c)
    port = recovery_port(["receive" | c.receiving_paths])
    assert Port.command(port, Base.url_encode64(c.key, padding: false) <> "\n")
    {0, lines} = receiving_port(port, c, "", [], 20_000)
    phases = Enum.filter(lines, &is_map/1)
    assert Enum.map(Enum.take(phases, 2), & &1["phase"]) == ["clock_request", "transfer_review"]
    delivery = List.last(phases)
    assert delivery["receipt"]["authority_epoch"] == 2
    assert delivery["dispatch_enabled"] == false
    refute inspect(lines) =~ Base.url_encode64(c.key, padding: false)
    assert nil == Process.whereis(WotexHome.Recovery.Destination.Reviews)
    review_file = Enum.at(phases, 1)["summary"]["review_file"]
    status_paths = [Path.dirname(c.path), c.owner_file, c.reviews, review_file]
    status = recovery_port(["receive-status" | status_paths])
    {0, [receipt]} = receiving_port(status, c, "", [], 20_000)
    assert receipt == delivery["receipt"]
    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(c.path)
    :ok = WotexHome.Durable.HostLock.release(lock)
  end

  test "actual CLI refuses an oversized metadata line and closes private clock custody", c do
    c = receiver(c)
    before = commitment(c.path)
    port = recovery_port(["receive" | c.receiving_paths])
    assert Port.command(port, Base.url_encode64(c.key, padding: false) <> "\n")
    options = Keyword.put(c.receiving_io, :read_line, fn -> String.duplicate("x", 4_097) end)
    {1, lines} = receiving_port(port, %{c | receiving_io: options}, "", [], 20_000)
    assert Enum.any?(lines, &(&1 == "recovery failed: invalid_receiving_input"))
    assert commitment(c.path) == before
    assert {:ok, lock} = WotexHome.Durable.HostLock.acquire(c.path)
    :ok = WotexHome.Durable.HostLock.release(lock)
  end

  defp recovery_port(arguments) do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args,
         ["run", "--no-start", "--no-compile", "--no-deps-check", "bin/recovery.exs" | arguments]},
        {:env, [{~c"MIX_ENV", ~c"test"}, {~c"WOTEX_HOME_GIT_DEPS", ~c"1"}]}
      ])

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    port
  end

  defp receiving_port(port, context, buffer, lines, remaining) do
    started = System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, bytes}} ->
        assert byte_size(buffer) + byte_size(bytes) <= 65_536
        pieces = String.split(buffer <> bytes, "\n")
        pending = List.last(pieces)

        complete =
          Enum.map(Enum.drop(pieces, -1), fn line ->
            case JSON.decode(line) do
              {:ok, %{"phase" => phase, "summary" => summary} = event} ->
                public =
                  case phase do
                    "clock_request" ->
                      %{
                        request_file: summary["request_file"],
                        request_digest: summary["request_digest"]
                      }

                    "transfer_review" ->
                      %{
                        review_file: summary["review_file"],
                        review_digest: summary["review_digest"],
                        minimum_approval_delay_ms: summary["minimum_approval_delay_ms"]
                      }
                  end

                assert :ok = context.receiving_io[:write].(%{phase: phase, summary: public})
                assert Port.command(port, context.receiving_io[:read_line].())
                event

              {:ok, value} ->
                value

              {:error, _} ->
                line
            end
          end)

        elapsed = System.monotonic_time(:millisecond) - started
        receiving_port(port, context, pending, lines ++ complete, max(remaining - elapsed, 0))

      {^port, {:exit_status, code}} ->
        assert buffer == ""
        {code, lines}
    after
      remaining -> flunk("foreground recovery CLI did not complete within its bounded wait")
    end
  end

  defp receiver(c) do
    :ok = stop_supervised(:recovery)
    :ok = stop_supervised(ReviewOwner)
    {clock_public, clock_private} = :crypto.generate_key(:eddsa, :ed25519)

    clock_policy = %{
      issuer_id: "clock:synthetic",
      public_key: clock_public,
      generation: 1,
      procedure_ref: "procedure:synthetic-utc",
      policy_digest: String.duplicate("d", 64),
      maximum_response_ms: 10_000,
      maximum_age_ms: 60_000,
      maximum_error_ms: 5
    }

    clock_file = Path.join(c.root, "receiver-clock-policy.json")
    {:ok, bytes} = ClockCodec.policy_document(clock_policy)
    :ok = PrivateFile.write(clock_file, bytes, 4_096)
    issuers_file = Path.join(c.root, "receiver-issuers.json")
    {:ok, bytes} = IssuerPolicies.encode(%{"issuer:synthetic" => c.policy})
    :ok = PrivateFile.write(issuers_file, bytes, 65_536)

    state =
      start_supervised!({Agent, fn -> %{events: [], line: nil, delay: 0} end}, id: :receiving_io)

    write = fn event ->
      id = System.unique_integer([:positive])

      {line, delay} =
        case event.phase do
          "clock_request" ->
            {:ok, request} = ClockCodec.decode_request(File.read!(event.summary.request_file))

            record =
              Map.merge(request, %{
                "procedure_ref" => clock_policy.procedure_ref,
                "observed_utc_ms" => 10_000
              })

            {:ok, payload} = ClockCodec.signing_payload(record)

            {:ok, package} =
              ClockCodec.encode(
                record,
                :crypto.sign(:eddsa, :none, payload, [clock_private, :ed25519])
              )

            file = Path.join(c.root, "clock-response-#{id}.json")
            :ok = PrivateFile.write(file, package, 4_096)
            {JSON.encode!(["clock-response.v1", event.summary.request_digest, file]) <> "\n", 0}

          "transfer_review" ->
            {:ok, review} = TransferReviewCodec.decode(File.read!(event.summary.review_file))
            {:ok, scope} = TransferReviewCodec.isolation_scope(review)

            decision =
              Map.merge(scope, %{
                "format" => "wotex-home.controller-isolation.v1",
                "method" => c.policy.method,
                "procedure_ref" => c.policy.procedure_ref,
                "issuer_id" => "issuer:synthetic",
                "issuer_generation" => c.policy.generation,
                "isolation_policy_digest" => c.policy.policy_digest,
                "issued_at_utc_ms" => review["issued_at_utc_ms"],
                "expires_at_utc_ms" => review["expires_at_utc_ms"]
              })

            {:ok, payload} = IsolationDecision.signing_payload(decision)

            {:ok, package} =
              IsolationDecision.encode(
                decision,
                :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
              )

            file = Path.join(c.root, "isolation-response-#{id}.json")
            :ok = PrivateFile.write(file, package, 8_192)

            {JSON.encode!([
               "transfer-approval.v1",
               event.summary.review_digest,
               file,
               "accept:receiver"
             ]) <> "\n", event.summary.minimum_approval_delay_ms + 10}
        end

      Agent.update(state, &%{&1 | line: line, delay: delay, events: &1.events ++ [event]})
      :ok
    end

    read = fn ->
      %{line: line, delay: delay} = Agent.get(state, & &1)
      if delay > 0, do: Process.sleep(delay)
      line
    end

    c
    |> Map.merge(%{
      receiving_state: state,
      receiving_io: [write: write, read_line: read],
      receiving_paths: [
        Path.dirname(c.path),
        c.archive,
        c.owner_file,
        clock_file,
        issuers_file,
        c.reviews
      ]
    })
  end

  defp prepare(c, options \\ []) do
    assert {:ok, summary} = ReviewOwner.prepare(c.review_owner)
    if delay = options[:approval_delay_ms], do: Process.sleep(delay)
    assert {:ok, review_document} = PrivateFile.read(summary.review_file, 4_096)
    assert {:ok, review} = TransferReviewCodec.decode(review_document)
    assert {:ok, scope} = TransferReviewCodec.isolation_scope(review)
    # Disposable software key and trusted fixture time; no physical isolation evidence.
    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => c.policy.method,
        "procedure_ref" => c.policy.procedure_ref,
        "issuer_id" => "issuer:synthetic",
        "issuer_generation" => 1,
        "isolation_policy_digest" => c.policy.policy_digest,
        "issued_at_utc_ms" => review["issued_at_utc_ms"],
        "expires_at_utc_ms" => review["expires_at_utc_ms"]
      })

    assert {:ok, payload} = IsolationDecision.signing_payload(decision)

    assert {:ok, package} =
             IsolationDecision.encode(
               decision,
               :crypto.sign(:eddsa, :none, payload, [c.private, :ed25519])
             )

    assert {:ok, _} =
             ReviewOwner.approve(
               c.review_owner,
               summary.review_token,
               summary.review_digest,
               package
             )

    assert {:ok, credential} = PrivateFile.read_credential(summary.credential_file)

    input =
      Map.take(review, ~w(principal_id source_epoch retirement_revision destination_owner_id))
      |> Map.merge(%{
        "operation_id" => "accept:original",
        "review_digest" => summary.review_digest,
        "isolation_package_digest" => Artifact.digest(package)
      })

    %{summary: summary, credential: credential, input: input, package: package}
  end

  defp accept(c, ready),
    do:
      Authority.accept_controller_transfer(
        c.authority,
        ready.summary.review_token,
        ready.credential,
        ready.input
      )

  defp commitment(path),
    do:
      with_db(path, fn db ->
        assert {:ok, commitment} = RecoverySnapshot.commitment(db, :quarantine)
        commitment
      end)

  defp with_db(path, function) do
    {:ok, db} = Sqlite3.open(path)

    try do
      :ok = Sqlite3.execute(db, "PRAGMA foreign_keys=ON")
      function.(db)
    after
      Sqlite3.close(db)
    end
  end
end
