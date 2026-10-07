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
    IsolationDecision,
    Owner,
    PrivateFile,
    ReviewOwner,
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

    {:ok, barrier} = Store.begin_maintenance(store, maintainer, 1, "maintenance:source", 4)

    {:ok, retired} =
      Store.retire_controller(store, transfer, %{
        "authority_epoch" => 1,
        "operation_id" => "retire:source",
        "expected_revision" => barrier.revision,
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
    with_db(c.path, fn db -> assert {:ok, [[22]]} = SQL.query(db, "PRAGMA user_version") end)
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

  defp prepare(c) do
    assert {:ok, summary} = ReviewOwner.prepare(c.review_owner)
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
        "issued_at_utc_ms" => 2_000,
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

    %{summary: summary, credential: credential, input: input}
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
