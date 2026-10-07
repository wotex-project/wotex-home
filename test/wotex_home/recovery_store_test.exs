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
    Owner,
    PrivateFile,
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
