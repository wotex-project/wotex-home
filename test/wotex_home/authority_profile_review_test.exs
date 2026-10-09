Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))

defmodule WotexHome.AuthorityProfileReviewTest do
  use ExUnit.Case

  alias WotexHome.Authority
  alias WotexHome.LocalAPI.{Client, Frame, Server}
  import ExUnit.CaptureIO
  alias WotexHome.Mutation
  alias WotexHome.Discovery.{Candidate, Interview}
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Semantics.Observation
  alias WotexHome.Lifx.{CaptureSession, IPv4Scope, ProfileCatalogue, Transport}
  alias WotexHome.Profiles.{Artifact, Custody, ReviewSession}

  defmodule Peer do
    @behaviour Transport
    @impl true
    def send(peer, _, request) do
      <<_::binary-size(4), source::little-32, target::binary-size(6), _::binary-size(9),
        sequence::8, _::64, type::little-16, _::16, _::binary>> = request

      peer = if is_map(peer), do: peer, else: %{}
      serial = Map.get(peer, :serial, <<0xD0, 0x73, 0xD5, 0, 0, 1>>)
      product = Map.get(peer, :product, 22)
      {major, minor} = Map.get(peer, :firmware, {1, 22})

      {reply_type, payload} =
        case type do
          2 -> {3, <<1, 56_700::little-32>>}
          32 -> {33, <<1::little-32, product::little-32, 0::32>>}
          14 -> {15, <<1_700_000_000::little-64, 0::64, minor::little-16, major::little-16>>}
        end

      target = if type == 2, do: serial, else: target
      size = 36 + byte_size(payload)

      reply =
        <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48,
          0::8, sequence::8, 0::64, reply_type::little-16, 0::16, payload::binary>>

      Process.put(:profile_review_peer, Process.get(:profile_review_peer, []) ++ [reply])
      :ok
    end

    @impl true
    def recv(_, _) do
      case Process.get(:profile_review_peer, []) do
        [reply | rest] ->
          Process.put(:profile_review_peer, rest)
          {:ok, "192.0.2.10:56700", reply}

        [] ->
          {:error, :timeout}
      end
    end
  end

  setup do
    temporary = System.tmp_dir!()

    temporary =
      if String.starts_with?(temporary, "/var/"), do: "/private" <> temporary, else: temporary

    directory =
      Path.join(temporary, "woh-profile-review-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    root = Path.join(directory, "profiles")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    custody = start_supervised!({Custody, root: root})

    reviews = start_supervised!({ReviewSession, custody: custody})
    path = Path.join(directory, "home.sqlite")
    {case_public, case_private} = :crypto.generate_key(:eddsa, :ed25519)
    {decision_public, decision_private} = :crypto.generate_key(:eddsa, :ed25519)

    keys = [
      qualification_case_keys: %{"reviewer:cases" => case_public},
      qualification_decision_keys: %{"reviewer:physical" => decision_public}
    ]

    store =
      start_supervised!(
        {Store, [path: path, profile_custody: custody, profile_reviews: reviews] ++ keys}
      )

    {:ok, operator, _} =
      Store.provision_principal(store, "operator:review", ["profile:manage", "enroll:review"], [])

    {:ok, manager, _} = Store.provision_principal(store, "manager:review", ["profile:manage"], [])

    {:ok, maintainer, _} =
      Store.provision_principal(store, "maintainer:review", ["host:maintain"], [])

    {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:fixture")

    {:ok, candidate} =
      Candidate.new(%{
        "interface_id" => "en0",
        "transport" => "udp",
        "source_endpoint" => "192.0.2.10:56700",
        "receive_epoch" => "scan:initial",
        "received_monotonic_ms" => 10,
        "raw_ref" => "capture:initial",
        "claimed_identifiers" => %{"stable_id" => "lifx:d073d5000001"},
        "trust_class" => "untrusted_network"
      })

    {:ok, interview} =
      Interview.new(
        %{
          "candidate_ref" => candidate.raw_ref,
          "transport" => "udp",
          "manufacturer" => "lifx.vendor.1",
          "model" => "lifx.product.22",
          "firmware" => "1.22",
          "stable_id" => "lifx:d073d5000001"
        },
        candidate
      )

    selection = %{
      "operator_id" => "operator:review",
      "candidate_ref" => candidate.raw_ref,
      "stable_id" => interview.stable_id,
      "profile_ref" => package.thing.profile_ref,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:initial"
    }

    {:ok, binding_revision} =
      Store.commit_enrollment(
        store,
        operator,
        [candidate],
        interview,
        [package.profile],
        package.thing,
        selection
      )

    {:ok, scope} = IPv4Scope.new({192, 0, 2, 2}, 24)

    capture =
      start_supervised!(
        {CaptureSession, interface_id: "en0", scope: scope, transport: {Peer, :fixture}}
      )

    authority =
      Authority.new(
        store: store,
        profile_custody: custody,
        profile_reviews: reviews,
        capture: capture
      )

    {:ok, digest} =
      Authority.stage_profile(
        authority,
        operator,
        File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__))
      )

    {:ok, revision} = Store.revision(store)

    {:ok, _} =
      Authority.begin_maintenance(authority, maintainer, 1, "maintenance:review", revision)

    {:ok, revision} = Store.revision(store)

    {:ok, receipt} =
      Authority.profile_change(authority, operator, %{
        "action" => "approve",
        "authority_epoch" => 1,
        "operation_id" => "approval:review",
        "expected_revision" => revision,
        "artifact_digest" => digest,
        "expected_trust_revision" => 0
      })

    %{
      store: store,
      custody: custody,
      reviews: reviews,
      path: path,
      keys: keys,
      case_private: case_private,
      decision_private: decision_private,
      directory: directory,
      authority: authority,
      operator: operator,
      manager: manager,
      maintainer: maintainer,
      digest: digest,
      receipt: receipt,
      binding_revision: binding_revision,
      root: root,
      compiled_review: %{
        candidates: [candidate],
        interview: interview,
        thing: package.thing,
        artifact: %{profile: package.profile},
        enrollment:
          elem(
            WotexHome.Discovery.EnrollmentReview.new(
              [candidate],
              interview,
              [package.profile],
              package.thing,
              selection
            ),
            1
          )
      },
      capture: capture
    }
  end

  test "fresh host evidence produces a bounded proposal without changing durable state", c do
    {input, session} = captured_input(c)
    {:ok, before_revision} = Store.revision(c.store)
    assert {:ok, review} = Authority.review_profile_selection(c.authority, c.operator, input)
    assert review.summary.current_profile_ref == "lifx.product-22:1.0.0"
    assert review.summary.proposed_profile_ref == "test.portable-light:1.0.0"
    assert review.basis["binding_revision"] == c.binding_revision
    assert review.basis["trust_revision"] == c.receipt.final_revision
    assert {:ok, ^before_revision} = Store.revision(c.store)

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(c.capture, "operator:review", session)

    assert {:error, :profile_review_missing} =
             Authority.profile_change(c.authority, c.operator, input)
  end

  test "original native access receipts survive revoke without replaying a grant", c do
    {secret, grant} = native_access_basis(c)

    status =
      Map.take(
        grant,
        ~w(deployment_id owner_id authority_epoch creation_revision verifier operation_id)
      )

    assert :not_found = Authority.native_target_status(c.authority, status)
    assert {:ok, %{items: []}} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert {:ok, receipt} = Authority.native_target_change(c.authority, "grant", grant)
    assert receipt["change_revision"] == grant["expected_revision"] + 1
    assert receipt["final_revision"] == receipt["change_revision"]
    assert {:ok, ^receipt} = Authority.native_target_status(c.authority, status)
    assert {:ok, ^receipt} = Authority.native_target_change(c.authority, "grant", grant)
    assert {:ok, %{items: [_]}} = Store.catalogue_page(c.store, secret, nil, nil, 10)

    assert {:error, :native_operation_conflict} =
             Authority.native_target_change(
               c.authority,
               "grant",
               Map.put(grant, "resource_revision", 99)
             )

    assert {:error, :native_target_exists} =
             Authority.native_target_change(
               c.authority,
               "grant",
               grant
               |> Map.put("operation_id", "access:duplicate")
               |> Map.put("expected_revision", receipt["final_revision"])
             )

    revoke = native_revoke(grant, receipt["final_revision"])
    assert {:ok, removed} = Authority.native_target_change(c.authority, "revoke", revoke)
    assert removed["change_revision"] == receipt["final_revision"] + 1
    assert {:ok, ^removed} = Authority.native_target_change(c.authority, "revoke", revoke)
    assert {:ok, ^receipt} = Authority.native_target_change(c.authority, "grant", grant)
    assert {:ok, %{items: []}} = Store.catalogue_page(c.store, secret, nil, nil, 10)

    assert {:ok, %{qualification_head: nil}} =
             Authority.profile_target(c.authority, secret, grant["target_id"])

    assert {:ok, %{dispatch_enabled: false, writable: true}} = Store.health(c.store)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "private native parent frames retain exact target receipts and bounded policy replies",
       c do
    alias WotexHome.NativeSetup.{Bridge, Codec, TargetCodec}
    {_secret, grant} = native_access_basis(c)

    status =
      Map.take(
        grant,
        ~w(deployment_id owner_id authority_epoch creation_revision verifier operation_id)
      )

    wrong = Map.put(grant, "verifier", String.duplicate("d", 64))

    bodies = [
      TargetCodec.encode("status", status),
      TargetCodec.encode("grant", wrong),
      TargetCodec.encode("grant", grant),
      TargetCodec.encode("grant", grant),
      TargetCodec.encode("status", status),
      Codec.encode("identity_request", %{})
    ]

    input = Enum.map_join(bodies, fn {:ok, body} -> <<byte_size(body)::32, body::binary>> end)
    {:ok, device} = StringIO.open(input, encoding: :latin1)
    assert :ok = Bridge.run(c.authority, device)
    {_, output} = StringIO.contents(device)
    StringIO.close(device)
    [missing, denied, first, duplicate, found, identity] = native_frame_bodies(output)
    assert {:ok, ^status} = TargetCodec.decode("not_found", missing)
    assert {:ok, %{"reason" => "native_custody_conflict"}} = TargetCodec.decode("error", denied)
    assert first == duplicate and first == found
    assert {:ok, receipt} = TargetCodec.decode("receipt", first)
    assert receipt["change_revision"] == grant["expected_revision"] + 1
    assert {:ok, scope} = Codec.decode("identity", identity)
    assert scope["store_revision"] == receipt["final_revision"]
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(c.store)
  end

  test "native channel guard failure before SQLite commit rolls back access and history", c do
    {_secret, grant} = native_access_basis(c)
    parent = self()
    key = make_ref()

    guard = fn ->
      count = Process.get(key, 0) + 1
      Process.put(key, count)
      send(parent, {:native_commit_guard, count})
      if count < 3, do: :ok, else: {:error, :expired}
    end

    assert {:error, :outcome_unknown} =
             Authority.native_target_change(c.authority, "grant", grant, guard)

    for count <- 1..3, do: assert_receive({:native_commit_guard, ^count})
    assert {:ok, revision} = Store.revision(c.store)
    assert revision == grant["expected_revision"]
    assert {:ok, []} = query(c, "SELECT * FROM native_target_operations")

    assert {:ok, []} =
             query(
               c,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    assert {:ok, %{writable: true}} = Store.health(c.store)
    assert {:ok, _} = Authority.native_target_change(c.authority, "grant", grant)
  end

  test "a timed-out native parent worker cannot grant later from the Store queue", c do
    alias WotexHome.NativeSetup.{Bridge, TargetCodec}
    {_secret, grant} = native_access_basis(c)
    {:ok, body} = TargetCodec.encode("grant", grant)
    {:ok, device} = StringIO.open(<<byte_size(body)::32, body::binary>>, encoding: :latin1)
    :sys.suspend(c.store)

    try do
      task = Task.async(fn -> Bridge.run(c.authority, device) end)
      assert {:error, :outcome_unknown} = Task.await(task, 7_000)
      assert {_, ""} = StringIO.contents(device)
    after
      :sys.resume(c.store)
      StringIO.close(device)
    end

    assert {:ok, revision} = Store.revision(c.store)
    assert revision == grant["expected_revision"]
    assert {:ok, []} = query(c, "SELECT * FROM native_target_operations")

    assert {:ok, []} =
             query(
               c,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    assert {:ok, %{writable: true}} = Store.health(c.store)
    assert {:ok, _} = Authority.native_target_change(c.authority, "grant", grant)
  end

  test "native target changes refuse changed original custody and stale reviewed pins", c do
    {_secret, grant} = native_access_basis(c)
    revision = grant["expected_revision"]

    for field <- ~w(resource_revision binding_revision selection_generation) do
      assert {:error, :native_target_changed} =
               Authority.native_target_change(
                 c.authority,
                 "grant",
                 Map.update!(grant, field, &(&1 + 1))
               )
    end

    assert {:error, :native_target_changed} =
             Authority.native_target_change(
               c.authority,
               "grant",
               Map.put(grant, "artifact_digest", String.duplicate("a", 64))
             )

    assert {:error, :revision_conflict} =
             Authority.native_target_change(
               c.authority,
               "grant",
               Map.put(grant, "expected_revision", revision + 1)
             )

    assert {:error, :native_custody_conflict} =
             Authority.native_target_change(
               c.authority,
               "grant",
               Map.put(grant, "verifier", String.duplicate("b", 64))
             )

    assert {:error, :native_owner_changed} =
             Authority.native_target_change(
               c.authority,
               "grant",
               Map.put(grant, "owner_id", String.duplicate("c", 64))
             )

    assert {:error, :invalid_native_target_record} =
             Authority.native_target_change(
               c.authority,
               "grant",
               Map.put(grant, "role", "maintenance")
             )

    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, []} = query(c, "SELECT * FROM native_target_operations")

    assert {:ok, []} =
             query(
               c,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  test "native revoke invalidates actual held requests at its immutable final revision", c do
    {secret, grant} = native_access_basis(c)
    assert {:ok, _} = Authority.native_target_change(c.authority, "grant", grant)

    for id <- ~w(request:native:first request:native:second) do
      assert {:ok, mutation} =
               Mutation.new(%{
                 "api_version" => 1,
                 "authority_epoch" => 1,
                 "operation_id" => id,
                 "expected_revision" => 1,
                 "target_id" => grant["target_id"],
                 "capability_key" => "power",
                 "value" => %{"type" => "boolean", "value" => true}
               })

      assert {:ok, %{disposition: :held}} = Store.submit_request(c.store, secret, mutation)
    end

    {:ok, revision} = Store.revision(c.store)
    revoke = native_revoke(grant, revision)
    assert {:ok, receipt} = Authority.native_target_change(c.authority, "revoke", revoke)
    assert receipt["change_revision"] == revision + 1
    assert receipt["final_revision"] == revision + 3
    assert receipt["affected_requests"] == 2 and receipt["unknown_outcomes"] == 0

    assert {:ok, [["rejected", "native_target_revoked"], ["rejected", "native_target_revoked"]]} =
             query(
               c,
               "SELECT disposition,reason FROM request_journal WHERE revision>#{receipt["change_revision"]} ORDER BY revision"
             )

    assert {:ok, ^receipt} = Authority.native_target_change(c.authority, "revoke", revoke)
    assert {:ok, final} = Store.revision(c.store)
    assert final == receipt["final_revision"]
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  for phase <- ~w(queued claimed dispatching protocol_accepted) do
    @tag native_execution_phase: phase
    test "native revoke preserves causal spend at the #{phase} boundary", c do
      phase = c.native_execution_phase
      {secret, grant} = native_access_basis(c)
      assert {:ok, _} = Authority.native_target_change(c.authority, "grant", grant)
      execution_fixture(c, secret, grant, phase)
      {:ok, revision} = Store.revision(c.store)
      revoke = native_revoke(grant, revision)
      assert {:ok, receipt} = Authority.native_target_change(c.authority, "revoke", revoke)
      unknown = phase in ~w(dispatching protocol_accepted)
      assert receipt["affected_requests"] == 1
      assert receipt["unknown_outcomes"] == if(unknown, do: 1, else: 0)
      assert receipt["final_revision"] == revision + 2
      assert {:ok, [[1]]} = query(c, "SELECT reserved_effects FROM request_causal_roots")

      if unknown do
        assert {:ok, [["outcome_unknown"]]} = query(c, "SELECT state FROM request_execution")

        assert {:ok, [["outcome_unknown", "native_target_revoked_after_handoff"]]} =
                 query(c, "SELECT disposition,reason FROM request_receipts")
      else
        assert {:ok, []} = query(c, "SELECT state FROM request_execution")

        assert {:ok, [["rejected", "native_target_revoked"]]} =
                 query(c, "SELECT disposition,reason FROM request_receipts")
      end

      assert {:ok, ^receipt} = Authority.native_target_change(c.authority, "revoke", revoke)
      assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
    end
  end

  test "generic target revocation cannot be undone by original native grant retry", c do
    {secret, grant} = native_access_basis(c)
    assert {:ok, receipt} = Authority.native_target_change(c.authority, "grant", grant)

    assert {:ok, revision} =
             Store.revoke_target_grant(c.store, receipt["principal_id"], grant["target_id"])

    assert {:ok, ^receipt} = Authority.native_target_change(c.authority, "grant", grant)
    assert {:ok, %{items: []}} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert {:ok, ^revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.native_target_change(
               c.authority,
               "grant",
               grant
               |> Map.put("operation_id", "access:reviewed:again")
               |> Map.put("expected_revision", revision)
             )

    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "revoking and reapproving profile trust cannot revive native access", c do
    {secret, grant} = native_access_basis(c)
    assert {:ok, receipt} = Authority.native_target_change(c.authority, "grant", grant)
    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.begin_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maint:native:trust",
               revision
             )

    {:ok, revision} = Store.revision(c.store)

    revoke = %{
      "action" => "revoke",
      "authority_epoch" => 1,
      "operation_id" => "artifact:native:revoke",
      "expected_revision" => revision,
      "artifact_digest" => c.digest,
      "expected_trust_revision" => c.receipt.final_revision
    }

    assert {:ok, revoked} = Authority.profile_change(c.authority, c.operator, revoke)

    assert {:ok, []} =
             query(
               c,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    approve =
      Map.merge(revoke, %{
        "action" => "approve",
        "operation_id" => "artifact:native:reapprove",
        "expected_revision" => revoked.final_revision,
        "expected_trust_revision" => revoked.final_revision
      })

    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, approve)
    assert {:ok, ^receipt} = Authority.native_target_change(c.authority, "grant", grant)
    end_maintenance(c)
    assert {:ok, %{items: []}} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "damaged native access history refuses lookup and restart instead of repairing grants",
       c do
    {_secret, grant} = native_access_basis(c)
    assert {:ok, _} = Authority.native_target_change(c.authority, "grant", grant)

    assert :ok =
             Sqlite3.execute(
               :sys.get_state(c.store).db,
               "UPDATE native_target_operations SET operation_id='access:substituted'"
             )

    status =
      Map.take(
        grant,
        ~w(deployment_id owner_id authority_epoch creation_revision verifier operation_id)
      )

    assert {:error, :corrupt_native_setup} = Authority.native_target_status(c.authority, status)
    assert {:ok, %{writable: false, dispatch_enabled: false}} = Store.health(c.store)

    assert {:ok, [["light:fixture"]]} =
             query(
               c,
               "SELECT thing_id FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    stop_supervised!(Store)
    Process.flag(:trap_exit, true)
    assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
  end

  test "profile reselection withdraws native access and requires a fresh review", c do
    {secret, grant} = native_access_basis(c)
    assert {:ok, original} = Authority.native_target_change(c.authority, "grant", grant)
    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.begin_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maint:native:reselect",
               revision
             )

    {selection, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, selection)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, selection)

    assert {:ok, []} =
             query(
               c,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    assert {:ok, ^original} = Authority.native_target_change(c.authority, "grant", grant)
    end_maintenance(c)
    assert {:ok, %{items: []}} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert {:ok, snapshot} = Authority.profile_target(c.authority, secret, grant["target_id"])

    fresh =
      Map.merge(grant, %{
        "operation_id" => "access:replacement",
        "expected_revision" => snapshot.store_revision,
        "resource_revision" => snapshot.resource_revision,
        "binding_revision" => snapshot.binding_revision,
        "selection_generation" => snapshot.selection_generation,
        "artifact_digest" => snapshot.artifact_digest
      })

    assert {:ok, replacement} = Authority.native_target_change(c.authority, "grant", fresh)
    assert replacement["change_revision"] > original["change_revision"]
    assert {:ok, %{items: [_]}} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "a native access ledger failure rolls back the actual grant and all revisions", c do
    {_secret, grant} = native_access_basis(c)
    db = :sys.get_state(c.store).db

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TRIGGER fail_native_access BEFORE INSERT ON native_target_operations BEGIN SELECT RAISE(ABORT,'fixture'); END"
             )

    assert {:error, :store_unavailable} =
             Authority.native_target_change(c.authority, "grant", grant)

    assert {:ok, [[revision]]} = SQL.query(db, "SELECT value FROM meta WHERE key='revision'")
    assert revision == grant["expected_revision"]
    assert {:ok, []} = SQL.query(db, "SELECT * FROM native_target_operations")

    assert {:ok, []} =
             SQL.query(
               db,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    assert {:ok, []} =
             SQL.query(
               db,
               "SELECT * FROM authority_journal WHERE event_type='native_target_granted'"
             )

    assert :ok = Sqlite3.execute(db, "DROP TRIGGER fail_native_access")
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store, path: c.path, profile_custody: c.custody, profile_reviews: c.reviews}
      )

    assert {:ok, _} = Store.native_target_change(store, "grant", grant)
    assert :ok = Integrity.validate_snapshot(:sys.get_state(store).db)
  end

  test "revoked native principals retain access history without reviving grants", c do
    {secret, grant} = native_access_basis(c)
    assert {:ok, _} = Authority.native_target_change(c.authority, "grant", grant)
    assert {:ok, _} = Store.revoke_principal(c.store, "native-setup-v1:1:operator")

    assert {:ok, []} =
             query(
               c,
               "SELECT * FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*'"
             )

    assert {:error, :native_custody_conflict} =
             Authority.native_target_change(c.authority, "grant", grant)

    assert {:error, :unauthorized} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert {:ok, [[1]]} = query(c, "SELECT COUNT(*) FROM native_target_operations")
    assert :ok = Integrity.validate_snapshot(:sys.get_state(c.store).db)
  end

  test "native access survives restart and archive while absent bytes permit revoke", c do
    {secret, grant} = native_access_basis(c)
    assert {:ok, receipt} = Authority.native_target_change(c.authority, "grant", grant)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "native-access.backup")
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:ok, _} = WotexHome.Durable.Backup.verify(archive, key)
    File.rm!(Path.join(c.root, c.digest <> ".json"))
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store, path: c.path, profile_custody: c.custody, profile_reviews: c.reviews}
      )

    assert {:ok, ^receipt} = Store.native_target_change(store, "grant", grant)

    assert {:ok, [["light:fixture"]]} =
             SQL.query(
               :sys.get_state(store).db,
               "SELECT thing_id FROM principal_targets WHERE principal_id='native-setup-v1:1:operator'"
             )

    assert {:ok, %{current_use: :profile_artifact_unavailable}} =
             Store.profile_target(store, secret, grant["target_id"])

    assert {:ok, revision} = Store.revision(store)
    assert {:ok, _} = Store.native_target_change(store, "revoke", native_revoke(grant, revision))
    assert :ok = Integrity.validate_snapshot(:sys.get_state(store).db)
  end

  test "native target basis joins actual reviewed power selection without granting or qualifying",
       c do
    alias WotexHome.NativeSetup.{TargetBasis, TargetCodec}
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, scope} = Authority.native_setup_identity(c.authority)

    original =
      scope
      |> Map.drop(["store_revision"])
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      })

    assert {:ok, receipt} = Authority.ensure_native_principal(c.authority, original)
    {selection, _session} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, selection)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, selection)
    assert {:ok, snapshot} = Authority.profile_target(c.authority, secret, "light:fixture")

    input =
      original
      |> Map.delete("role")
      |> Map.merge(%{
        "creation_revision" => receipt["revision"],
        "operation_id" => "access:basis",
        "expected_revision" => snapshot.store_revision,
        "target_id" => snapshot.target_id,
        "resource_revision" => snapshot.resource_revision,
        "binding_revision" => snapshot.binding_revision,
        "selection_generation" => snapshot.selection_generation,
        "artifact_digest" => snapshot.artifact_digest
      })

    assert {:ok, _} = TargetCodec.encode("grant", input)
    assert :ok = TargetBasis.validate(input, snapshot)
    assert snapshot.qualification_head == nil

    for field <-
          ~w(authority_epoch expected_revision resource_revision binding_revision selection_generation) do
      assert {:error, :native_target_changed} =
               TargetBasis.validate(Map.update!(input, field, &(&1 + 1)), snapshot)
    end

    assert {:error, :native_target_changed} =
             TargetBasis.validate(%{input | "target_id" => "light:other"}, snapshot)

    assert {:error, :native_target_changed} =
             TargetBasis.validate(
               %{input | "artifact_digest" => String.duplicate("e", 64)},
               snapshot
             )

    for {field, value} <- [
          {:status, "revoked"},
          {:selection_state, "revoked"},
          {:identity_status, :review_required},
          {:current_use, :profile_artifact_unavailable}
        ] do
      assert {:error, :native_target_unavailable} =
               TargetBasis.validate(input, Map.put(snapshot, field, value))
    end

    [power] = snapshot.declaration["capabilities"]

    brightness =
      Map.merge(power, %{"key" => "brightness", "value_kind" => "fraction", "unit" => "ppm"})

    expanded = Map.put(snapshot.declaration, "capabilities", [power, brightness])
    assert {:ok, _} = WotexHome.Semantics.Thing.new(expanded)

    assert {:error, :native_target_unavailable} =
             TargetBasis.validate(input, %{snapshot | declaration: expanded})

    assert {:ok, %{items: []}} = Store.catalogue_page(c.store, secret, nil, nil, 10)
    assert {:ok, %{store_revision: revision, dispatch_enabled: false}} = Store.health(c.store)
    assert revision == snapshot.store_revision
  end

  test "pending preparation retry returns its original token without consuming another capture",
       c do
    reviews = c.reviews
    authority = %{c.authority | profile_reviews: reviews}
    {input, session} = captured_input(c)
    {:ok, revision} = Store.revision(c.store)
    assert {:ok, held} = Authority.prepare_profile_selection(authority, c.operator, input)
    assert {:ok, again} = Authority.prepare_profile_selection(authority, c.operator, input)
    assert held.review_token == again.review_token
    assert again.remaining_ms <= held.remaining_ms

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(c.capture, "operator:review", session)

    assert {:ok, ^revision} = Store.revision(c.store)
    assert :ok = ReviewSession.cancel(reviews, "operator:review", held.review_token)

    assert {:error, :profile_review_consumed} =
             Authority.prepare_profile_selection(authority, c.operator, input)
  end

  test "management alone cannot consume enrollment evidence", c do
    {input, session} = captured_input(c)

    assert {:error, :permission_denied} =
             Authority.review_profile_selection(c.authority, c.manager, input)

    assert {:ok, _} = CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "a changed global basis is rejected before capture consumption", c do
    {input, session} = captured_input(c)
    assert {:ok, _, _} = Store.provision_principal(c.store, "reader:later", ["read"], [])

    assert {:error, :resnapshot_required} =
             Authority.review_profile_selection(c.authority, c.operator, input)

    assert {:ok, _} = CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "all selection CAS fields fail closed on the actual Store boundary", c do
    input = input(c, "session:fixture", "capture:fixture")

    for {key, expected} <- [
          {"authority_epoch", :stale_authority_epoch},
          {"expected_trust_revision", :profile_trust_changed},
          {"expected_policy_generation", :profile_policy_changed},
          {"expected_resource_revision", :stale_resource_revision},
          {"expected_binding_revision", :stale_binding_revision},
          {"expected_selection_generation", :profile_selection_changed},
          {"expected_rule_generation", :stale_rule_generation}
        ] do
      assert {:error, ^expected} =
               Store.profile_selection_basis(
                 c.store,
                 c.operator,
                 Map.update!(input, key, &(&1 + 1))
               )
    end
  end

  test "missing approved bytes do not consume the one-use capture", c do
    {input, session} = captured_input(c)
    File.rm!(Path.join(c.root, c.digest <> ".json"))

    assert {:error, :profile_artifact_unavailable} =
             Authority.review_profile_selection(c.authority, c.operator, input)

    assert {:ok, _} = CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "maintenance end leaves the catalogue inert and denies selection review", c do
    input = input(c, "session:fixture", "capture:fixture")

    {:ok, %{begin_revision: begin_revision}} =
      Authority.maintenance_status(c.authority, c.maintainer)

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.end_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maintenance:end:review",
               revision,
               begin_revision
             )

    input = input(c, input["session_ref"], input["candidate_ref"])

    assert {:error, :maintenance_required} =
             Store.profile_selection_basis(c.store, c.operator, input)
  end

  test "Store commits the held selection and original retry without files or transient custody",
       c do
    {input, _session} = captured_input(c)
    assert {:ok, held} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert {:ok, receipt} = Authority.profile_change(c.authority, c.operator, input)
    assert receipt.changed_targets == 1
    assert receipt.invalidated_requests == 0
    assert receipt.unknown_outcomes == 0
    assert receipt.final_revision == input["expected_revision"] + 3
    assert :not_found = ReviewSession.status(c.reviews, "operator:review", held.review_token)

    assert {:ok, [["test.portable-light:1.0.0", 1]]} =
             query(c, "SELECT profile_ref,resource_revision FROM enrolled_things")

    assert {:ok, [[1, "selected"]]} = query(c, "SELECT generation,state FROM profile_current")
    assert {:ok, []} = query(c, "SELECT * FROM profile_qualifications")
    assert {:ok, %{writable: true}} = Store.health(c.store)

    File.rm!(Path.join(c.root, c.digest <> ".json"))
    stop_supervised!(ReviewSession)
    assert {:ok, ^receipt} = Authority.profile_change(c.authority, c.operator, input)

    assert {:error, :profile_operation_conflict} =
             Authority.profile_change(
               c.authority,
               c.operator,
               Map.put(input, "review_ref", "review:altered")
             )

    assert {:ok, ^receipt} =
             Authority.profile_operation_status(c.authority, c.operator, 1, input["operation_id"])

    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, %{writable: true}} = Store.health(store)
    assert {:ok, ^receipt} = Store.profile_change(store, c.operator, input)
  end

  test "selected observations retain their pin and revocation remains possible with missing bytes",
       c do
    {input, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)
    {report, capability} = selected_report(c)
    assert {:ok, observed} = Store.record(c.store, report, capability)

    assert {:ok, reader, _} =
             Store.provision_principal(c.store, "reader:profile-inspection", ["read"], [
               input["target_id"]
             ])

    assert {:ok, %{capabilities: [%{freshness: "fresh", profile_status: "usable"}]}} =
             Authority.current_thing(c.authority, reader, input["target_id"])

    assert {:ok, [[^observed, 1, 1]]} =
             query(
               c,
               "SELECT owner_revision,selection_generation,resource_revision FROM profile_observation_pins"
             )

    File.rm!(Path.join(c.root, c.digest <> ".json"))

    assert {:ok,
            %{
              capabilities: [
                %{
                  freshness: "profile_unavailable",
                  profile_status: "profile_artifact_unavailable",
                  current_value: nil,
                  report: %{"revision" => ^observed}
                }
              ]
            }} = Authority.current_thing(c.authority, reader, input["target_id"])

    assert {:error, :profile_artifact_unavailable} =
             Store.record(c.store, %{report | source_sequence: 2}, capability)

    assert {:ok, %{writable: true}} = Store.health(c.store)
    {:ok, revision} = Store.revision(c.store)

    revoke = %{
      "action" => "revoke_selection",
      "authority_epoch" => 1,
      "operation_id" => "selection:revoke",
      "expected_revision" => revision,
      "artifact_digest" => c.digest,
      "expected_trust_revision" => c.receipt.final_revision,
      "target_id" => input["target_id"],
      "expected_resource_revision" => 1,
      "expected_selection_generation" => 1
    }

    assert {:ok, receipt} = Authority.profile_change(c.authority, c.operator, revoke)
    assert receipt.changed_targets == 1

    assert {:ok,
            %{
              selection_state: "revoked",
              selection_generation: 2,
              current_use: :profile_selection_revoked,
              artifact_digest: digest
            }} = Authority.profile_target(c.authority, c.manager, input["target_id"])

    assert digest == c.digest
    assert {:ok, [[2, "revoked"]]} = query(c, "SELECT generation,state FROM profile_current")
    assert :not_found = Store.current(c.store, input["target_id"], "power")

    assert {:ok,
            %{
              capabilities: [
                %{
                  freshness: "profile_unavailable",
                  profile_status: "profile_selection_revoked",
                  current_value: nil,
                  report: nil
                }
              ]
            }} = Authority.current_thing(c.authority, reader, input["target_id"])

    assert {:error, :profile_selection_revoked} =
             Store.record(c.store, %{report | source_sequence: 2}, capability)

    assert {:ok, ^receipt} = Authority.profile_change(c.authority, c.operator, revoke)
    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, %{writable: true}} = Store.health(store)
    {:ok, db} = Sqlite3.open(c.path)
    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.close(db)
  end

  test "artifact revocation records a target barrier and reapproval leaves it revoked", c do
    {input, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)
    {:ok, revision} = Store.revision(c.store)

    revoke = %{
      "action" => "revoke",
      "authority_epoch" => 1,
      "operation_id" => "artifact:revoke",
      "expected_revision" => revision,
      "artifact_digest" => c.digest,
      "expected_trust_revision" => c.receipt.final_revision
    }

    assert {:ok, revoked} = Authority.profile_change(c.authority, c.operator, revoke)
    assert revoked.changed_targets == 1
    assert {:ok, [[2, "revoked"]]} = query(c, "SELECT generation,state FROM profile_current")

    approve = %{
      revoke
      | "action" => "approve",
        "operation_id" => "artifact:reapprove",
        "expected_revision" => revoked.final_revision,
        "expected_trust_revision" => revoked.final_revision
    }

    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, approve)
    assert {:ok, [[2, "revoked"]]} = query(c, "SELECT generation,state FROM profile_current")
    assert {:ok, %{writable: true}} = Store.health(c.store)
    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, %{writable: true}} = Store.health(store)
  end

  test "a registry-supported profile outside the compiled catalogue enrolls atomically without grants",
       c do
    data =
      File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__)) |> JSON.decode!()

    data =
      data
      |> Map.put("id", "test.external-product")
      |> put_in(["fingerprint", "model"], "lifx.product.49")
      |> put_in(["fingerprint", "firmware_versions"], ["3.60"])

    c = approve_profile(c, data, "approval:external")
    c = fresh_capture(c, %{serial: <<0xD0, 0x73, 0xD5, 0, 0, 2>>, product: 49, firmware: {3, 60}})
    {input, _} = captured_input(c)

    input =
      input |> Map.put("target_id", "light:initial") |> Map.put("expected_binding_revision", 0)

    assert {:ok, :new, basis} = Store.profile_selection_basis(c.store, c.operator, input)

    assert basis["binding_revision"] == 0 and basis["stable_id"] == nil and
             basis["current_thing_document"] == nil

    assert {:ok, held} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert held.summary.current_profile_ref == nil
    assert {:ok, selected} = Authority.profile_change(c.authority, c.operator, input)

    assert selected.changed_targets == 1 and
             selected.final_revision == input["expected_revision"] + 3

    assert {:ok, [["test.external-product:1.0.0", 1]]} =
             query(
               c,
               "SELECT profile_ref,resource_revision FROM enrolled_things WHERE thing_id='light:initial'"
             )

    assert {:ok, [["lifx:d073d5000002", "lifx.product.49", "3.60", "thing_enrolled_reviewed"]]} =
             query(
               c,
               "SELECT h.stable_id,h.model,h.firmware,a.event_type FROM enrollment_review_history h JOIN authority_journal a USING(revision) WHERE h.thing_id='light:initial'"
             )

    assert {:ok, [[0]]} =
             query(c, "SELECT COUNT(*) FROM principal_targets WHERE thing_id='light:initial'")

    assert {:ok, [[0]]} =
             query(
               c,
               "SELECT COUNT(*) FROM profile_qualifications WHERE thing_id='light:initial'"
             )

    assert {:ok, ^selected} = Authority.profile_change(c.authority, c.operator, input)
    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "initial.backup")
    assert {:ok, _} = Store.export_backup(store, archive, key)
    assert {:ok, verified} = WotexHome.Durable.Backup.verify(archive, key)
    assert verified.dependencies.profile_selection_rows == 1
  end

  test "initial target IDs cannot be confused with another authority entity family", c do
    c = fresh_capture(c, %{serial: <<0xD0, 0x73, 0xD5, 0, 0, 2>>})
    {input, _} = captured_input(c)
    initial = input |> Map.put("target_id", c.digest) |> Map.put("expected_binding_revision", 0)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, initial)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, initial)
    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, %{writable: true}} = Store.health(store)
  end

  test "initial selection cannot move an occupied stable identity or reuse a revoked Thing", c do
    {input, session} = captured_input(c)

    initial =
      input |> Map.put("target_id", "light:new") |> Map.put("expected_binding_revision", 0)

    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, initial)

    assert {:error, :enrollment_conflict} =
             Authority.profile_change(c.authority, c.operator, initial)

    assert {:ok, []} = query(c, "SELECT thing_id FROM enrolled_things WHERE thing_id='light:new'")
    assert {:ok, %{writable: true}} = Store.health(c.store)
    assert {:ok, _} = Store.revoke_thing(c.store, "light:fixture")
    {:ok, revision} = Store.revision(c.store)

    revoked =
      input
      |> Map.put("operation_id", "selection:revoked-target")
      |> Map.put("expected_revision", revision)

    assert {:error, :target_unavailable} =
             Store.profile_selection_basis(c.store, c.operator, revoked)

    assert {:error, :capture_missing} =
             CaptureSession.checkout_auto(c.capture, "operator:review", session)
  end

  test "changed firmware creates a new reviewed basis and preserves revoked original qualification",
       c do
    {:ok, qualifier, _} =
      Store.provision_principal(c.store, "qualifier:firmware", ["qualify:profile"], [
        "light:fixture"
      ])

    {old_signed, old_basis, old_cohort, old_attestations} =
      WotexHome.Test.PortableProfileFixture.qualification(
        c.compiled_review,
        0,
        c.case_private,
        c.decision_private
      )

    assert {:ok, old_qualification} =
             Store.qualify_lifx_power(
               c.store,
               qualifier,
               old_signed,
               old_basis,
               old_cohort,
               old_attestations
             )

    data =
      File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__)) |> JSON.decode!()

    data =
      data
      |> Map.put("id", "test.new-firmware")
      |> put_in(["fingerprint", "firmware_versions"], ["1.23"])

    c = approve_profile(c, data, "approval:firmware") |> fresh_capture(%{firmware: {1, 23}})
    {input, _} = captured_input(c)
    {:ok, review} = Authority.review_profile_selection(c.authority, c.operator, input)
    assert review.basis["firmware"] == "1.22" and review.interview.firmware == "1.23"
    assert {:ok, _} = ReviewSession.hold(c.reviews, "operator:review", review)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)

    assert {:ok, %{qualification_head: head, identity: identity, current_use: :usable}} =
             Authority.profile_target(c.authority, c.manager, "light:fixture")

    assert head["revision"] == old_qualification and head["status"] == "revoked"
    assert head["profile_ref"] == "lifx.product-22:1.0.0" and identity.firmware == "1.23"

    assert {:ok, [["revoked", ^old_qualification]]} =
             query(c, "SELECT status,revision FROM profile_qualifications")

    assert {:ok, [["1.22"], ["1.23"]]} =
             query(c, "SELECT firmware FROM enrollment_review_history ORDER BY revision")

    assert {:ok, ^old_qualification} =
             Store.qualify_lifx_power(
               c.store,
               qualifier,
               old_signed,
               old_basis,
               old_cohort,
               old_attestations
             )

    {signed, basis, cohort, attestations} =
      WotexHome.Test.PortableProfileFixture.qualification(
        review,
        1,
        c.case_private,
        c.decision_private
      )

    assert {:ok, newer} =
             Store.qualify_lifx_power(c.store, qualifier, signed, basis, cohort, attestations)

    assert newer > old_qualification
    stop_supervised!(Store)
    store = start_supervised!({Store, [path: c.path, profile_custody: c.custody] ++ c.keys})
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
  end

  test "failed initial selection leaves no partial enrollment, binding or grants", c do
    c = fresh_capture(c, %{serial: <<0xD0, 0x73, 0xD5, 0, 0, 2>>})
    {input, _} = captured_input(c)

    initial =
      input |> Map.put("target_id", "light:new") |> Map.put("expected_binding_revision", 0)

    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, initial)
    {:ok, revision} = Store.revision(c.store)

    assert {:ok, []} =
             query(
               c,
               "CREATE TRIGGER reject_initial BEFORE INSERT ON authority_journal WHEN NEW.event_type='portable_profile_selection_committed' BEGIN SELECT RAISE(ABORT,'fixture'); END"
             )

    assert {:error, :store_unavailable} =
             Authority.profile_change(c.authority, c.operator, initial)

    assert {:ok, ^revision} = Store.revision(c.store)

    for table <- ["enrolled_things", "enrollment_bindings", "enrollment_review_history"] do
      assert {:ok, []} = query(c, "SELECT thing_id FROM #{table} WHERE thing_id='light:new'")
    end

    assert {:ok, [[0]]} = query(c, "SELECT COUNT(*) FROM profile_selection_history")
  end

  defp approve_profile(c, data, operation) do
    {:ok, digest} = Authority.stage_profile(c.authority, c.operator, JSON.encode!(data))
    {:ok, revision} = Store.revision(c.store)

    {:ok, receipt} =
      Authority.profile_change(c.authority, c.operator, %{
        "action" => "approve",
        "authority_epoch" => 1,
        "operation_id" => operation,
        "expected_revision" => revision,
        "artifact_digest" => digest,
        "expected_trust_revision" => 0
      })

    %{c | digest: digest, receipt: receipt}
  end

  defp fresh_capture(c, peer) do
    {:ok, scope} = IPv4Scope.new({192, 0, 2, 2}, 24)

    capture =
      start_supervised!(
        Supervisor.child_spec(
          {CaptureSession, interface_id: "en0", scope: scope, transport: {Peer, peer}},
          id: make_ref()
        )
      )

    %{c | capture: capture, authority: %{c.authority | capture: capture}}
  end

  test "missing bytes or a changed basis consumes no durable selection", c do
    {input, _} = captured_input(c)
    assert {:ok, held} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    {:ok, revision} = Store.revision(c.store)
    File.rm!(Path.join(c.root, c.digest <> ".json"))

    assert {:error, :profile_artifact_unavailable} =
             Authority.profile_change(c.authority, c.operator, input)

    assert :not_found = ReviewSession.status(c.reviews, "operator:review", held.review_token)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, %{writable: true}} = Store.health(c.store)
    assert {:ok, [[0]]} = query(c, "SELECT COUNT(*) FROM profile_selection_history")
  end

  test "Store refuses a structurally valid proposal bound to another runtime", c do
    {input, _} = captured_input(c)
    {:ok, review} = Authority.review_profile_selection(c.authority, c.operator, input)

    evidence = %{
      ref: input["session_ref"],
      candidates: review.candidates,
      selected_candidate_ref: input["candidate_ref"],
      interview: review.interview,
      expires_at: review.capture_deadline
    }

    {:ok, changed} =
      WotexHome.Profiles.Review.new(
        review.basis,
        review.artifact,
        evidence,
        input,
        String.duplicate("f", 64)
      )

    assert {:ok, _} = ReviewSession.hold(c.reviews, "operator:review", changed)

    assert {:error, :profile_review_mismatch} =
             Authority.profile_change(c.authority, c.operator, input)

    assert {:ok, [[0]]} = query(c, "SELECT COUNT(*) FROM profile_selection_history")
    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  test "expired proposal and a restarted review owner cannot commit or renew capture authority",
       c do
    stop_supervised!(ReviewSession)
    reviews = start_supervised!({ReviewSession, custody: c.custody, ttl_ms: 100})
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store, path: c.path, profile_custody: c.custody, profile_reviews: reviews}
      )

    c = %{
      c
      | store: store,
        reviews: reviews,
        authority: %{c.authority | store: store, profile_reviews: reviews}
    }

    {input, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    Process.sleep(110)

    assert {:error, :profile_review_consumed} =
             Authority.profile_change(c.authority, c.operator, input)

    assert {:ok, [[0]]} = query(c, "SELECT COUNT(*) FROM profile_selection_history")
    stop_supervised!(ReviewSession)

    assert {:error, :profile_review_unavailable} =
             Authority.profile_change(c.authority, c.operator, input)

    assert {:ok, %{writable: true}} = Store.health(store)
  end

  test "selected declarations cannot be changed through ordinary narrowing", c do
    {input, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)
    {:ok, artifact} = Custody.read(c.custody, c.digest)
    {:ok, thing} = Artifact.declaration(artifact, "light:fixture")

    narrower = %{
      thing
      | capabilities: %{"power" => %{thing.capabilities["power"] | freshness_ms: 4_000}}
    }

    assert {:error, :profile_lifecycle_required} = Store.narrow_thing(c.store, narrower, 1)
    assert {:ok, [[1]]} = query(c, "SELECT resource_revision FROM enrolled_things")
    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  test "missing original observation pins reject archives and disable current writes", c do
    {input, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)
    {report, capability} = selected_report(c)
    assert {:ok, _} = Store.record(c.store, report, capability)
    assert {:ok, []} = query(c, "DELETE FROM profile_observation_pins")
    {:ok, db} = Sqlite3.open(c.path)
    assert {:error, :corrupt_profile_ledger} = Integrity.validate_snapshot(db)
    archive = Path.join(c.directory, "corrupt.backup")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = WotexHome.Durable.Backup.export(db, archive, key)
    assert {:error, :invalid_backup} = WotexHome.Durable.Backup.verify(archive, key)
    Sqlite3.close(db)

    assert {:error, :store_unavailable} =
             Store.record(c.store, %{report | source_sequence: 2}, capability)

    assert {:ok, %{writable: false}} = Store.health(c.store)
  end

  test "qualified selection pins remain historical and a successor requires its own signed basis",
       c do
    {:ok, qualifier, _} =
      Store.provision_principal(c.store, "qualifier:selection", ["qualify:profile"], [
        "light:fixture"
      ])

    {input, _} = captured_input(c)
    {:ok, review} = Authority.review_profile_selection(c.authority, c.operator, input)
    assert {:ok, _} = ReviewSession.hold(c.reviews, "operator:review", review)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)

    {signed, basis, cohort, attestations} =
      WotexHome.Test.PortableProfileFixture.qualification(
        review,
        1,
        c.case_private,
        c.decision_private
      )

    assert {:ok, qualified} =
             Store.qualify_lifx_power(c.store, qualifier, signed, basis, cohort, attestations)

    assert {:ok, [[^qualified, 1, 1]]} =
             query(
               c,
               "SELECT owner_revision,selection_generation,resource_revision FROM profile_qualification_pins"
             )

    {second, _} = captured_input(c)
    {:ok, next_review} = Authority.review_profile_selection(c.authority, c.operator, second)
    assert {:ok, _} = ReviewSession.hold(c.reviews, "operator:review", next_review)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, second)

    assert {:ok, [["revoked", ^qualified]]} =
             query(c, "SELECT status,revision FROM profile_qualifications")

    File.rm_rf!(Path.join(c.directory, "qualification_claims"))

    assert {:ok, ^qualified} =
             Store.qualify_lifx_power(c.store, qualifier, signed, basis, cohort, attestations)

    {signed2, basis2, cohort2, attestations2} =
      WotexHome.Test.PortableProfileFixture.qualification(
        next_review,
        2,
        c.case_private,
        c.decision_private
      )

    assert {:ok, newer} =
             Store.qualify_lifx_power(c.store, qualifier, signed2, basis2, cohort2, attestations2)

    assert newer > qualified

    assert {:ok, [[^qualified, 1, 1], [^newer, 2, 2]]} =
             query(
               c,
               "SELECT owner_revision,selection_generation,resource_revision FROM profile_qualification_pins ORDER BY owner_revision"
             )

    assert {:ok, ^qualified} =
             Store.qualify_lifx_power(c.store, qualifier, signed, basis, cohort, attestations)

    assert {:ok, [["qualified", ^newer]]} =
             query(c, "SELECT status,revision FROM profile_qualifications")

    stop_supervised!(Store)
    store = start_supervised!({Store, [path: c.path, profile_custody: c.custody] ++ c.keys})
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "qualified.backup")
    assert {:ok, _} = Store.export_backup(store, archive, key)
    assert {:ok, verified} = WotexHome.Durable.Backup.verify(archive, key)
    assert verified.dependencies.retained_qualification_rows == 2
    assert verified.dependencies.qualified_profile_rows == 1
    assert_pin_corruption(c, "profile_qualification_pins")
  end

  test "request and rule pins survive reselection while current rule use requires the new basis",
       c do
    {:ok, controller, _} =
      Store.provision_principal(
        c.store,
        "controller:selection",
        ["read", "control:ordinary", "rule:manage", "rule:review"],
        ["light:fixture"]
      )

    {input, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, input)
    end_maintenance(c)

    {:ok, mutation} =
      Mutation.new(%{
        "api_version" => 1,
        "authority_epoch" => 1,
        "operation_id" => "request:selected",
        "expected_revision" => 1,
        "target_id" => "light:fixture",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      })

    assert {:ok, request} = Store.submit_request(c.store, controller, mutation)
    assert request.disposition == :held

    assert {:ok, [[1, 1]]} =
             query(c, "SELECT selection_generation,resource_revision FROM profile_request_pins")

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, admission} =
             Authority.admit_rule(c.authority, controller, 1, "rule:selected", revision, [rule()])

    assert {:ok, [[1, 1]]} =
             query(c, "SELECT selection_generation,resource_revision FROM profile_rule_pins")

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.activate_rule(
               c.authority,
               controller,
               1,
               "rule:activate",
               revision,
               admission.revision
             )

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.begin_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maint:selection:second",
               revision
             )

    {second, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, second)
    assert {:ok, selected} = Authority.profile_change(c.authority, c.operator, second)
    assert selected.changed_targets == 1
    assert {:ok, [[2, "selected"]]} = query(c, "SELECT generation,state FROM profile_current")

    assert {:ok, [[1, 1]]} =
             query(c, "SELECT selection_generation,resource_revision FROM profile_request_pins")

    assert {:ok, rejected} = Store.submit_request(c.store, controller, mutation)
    assert rejected.disposition == :rejected

    assert {:ok, ^admission} =
             Authority.admit_rule(
               c.authority,
               controller,
               1,
               "rule:selected",
               admission.revision - 1,
               [
                 rule()
               ]
             )

    end_maintenance(c)
    {:ok, revision} = Store.revision(c.store)

    assert {:error, :profile_basis_changed} =
             Authority.activate_rule(
               c.authority,
               controller,
               1,
               "rule:stale",
               revision,
               admission.revision
             )

    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path, profile_custody: c.custody})
    assert {:ok, %{writable: true}} = Store.health(store)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "selected.backup")
    assert {:ok, _} = Store.export_backup(store, archive, key)
    assert {:ok, verified} = WotexHome.Durable.Backup.verify(archive, key)
    assert verified.dependencies.profile_selection_rows == 2
    assert_pin_corruption(c, "profile_request_pins")
    assert_pin_corruption(c, "profile_rule_pins")
  end

  @tag requires_socket: true
  test "CLI and private socket retain the same review, selection and original receipt", c do
    socket_root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "woh-profile-api-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir!(socket_root)
    File.chmod!(socket_root, 0o700)
    on_exit(fn -> File.rm_rf!(socket_root) end)
    socket = Path.join(socket_root, "home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    encoded = Base.url_encode64(c.operator, padding: false)
    credential_file = Path.join(c.directory, "credential")
    File.write!(credential_file, encoded <> "\n")
    File.chmod!(credential_file, 0o600)
    flags = ["--socket", socket, "--credential-file", credential_file]
    source = Path.join(c.directory, "input.json")
    File.write!(source, File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__)))
    File.chmod!(source, 0o600)
    {:ok, revision} = Store.revision(c.store)
    imported = profile_cli(flags, ["profile-import", source])["profile_artifact"]
    assert imported["artifact_digest"] == c.digest and imported["authority_changed"] == false
    assert {:ok, ^revision} = Store.revision(c.store)
    catalogue = profile_cli(flags, ["profiles"])["profile_catalogue"]
    assert hd(catalogue["items"])["byte_availability"] == "available"
    before = profile_cli(flags, ["profile-target", "light:fixture"])["profile_target"]

    assert before["selection_generation"] == 0 and
             before["binding_revision"] == c.binding_revision

    {input, _} = captured_input(c)
    File.write!(source, JSON.encode!(input))
    held = profile_cli(flags, ["profile-prepare", source])["profile_review"]
    again = profile_cli(flags, ["profile-prepare", source])["profile_review"]

    assert held["review_token"] == again["review_token"] and
             again["remaining_ms"] <= held["remaining_ms"]

    assert held["identity"]["prior"] == held["identity"]["captured"]

    assert profile_cli(flags, ["profile-review-status", held["review_token"]])["profile_review"][
             "review_digest"
           ] == held["review_digest"]

    assert %{"outcome" => "not_found"} =
             profile_frame(c.authority, c.manager, "profile_review_status", %{
               "review_token" => held["review_token"]
             })

    assert %{"outcome" => "not_found"} =
             profile_frame(c.authority, c.manager, "profile_review_cancel", %{
               "review_token" => held["review_token"]
             })

    # Drop the real server reply after its length prefix, before the client can
    # decode or retain any receipt body. Recovery uses the original scope.
    {:ok, lost_socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(socket)},
        0,
        [:binary, active: false, packet: :raw],
        5_000
      )

    {:ok, change_frame} =
      Frame.encode_request(%{
        "api_version" => 1,
        "operation" => "profile_change",
        "credential" => encoded,
        "change" => input
      })

    assert :ok = :gen_tcp.send(lost_socket, change_frame)
    assert {:ok, <<reply_length::32>>} = :gen_tcp.recv(lost_socket, 4, 5_000)
    assert reply_length > 0
    :gen_tcp.close(lost_socket)

    receipt =
      profile_cli(flags, ["profile-operation-status", "1", input["operation_id"]])[
        "profile_receipt"
      ]

    assert profile_cli(flags, ["profile-change", source])["profile_receipt"] == receipt
    assert {:ok, direct} = Authority.profile_change(c.authority, c.operator, input)
    assert receipt == WotexHome.Profiles.Wire.encode(direct)

    assert profile_cli(flags, ["profile-operation-status", "1", input["operation_id"]])[
             "profile_receipt"
           ] == receipt

    assert %{"outcome" => "not_found"} =
             profile_frame(c.authority, c.manager, "profile_operation_status", %{
               "authority_epoch" => 1,
               "operation_id" => input["operation_id"]
             })

    target = profile_cli(flags, ["profile-target", "light:fixture"])["profile_target"]
    assert target["current_use"] == "usable" and target["selection_state"] == "selected"
    assert target["qualification_head"] == nil
    assert target["declaration"]["profile_ref"] == imported["profile_ref"]
    File.rm!(Path.join(c.root, c.digest <> ".json"))
    stop_supervised!(ReviewSession)
    assert profile_cli(flags, ["profile-prepare", source])["profile_receipt"] == receipt
    assert profile_cli(flags, ["profile-change", source])["profile_receipt"] == receipt

    assert profile_cli(flags, ["profile-operation-status", "1", input["operation_id"]])[
             "profile_receipt"
           ] == receipt

    missing = profile_cli(flags, ["profile-target", "light:fixture"])["profile_target"]

    assert missing["selection_state"] == "selected" and
             missing["current_use"] == "profile_artifact_unavailable"

    item = hd(profile_cli(flags, ["profiles"])["profile_catalogue"]["items"])
    assert item["state"] == "approved" and item["byte_availability"] == "unavailable"
    changed = Map.put(input, "review_ref", "review:changed")

    assert %{"outcome" => "error", "reason" => "profile_operation_conflict"} =
             profile_frame(c.authority, c.operator, "profile_change", %{"change" => changed})

    assert {:ok, %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"}} =
             Client.request(socket, %{
               "api_version" => 1,
               "operation" => "profiles",
               "credential" => encoded,
               "path" => source
             })

    refute JSON.encode!(target) =~ c.root
    assert {:ok, %{dispatch_enabled: false, writable: true}} = Store.health(c.store)
  end

  test "framed profile reviews disclose initial and changed firmware identity without granting effects",
       c do
    c = fresh_capture(c, %{serial: <<0xD0, 0x73, 0xD5, 0, 0, 2>>})
    {input, _} = captured_input(c)

    input =
      input |> Map.put("target_id", "light:api:new") |> Map.put("expected_binding_revision", 0)

    assert %{"outcome" => "ok", "profile_target" => absent} =
             profile_frame(c.authority, c.manager, "profile_target", %{
               "thing_id" => input["target_id"]
             })

    assert absent["status"] == "absent" and absent["binding_revision"] == 0 and
             absent["identity"] == nil

    assert %{"outcome" => "error", "reason" => "profile_review_missing"} =
             profile_frame(c.authority, c.operator, "profile_change", %{"change" => input})

    assert %{"outcome" => "ok", "profile_review" => review} =
             profile_frame(c.authority, c.operator, "profile_prepare", %{"selection" => input})

    assert review["identity"]["prior"]["stable_id"] == nil
    assert review["identity"]["captured"]["stable_id"] == "lifx:d073d5000002"

    assert %{"outcome" => "ok"} =
             profile_frame(c.authority, c.operator, "profile_change", %{"change" => input})

    assert {:ok, [[0]]} =
             query(c, "SELECT COUNT(*) FROM principal_targets WHERE thing_id='light:api:new'")

    assert {:ok, [[0]]} = query(c, "SELECT COUNT(*) FROM profile_qualifications")

    data =
      File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__)) |> JSON.decode!()

    data =
      data
      |> Map.put("id", "test.api-firmware")
      |> put_in(["fingerprint", "firmware_versions"], ["1.23"])

    c = approve_profile(c, data, "approval:api:firmware") |> fresh_capture(%{firmware: {1, 23}})
    {:ok, target} = Authority.profile_target(c.authority, c.operator, "light:fixture")
    {:ok, session, [%{raw_ref: candidate}]} = Authority.lifx_discover(c.authority, c.operator)
    {:ok, _, _} = Authority.lifx_interview(c.authority, c.operator, session, candidate)

    input =
      Map.merge(input, %{
        "operation_id" => "selection:api:firmware",
        "target_id" => "light:fixture",
        "expected_revision" => target.store_revision,
        "expected_binding_revision" => target.binding_revision,
        "artifact_digest" => c.digest,
        "expected_trust_revision" => c.receipt.final_revision,
        "expected_policy_generation" => target.policy_generation,
        "session_ref" => session,
        "candidate_ref" => candidate,
        "review_ref" => "review:api:firmware"
      })

    assert %{"outcome" => "ok", "profile_review" => review} =
             profile_frame(c.authority, c.operator, "profile_prepare", %{"selection" => input})

    assert review["identity"]["prior"]["firmware"] == "1.22" and
             review["identity"]["captured"]["firmware"] == "1.23"

    assert %{"outcome" => "ok", "profile_review_cancelled" => true} =
             profile_frame(c.authority, c.operator, "profile_review_cancel", %{
               "review_token" => review["review_token"]
             })

    assert %{"outcome" => "not_found"} =
             profile_frame(c.authority, c.operator, "profile_review_status", %{
               "review_token" => review["review_token"]
             })

    assert %{"outcome" => "error", "reason" => "profile_review_consumed"} =
             profile_frame(c.authority, c.operator, "profile_change", %{"change" => input})
  end

  defp profile_cli(flags, command) do
    capture_io(fn -> assert WotexHome.CLI.main(flags ++ command) == 0 end) |> JSON.decode!()
  end

  defp profile_frame(authority, credential, operation, fields) do
    request =
      Map.merge(
        %{
          "api_version" => 1,
          "operation" => operation,
          "credential" => Base.url_encode64(credential, padding: false)
        },
        fields
      )

    {:ok, frame} = Frame.encode_request(request)
    {:ok, <<size::32, body::binary>>} = Server.route_frame(authority, frame)
    assert size == byte_size(body)
    {:ok, response} = Frame.decode_response(body)
    response
  end

  defp end_maintenance(c) do
    {:ok, %{begin_revision: begin_revision}} =
      Authority.maintenance_status(c.authority, c.maintainer)

    {:ok, revision} = Store.revision(c.store)

    assert {:ok, _} =
             Authority.end_maintenance(
               c.authority,
               c.maintainer,
               1,
               "maint:end:#{begin_revision}",
               revision,
               begin_revision
             )
  end

  defp rule do
    %{
      "version" => 1,
      "id" => "rule:selection",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => "light:fixture",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => 1,
      "cooldown_ms" => 0,
      "causal_budget" => 1
    }
  end

  test "a selection journal failure rolls back every barrier and consumes only the proposal", c do
    {input, _} = captured_input(c)
    assert {:ok, held} = Authority.prepare_profile_selection(c.authority, c.operator, input)
    {:ok, revision} = Store.revision(c.store)

    assert {:ok, []} =
             query(
               c,
               "CREATE TRIGGER reject_selection BEFORE INSERT ON authority_journal WHEN NEW.event_type='portable_profile_selection_committed' BEGIN SELECT RAISE(ABORT,'fixture'); END"
             )

    assert {:error, :store_unavailable} = Authority.profile_change(c.authority, c.operator, input)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert {:ok, [[0]]} = query(c, "SELECT COUNT(*) FROM profile_selection_history")
    assert {:ok, [[1]]} = query(c, "SELECT COUNT(*) FROM enrollment_review_history")

    assert {:ok, [["lifx.product-22:1.0.0", 0]]} =
             query(c, "SELECT profile_ref,resource_revision FROM enrolled_things")

    assert :not_found = ReviewSession.status(c.reviews, "operator:review", held.review_token)
    assert {:ok, []} = query(c, "DROP TRIGGER reject_selection")
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store, path: c.path, profile_custody: c.custody, profile_reviews: c.reviews}
      )

    assert {:ok, %{writable: true}} = Store.health(store)
    assert {:error, :profile_review_consumed} = Store.profile_change(store, c.operator, input)
  end

  defp selected_report(c) do
    {:ok, artifact} = Custody.read(c.custody, c.digest)
    {:ok, thing} = Artifact.declaration(artifact, "light:fixture")
    capability = thing.capabilities["power"]

    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "source:selection",
          "source_sequence" => 1,
          "boot_epoch" => "boot:fixture",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000,
          "received_monotonic_ms" => 10
        },
        capability
      )

    {report, capability}
  end

  defp assert_pin_corruption(c, table) do
    {:ok, db} = Sqlite3.open(c.path)
    assert :ok = Integrity.validate_snapshot(db)

    assert {:ok, []} =
             SQL.query(db, "UPDATE #{table} SET selection_generation=selection_generation+1")

    assert {:error, :corrupt_profile_ledger} = Integrity.validate_snapshot(db)

    assert {:ok, []} =
             SQL.query(db, "UPDATE #{table} SET selection_generation=selection_generation-1")

    assert :ok = Integrity.validate_snapshot(db)
    {:ok, [row]} = SQL.query(db, "SELECT * FROM #{table} ORDER BY owner_revision LIMIT 1")
    {:ok, columns} = SQL.query(db, "PRAGMA table_info(#{table})")
    names = Enum.map_join(columns, ",", &Enum.at(&1, 1))

    owner =
      Enum.find_index(columns, &(Enum.at(&1, 1) == "owner_revision")) |> then(&Enum.at(row, &1))

    assert {:ok, []} = SQL.query(db, "DELETE FROM #{table} WHERE owner_revision=?", [owner])
    assert {:error, :corrupt_profile_ledger} = Integrity.validate_snapshot(db)

    assert {:ok, []} =
             SQL.query(
               db,
               "INSERT INTO #{table} (#{names}) VALUES (#{Enum.map_join(row, ",", fn _ -> "?" end)})",
               row
             )

    assert :ok = Integrity.validate_snapshot(db)
    Sqlite3.close(db)
  end

  defp query(c, sql) do
    {:ok, db} = Sqlite3.open(c.path)

    try do
      SQL.query(db, sql)
    after
      Sqlite3.close(db)
    end
  end

  defp native_access_basis(c) do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, identity} = Authority.native_setup_identity(c.authority)

    original =
      identity
      |> Map.drop(["store_revision"])
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      })

    assert {:ok, receipt} = Authority.ensure_native_principal(c.authority, original)
    {selection, _} = captured_input(c)
    assert {:ok, _} = Authority.prepare_profile_selection(c.authority, c.operator, selection)
    assert {:ok, _} = Authority.profile_change(c.authority, c.operator, selection)
    end_maintenance(c)
    assert {:ok, snapshot} = Authority.profile_target(c.authority, secret, "light:fixture")

    grant =
      original
      |> Map.delete("role")
      |> Map.merge(%{
        "creation_revision" => receipt["revision"],
        "operation_id" => "access:grant",
        "expected_revision" => snapshot.store_revision,
        "target_id" => snapshot.target_id,
        "resource_revision" => snapshot.resource_revision,
        "binding_revision" => snapshot.binding_revision,
        "selection_generation" => snapshot.selection_generation,
        "artifact_digest" => snapshot.artifact_digest
      })

    {secret, grant}
  end

  defp native_revoke(grant, revision) do
    grant
    |> Map.take(~w(deployment_id owner_id authority_epoch creation_revision verifier target_id))
    |> Map.merge(%{"operation_id" => "access:revoke", "expected_revision" => revision})
  end

  defp native_frame_bodies(<<>>), do: []

  defp native_frame_bodies(<<size::32, body::binary-size(size), rest::binary>>),
    do: [body | native_frame_bodies(rest)]

  # Synthetic historical execution states exercise the real invalidation
  # transaction. They send no packet and establish no physical qualification.
  defp execution_fixture(c, secret, grant, phase) do
    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "authority_epoch" => 1,
               "operation_id" => "request:native:boundary",
               "expected_revision" => 1,
               "target_id" => grant["target_id"],
               "capability_key" => "power",
               "value" => %{"type" => "boolean", "value" => true}
             })

    assert {:ok, held} = Store.submit_request(c.store, secret, mutation)
    db = :sys.get_state(c.store).db
    {:ok, artifact} = Custody.read(c.custody, c.digest)
    {:ok, thing} = Artifact.declaration(artifact, grant["target_id"])
    {:ok, %{rule_generation: generation}} = Store.health(c.store)

    phases =
      case phase do
        "queued" -> ["queued"]
        "claimed" -> ~w(queued claimed)
        "dispatching" -> ~w(queued claimed dispatching)
        "protocol_accepted" -> ~w(queued claimed dispatching protocol_accepted)
      end

    first = held.revision + 1
    final = first + length(phases) - 1

    assert {:ok, :ok} =
             SQL.transaction(db, fn db ->
               assert :ok = WotexHome.Durable.Store.CausalLedger.reserve(db, held, first)

               assert {:ok, []} =
                        SQL.query(db, "DELETE FROM request_outbox WHERE operation_id=?", [
                          held.operation_id
                        ])

               assert {:ok, []} =
                        SQL.query(
                          db,
                          "UPDATE request_receipts SET disposition=?,reason=NULL,revision=? WHERE operation_id=?",
                          [phase, final, held.operation_id]
                        )

               for {state, revision} <- Enum.with_index(phases, first) do
                 assert :ok =
                          WotexHome.Durable.Store.Journal.request_event(
                            db,
                            revision,
                            held.principal_id,
                            1,
                            held.operation_id,
                            state,
                            nil
                          )
               end

               token = if phase == "queued", do: nil, else: :crypto.strong_rand_bytes(32)
               boot = if token == nil, do: nil, else: "fixture:boot"
               handoff = if phase in ~w(dispatching protocol_accepted), do: first + 2, else: nil

               assert {:ok, []} =
                        SQL.query(
                          db,
                          "INSERT INTO request_execution (principal_id,authority_epoch,operation_id,target_id,effect_domain,profile_ref,profile_evidence_ref,resource_revision,rule_generation,baseline_revision,admission_revision,planned_value,state,claim_token,claim_boot_epoch,handoff_revision,attempts,revision) VALUES (?,?,?,?,?,?,?,?,?,?,?,CAST(? AS BLOB),?,CAST(? AS BLOB),?,?,?,?)",
                          [
                            held.principal_id,
                            1,
                            held.operation_id,
                            thing.id,
                            thing.id,
                            thing.profile_ref,
                            thing.capabilities["power"].evidence_ref,
                            grant["resource_revision"],
                            generation,
                            0,
                            first,
                            <<1, 1>>,
                            phase,
                            token,
                            boot,
                            handoff,
                            if(token == nil, do: 0, else: 1),
                            final
                          ]
                        )

               assert :ok = Integrity.validate_snapshot(db)
               {:commit, :ok}
             end)
  end

  defp captured_input(c) do
    {:ok, session, [%{raw_ref: candidate}]} =
      Authority.lifx_discover(c.authority, c.operator)

    {:ok, _, _} = Authority.lifx_interview(c.authority, c.operator, session, candidate)
    {input(c, session, candidate), session}
  end

  defp input(c, session, candidate) do
    {:ok, %{store_revision: revision, policy_generation: policy}} =
      Authority.profile_catalogue(c.authority, c.operator)

    {:ok, %{rule_generation: generation}} = Store.health(c.store)

    {:ok, [[resource, binding]]} =
      query(
        c,
        "SELECT t.resource_revision,b.revision FROM enrolled_things t JOIN enrollment_bindings b USING(thing_id)"
      )

    {:ok, selections} = query(c, "SELECT generation FROM profile_current")

    selected_generation =
      case selections do
        [] -> 0
        [[value]] -> value
      end

    %{
      "action" => "select",
      "authority_epoch" => 1,
      "operation_id" => "selection:review:#{selected_generation}",
      "expected_revision" => revision,
      "artifact_digest" => c.digest,
      "expected_trust_revision" => c.receipt.final_revision,
      "target_id" => "light:fixture",
      "expected_resource_revision" => resource,
      "expected_binding_revision" => binding,
      "expected_selection_generation" => selected_generation,
      "expected_policy_generation" => policy,
      "expected_rule_generation" => generation,
      "session_ref" => session,
      "candidate_ref" => candidate,
      "review_ref" => "review:portable:#{selected_generation}"
    }
  end
end
