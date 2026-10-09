Code.require_file("../support/controller_tls_fixture.exs", __DIR__)

defmodule WotexHome.ControllerPairingConsumptionTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.ControllerConnections.{Codec, ConsumptionCodec, PairingReview}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Access, Integrity, PairingWriter, SQL}
  alias WotexHome.TestSupport.ControllerTLSFixture, as: Peer
  alias WotexHome.Semantics.Thing

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "woh-consumption-cert-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    template =
      Peer.invitation(Peer.create(directory), 49_999)
      |> Map.drop(~w(invitation_id bootstrap_secret))

    %{template: template}
  end

  setup do
    Process.flag(:trap_exit, true)
    root = Path.join(System.tmp_dir!(), "woh-consumption-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))

    reviews =
      start_supervised!(
        Supervisor.child_spec({PairingReview, store_owner: store}, restart: :temporary)
      )

    %{
      root: root,
      path: path,
      store: store,
      reviews: reviews,
      authority: Authority.new(store: store, pairing_reviews: reviews)
    }
  end

  test "one transaction consumes the invitation and provisions exactly approved read access", c do
    {_admin, request, approval} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    assert response["principal_id"] == ConsumptionCodec.principal(approval)
    assert response["revision"] == 1
    assert response["permissions"] == ["read"]
    assert response["target_ids"] == []
    refute response["credential"] == request["bootstrap_secret"]
    assert {:ok, bytes} = Codec.encode("paired", response)
    assert {:ok, ^response} = Codec.verify_response(bytes, request)
    credential = Base.url_decode64!(response["credential"], padding: false)

    assert {:ok, %{active_principals: 1, dispatch_enabled: false}} =
             Authority.health(c.authority, credential)

    assert {:ok, 1} = Store.revision(c.store)
    assert counts(c.store) == [1, 1, 1, 0]
    assert :ok = Integrity.validate_snapshot(db(c.store))
    assert :sys.get_state(c.reviews).window == nil
    assert {:ok, status} = Authority.pairing_client_status(c.authority, lookup(request))

    assert status.original == %{
             "approval" => approval,
             "principal_id" => response["principal_id"],
             "revision" => 1
           }

    assert status.status == "active"
    assert status.store_revision == 1
    assert {:error, :invitation_consumed} = Authority.pairing_complete(c.authority, request)
    assert counts(c.store) == [1, 1, 1, 0]
  end

  test "unconfirmed, denied and altered clients provision nothing", c do
    assert {:ok, admin, invitation} = Authority.pairing_open(c.authority, c.template)
    request = request(invitation)
    assert {:error, :confirmation_denied} = Authority.pairing_complete(c.authority, request)
    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)
    assert {:ok, _} = Authority.pairing_approve(c.authority, admin, ref)

    for {key, value} <- [
          {"client_id", id(44)},
          {"request_id", id(55)},
          {"client_label", "different"}
        ] do
      assert {:error, :confirmation_denied} =
               Authority.pairing_complete(c.authority, Map.put(request, key, value))
    end

    assert :ok = Authority.pairing_deny(c.authority, admin, ref)
    assert {:error, :confirmation_denied} = Authority.pairing_complete(c.authority, request)
    assert counts(c.store) == [0, 0, 0, 0]
  end

  test "concurrent completion can issue only one credential", c do
    {_admin, request, _} = approved(c)

    tasks =
      for _ <- 1..16, do: Task.async(fn -> Authority.pairing_complete(c.authority, request) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(results, fn
             {:ok, _} ->
               true

             {:error, reason} ->
               reason in [:confirmation_denied, :invitation_consumed, :pairing_closed]
           end)

    assert counts(c.store) == [1, 1, 1, 0]
  end

  test "only active targets receive exact explicit control grants", c do
    thing = thing("light:approved")
    assert {:ok, 1} = Store.enroll_thing(c.store, thing)
    access = %{"permissions" => ["control:ordinary", "read"], "target_ids" => [thing.id]}
    {_admin, request, _} = approved(c, access: access)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    assert Map.take(response, ~w(permissions target_ids)) == access

    assert {:ok, %{active_principals: 1, dispatch_enabled: false}} =
             Authority.health(
               c.authority,
               Base.url_decode64!(response["credential"], padding: false)
             )

    assert {:ok, targets} = Access.allowed_targets(db(c.store), response["principal_id"])
    assert targets == MapSet.new([thing.id])
    assert :ok = Integrity.validate_snapshot(db(c.store))

    {_admin, next, _} =
      approved(c, client_id: id(99), access: %{access | "target_ids" => ["light:absent"]})

    assert {:error, :pairing_unavailable} = Authority.pairing_complete(c.authority, next)
    assert counts(c.store) == [1, 1, 2, 1]
    assert :available = Store.pairing_consumed(c.store, next["invitation_id"])
    assert :sys.get_state(c.store).writable
  end

  test "later trusted grants, rotation and removal preserve the original pairing receipt", c do
    thing = thing("light:under_score")
    assert {:ok, 1} = Store.enroll_thing(c.store, thing)
    {_admin, request, _} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    assert {:ok, original} = Authority.pairing_client_status(c.authority, lookup(request))
    old = Base.url_decode64!(response["credential"], padding: false)

    assert {:ok, changed, 3} =
             Store.grant_target_and_rotate(c.store, response["principal_id"], thing.id)

    assert {:error, :unauthorized} = Authority.health(c.authority, old)
    assert {:ok, _} = Authority.health(c.authority, changed)
    assert {:ok, current} = Authority.pairing_client_status(c.authority, lookup(request))
    assert current.original == original.original
    assert current.original["approval"]["target_ids"] == []
    assert :ok = Integrity.validate_snapshot(db(c.store))

    assert {:ok, rotated, 4} =
             Store.rotate_principal_credential(c.store, response["principal_id"])

    assert {:error, :unauthorized} = Authority.health(c.authority, changed)
    assert {:ok, _} = Authority.health(c.authority, rotated)
    assert {:ok, 5} = Store.revoke_target_grant(c.store, response["principal_id"], thing.id)
    assert :ok = Integrity.validate_snapshot(db(c.store))
    assert {:error, :invitation_consumed} = Authority.pairing_complete(c.authority, request)
  end

  test "reserved paired principal cannot be fabricated through ordinary trusted provisioning",
       c do
    {_admin, _request, approval} = approved(c)

    assert {:error, :invalid_provisioning} =
             Store.provision_principal(
               c.store,
               ConsumptionCodec.principal(approval),
               ["read"],
               []
             )

    assert counts(c.store) == [0, 0, 0, 0]
  end

  test "only the actual Store and original checkout caller can obtain a commit basis", c do
    {_admin, request, approval} = approved(c)
    assert {:ok, ref, ^approval} = PairingReview.checkout(c.reviews, request)

    assert {:error, :pairing_unavailable} =
             PairingReview.commit_basis(c.reviews, ref, approval, self())

    other = Task.async(fn -> Store.pairing_commit(c.store, c.reviews, ref, approval) end)
    assert {:error, :pairing_unavailable} = Task.await(other)
    assert counts(c.store) == [0, 0, 0, 0]
    assert {:ok, _, credential} = Store.pairing_commit(c.store, c.reviews, ref, approval)
    assert byte_size(credential) == 32
    assert :ok = PairingReview.finish(c.reviews, ref)
  end

  test "a changed Store revision rolls back and closes the checked-out review", c do
    {_admin, request, _} = approved(c)
    assert {:ok, _, 1} = Authority.provision_diagnostic(c.authority)
    assert {:error, :pairing_unavailable} = Authority.pairing_complete(c.authority, request)
    assert counts(c.store) == [1, 0, 1, 0]
    assert :available = Store.pairing_consumed(c.store, request["invitation_id"])
    assert :sys.get_state(c.reviews).window == nil
    assert :sys.get_state(c.store).writable
  end

  test "transaction insert failure rolls back principal, journal, revision and consumption", c do
    {_admin, request, _} = approved(c)

    assert :ok =
             Sqlite3.execute(
               db(c.store),
               "CREATE TRIGGER fixture_pairing_failure BEFORE INSERT ON controller_pairings BEGIN SELECT RAISE(ABORT,'fixture_pairing_failure'); END"
             )

    assert {:error, :pairing_unavailable} = Authority.pairing_complete(c.authority, request)
    assert counts(c.store) == [0, 0, 0, 0]
    assert {:ok, 0} = Store.revision(c.store)
    refute :sys.get_state(c.store).writable
    assert :sys.get_state(c.reviews).window == nil
    assert :ok = Integrity.validate_snapshot(db(c.store))
  end

  test "consumption survives Store/review restart and cannot return either credential", c do
    {_admin, request, approval} = approved(c)
    # Simulate lost delivery by discarding the one successful credential result.
    assert {:ok, _} = Authority.pairing_complete(c.authority, request)
    assert {:ok, before} = Authority.pairing_client_status(c.authority, lookup(request))
    GenServer.stop(c.store)
    next = start_supervised!({Store, path: c.path}, id: :consumption_restart)
    authority = Authority.new(store: next)
    assert {:error, :invitation_consumed} = Authority.pairing_complete(authority, request)
    assert {:ok, ^before} = Authority.pairing_client_status(authority, lookup(request))
    assert before.original["approval"] == approval
    assert counts(next) == [1, 1, 1, 0]
    assert :ok = Integrity.validate_snapshot(db(next))
  end

  test "expiry at the final live guard rolls back already written tentative rows", c do
    {_admin, request, _} = approved(c, duration_ms: 1_500)
    database = db(c.store)
    deadline = :sys.get_state(c.reviews).window.expires
    parent = self()
    gate = make_ref()

    # OTP's private test debugger blocks only actual commit-basis messages.
    # No caller-authored guard or adjustable product clock is introduced.
    hook = fn count, event, _ ->
      case event do
        {:in, {:"$gen_call", _, {:commit_basis, _, _, _}}} ->
          send(parent, {gate, self()})

          receive do
            {^gate, :continue} -> count + 1
          after
            5_000 -> count + 1
          end

        _ ->
          count
      end
    end

    assert :ok = :sys.install(c.reviews, {hook, 0})
    task = Task.async(fn -> Authority.pairing_complete(c.authority, request) end)
    assert_receive {^gate, review}
    assert review == c.reviews
    assert {:ok, [[0]]} = SQL.query(database, "SELECT COUNT(*) FROM controller_pairings")
    send(review, {gate, :continue})
    assert_receive {^gate, ^review}

    assert {:ok, [[1, 1, 1]]} =
             SQL.query(
               database,
               "SELECT (SELECT COUNT(*) FROM controller_pairings),(SELECT COUNT(*) FROM principals),(SELECT value FROM meta WHERE key='revision')"
             )

    with_db(c.path, fn external ->
      assert {:ok, [[0, 0]]} =
               SQL.query(
                 external,
                 "SELECT (SELECT COUNT(*) FROM controller_pairings),(SELECT COUNT(*) FROM principals)"
               )
    end)

    Process.sleep(max(1, deadline - System.monotonic_time(:millisecond) + 20))
    send(review, {gate, :continue})
    assert {:error, :outcome_unknown} = Task.await(task)
    assert counts(c.store) == [0, 0, 0, 0]
    assert {:ok, 0} = Store.revision(c.store)
    assert :available = Store.pairing_consumed(c.store, request["invitation_id"])
    assert :sys.get_state(c.store).writable
    assert :sys.get_state(c.reviews).window == nil
  end

  test "trusted exact revocation reconciles lost delivery and requires a fresh invitation/client",
       c do
    {_admin, request, _} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    credential = Base.url_decode64!(response["credential"], padding: false)

    assert {:error, :resnapshot_required} =
             Authority.revoke_paired_client(c.authority, lookup(request), 0)

    assert {:ok, revoked} = Authority.revoke_paired_client(c.authority, lookup(request), 1)
    assert revoked.status == "revoked"
    assert {:error, :unauthorized} = Authority.health(c.authority, credential)
    assert {:ok, ^revoked} = Authority.revoke_paired_client(c.authority, lookup(request), 0)
    assert {:error, :invitation_consumed} = Authority.pairing_complete(c.authority, request)
    {_admin, next, _} = approved(c, client_id: id(99), request_id: id(100))
    assert {:ok, replacement} = Authority.pairing_complete(c.authority, next)
    refute replacement["principal_id"] == response["principal_id"]
    assert counts(c.store) == [2, 2, 3, 0]
    assert :ok = Integrity.validate_snapshot(db(c.store))
  end

  test "another original cannot read or revoke the consumed association", c do
    {_admin, request, _} = approved(c)
    assert {:ok, _} = Authority.pairing_complete(c.authority, request)

    for key <- ConsumptionCodec.original_fields() do
      wrong = Map.put(lookup(request), key, id(99))

      expected =
        if key == "invitation_id", do: :not_found, else: {:error, :pairing_original_conflict}

      assert Authority.pairing_client_status(c.authority, wrong) == expected
      assert {:error, _} = Authority.revoke_paired_client(c.authority, wrong, 1)
    end

    assert {:ok, %{status: "active"}} =
             Authority.pairing_client_status(c.authority, lookup(request))

    assert {:ok, 1} = Store.revision(c.store)
  end

  test "fresh invitation cannot create another principal for the same original client/epoch", c do
    {_admin, request, _} = approved(c)
    assert {:ok, _} = Authority.pairing_complete(c.authority, request)
    {_admin, next, _} = approved(c)
    assert {:error, :pairing_unavailable} = Authority.pairing_complete(c.authority, next)
    assert counts(c.store) == [1, 1, 1, 0]
    assert :available = Store.pairing_consumed(c.store, next["invitation_id"])
  end

  test "backup retains consumed history but cannot reissue credentials or start a restored owner",
       c do
    {_admin, request, _} = approved(c)
    assert {:ok, _} = Authority.pairing_complete(c.authority, request)
    archive = Path.join(c.root, "paired.woh")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Store.export_backup(c.store, archive, key)
    assert {:ok, report} = Backup.verify(archive, key)
    assert report.dependencies.controller_pairing_rows == 1
    refute report.dependencies.pairing_credentials_reissued_on_restore
    destination = Path.join(c.root, "restore.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(archive, key, destination)
    assert {:error, _} = Store.start_link(path: destination)

    with_db(destination, fn database ->
      assert {:ok, [[1]]} = SQL.query(database, "SELECT COUNT(*) FROM controller_pairings")
      assert :ok = Integrity.validate_snapshot(database)
      assert {:ok, %{status: "active"}} = PairingWriter.status(database, lookup(request))
    end)
  end

  test "retirement retains the original pairing while fencing its source authority", c do
    {_admin, request, _} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    assert {:ok, before} = Authority.pairing_client_status(c.authority, lookup(request))
    credential = Base.url_decode64!(response["credential"], padding: false)

    assert {:ok, maintenance, 2} =
             Store.provision_principal(c.store, "maintenance:paired", ["host:maintain"], [])

    assert {:ok, transfer, 3} =
             Store.provision_principal(c.store, "transfer:paired", ["host:transfer"], [])

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, maintenance, 1, "maintenance:paired", 3)

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "retire:paired",
      "expected_revision" => barrier.revision,
      "destination_owner_id" => id(77)
    }

    assert {:ok, _} = Store.retire_controller(c.store, transfer, input)
    assert {:ok, after_retirement} = Authority.pairing_client_status(c.authority, lookup(request))
    assert after_retirement.original == before.original
    assert after_retirement.status == "source_retired"
    assert {:ok, %{writable: false}} = Authority.health(c.authority, credential)
    assert {:error, :source_retired} = Store.controller_identity(c.store, credential)
    assert {:error, :invitation_consumed} = Authority.pairing_complete(c.authority, request)
    assert {:error, :source_retired} = Authority.pairing_open(c.authority, c.template)
    assert :ok = Integrity.validate_snapshot(db(c.store))
  end

  test "SQLite snapshot, standard Store status and original status contain no raw secrets", c do
    {_admin, request, _} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    assert {:ok, original} = Authority.pairing_client_status(c.authority, lookup(request))
    assert {:ok, bytes} = Sqlite3.serialize(db(c.store), "main")
    summaries = :erlang.term_to_binary(original)

    for encoded <- [request["bootstrap_secret"], response["credential"]],
        secret <- [encoded, Base.url_decode64!(encoded, padding: false)] do
      assert :binary.match(bytes, secret) == :nomatch
      assert :binary.match(summaries, secret) == :nomatch
      refute inspect(:sys.get_status(c.store), limit: :infinity) =~ encoded
    end
  end

  test "current permission, grant, verifier and irreversible status damage fail closed", c do
    {_admin, request, _} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    credential = Base.url_decode64!(response["credential"], padding: false)
    principal = response["principal_id"]

    assert {:ok, []} =
             SQL.query(
               db(c.store),
               "UPDATE principals SET credential_hash=? WHERE principal_id=?",
               [:binary.copy(<<7>>, 32), principal]
             )

    assert {:error, :corrupt_controller_pairing} = Integrity.validate_snapshot(db(c.store))

    assert {:ok, []} =
             SQL.query(
               db(c.store),
               "UPDATE principals SET credential_hash=? WHERE principal_id=?",
               [:crypto.hash(:sha256, credential), principal]
             )

    assert {:ok, []} =
             SQL.query(
               db(c.store),
               "UPDATE principals SET permissions='[\"enroll:review\"]' WHERE principal_id=?",
               [principal]
             )

    assert {:error, :corrupt_controller_pairing} =
             Access.authenticate(db(c.store), :crypto.hash(:sha256, credential))

    assert {:ok, []} =
             SQL.query(
               db(c.store),
               "UPDATE principals SET permissions='[\"read\"]' WHERE principal_id=?",
               [principal]
             )

    assert {:ok, _} = Authority.revoke_paired_client(c.authority, lookup(request), 1)

    assert {:ok, []} =
             SQL.query(
               db(c.store),
               "UPDATE principals SET status='active' WHERE principal_id=?",
               [principal]
             )

    assert {:error, :corrupt_controller_pairing} = Authority.health(c.authority, credential)
    refute :sys.get_state(c.store).writable
  end

  test "current grants must follow the latest exact target transition", c do
    thing = thing("light:under_score")
    assert {:ok, 1} = Store.enroll_thing(c.store, thing)
    {_admin, request, _} = approved(c)
    assert {:ok, response} = Authority.pairing_complete(c.authority, request)
    principal = response["principal_id"]
    assert {:ok, _, 3} = Store.grant_target_and_rotate(c.store, principal, thing.id)
    assert {:ok, 4} = Store.revoke_target_grant(c.store, principal, thing.id)

    assert {:ok, []} =
             SQL.query(db(c.store), "INSERT INTO principal_targets VALUES (?,?)", [
               principal,
               thing.id
             ])

    assert {:error, :corrupt_controller_pairing} = Integrity.validate_snapshot(db(c.store))

    assert {:ok, []} =
             SQL.query(db(c.store), "DELETE FROM principal_targets WHERE principal_id=?", [
               principal
             ])

    assert :ok = Integrity.validate_snapshot(db(c.store))
    assert {:ok, _, 5} = Store.grant_target_and_rotate(c.store, principal, thing.id)

    assert {:ok, []} =
             SQL.query(db(c.store), "DELETE FROM principal_targets WHERE principal_id=?", [
               principal
             ])

    assert {:error, :corrupt_controller_pairing} = Integrity.validate_snapshot(db(c.store))
  end

  test "damaged receipt or missing pairing/journal links fail startup and backup", c do
    {_admin, request, _} = approved(c)
    assert {:ok, _} = Authority.pairing_complete(c.authority, request)

    assert {:ok, [[document]]} =
             SQL.query(db(c.store), "SELECT receipt_document FROM controller_pairings")

    assert {:ok, []} =
             SQL.query(db(c.store), "UPDATE controller_pairings SET receipt_document=?", [
               " " <> document
             ])

    assert {:error, :corrupt_controller_pairing} = Integrity.validate_snapshot(db(c.store))

    assert {:error, _} =
             Store.export_backup(
               c.store,
               Path.join(c.root, "damaged.woh"),
               :crypto.strong_rand_bytes(32)
             )

    assert {:ok, []} =
             SQL.query(db(c.store), "UPDATE controller_pairings SET receipt_document=?", [
               document
             ])

    assert {:ok, []} = SQL.query(db(c.store), "DELETE FROM controller_pairings")
    assert {:error, :corrupt_controller_pairing} = Integrity.validate_snapshot(db(c.store))
    GenServer.stop(c.store)

    assert {:error, {:store_open_failed, :corrupt_controller_pairing}} =
             Store.start_link(path: c.path)
  end

  test "historical migration adds no pairing, principal or new authorization", c do
    assert :ok =
             Sqlite3.execute(
               db(c.store),
               "DROP TABLE controller_pairings; PRAGMA user_version=27"
             )

    assert {:ok, _, 1} = Authority.provision_diagnostic(c.authority)
    GenServer.stop(c.store)
    next = start_supervised!({Store, path: c.path}, id: :pairing_migration)
    assert {:ok, [[28]]} = SQL.query(db(next), "PRAGMA user_version")
    assert counts(next) == [1, 0, 1, 0]
    assert :ok = Integrity.validate_snapshot(db(next))
  end

  test "an older namespace collision makes migration roll back before schema publication", c do
    {_admin, _request, approval} = approved(c)

    assert :ok =
             Sqlite3.execute(
               db(c.store),
               "DROP TABLE controller_pairings; PRAGMA user_version=27"
             )

    assert {:ok, []} =
             SQL.query(db(c.store), "INSERT INTO principals VALUES (?,?,'[\"read\"]','active')", [
               ConsumptionCodec.principal(approval),
               :binary.copy(<<7>>, 32)
             ])

    assert {:ok, []} =
             SQL.query(
               db(c.store),
               "INSERT INTO authority_journal VALUES (1,'principal_provisioned',?)",
               [ConsumptionCodec.principal(approval)]
             )

    assert {:ok, []} = SQL.query(db(c.store), "UPDATE meta SET value=1 WHERE key='revision'")
    GenServer.stop(c.store)
    assert {:error, _} = Store.start_link(path: c.path)

    with_db(c.path, fn database ->
      assert {:ok, [[27]]} = SQL.query(database, "PRAGMA user_version")

      assert {:ok, []} =
               SQL.query(
                 database,
                 "SELECT name FROM sqlite_master WHERE name='controller_pairings'"
               )
    end)
  end

  defp approved(c, opts \\ []) do
    assert {:ok, admin, invitation} =
             Authority.pairing_open(
               c.authority,
               c.template,
               Keyword.get(opts, :duration_ms, 300_000)
             )

    request =
      request(invitation)
      |> Map.merge(
        Map.new(Keyword.drop(opts, [:duration_ms, :access]), fn {key, value} ->
          {Atom.to_string(key), value}
        end)
      )

    assert {:ok, ref} = Authority.pairing_prepare(c.authority, admin, request)

    assert {:ok, approval} =
             Authority.pairing_approve(
               c.authority,
               admin,
               ref,
               Keyword.get(opts, :access, Codec.default_access())
             )

    {admin, request, approval}
  end

  defp request(invitation),
    do:
      Peer.request()
      |> Map.merge(Map.take(invitation, ~w(controller_id invitation_id bootstrap_secret)))

  defp lookup(request) do
    {:ok, digest} = Codec.request_digest(request)

    request
    |> Map.take(~w(controller_id invitation_id client_id request_id))
    |> Map.put("request_digest", digest)
  end

  defp id(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp thing(id) do
    {:ok, thing} =
      Thing.new(%{
        "id" => id,
        "role" => "Light",
        "profile_ref" => "fixture:pairing",
        "capabilities" => [
          %{
            "thing_id" => id,
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:pairing",
            "evidence_ref" => "fixture:pairing",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    thing
  end

  defp db(store), do: :sys.get_state(store).db

  defp counts(store) do
    {:ok, [counts]} =
      SQL.query(
        db(store),
        "SELECT (SELECT COUNT(*) FROM principals),(SELECT COUNT(*) FROM controller_pairings),(SELECT COUNT(*) FROM authority_journal),(SELECT COUNT(*) FROM principal_targets)"
      )

    counts
  end

  defp with_db(path, callback) do
    {:ok, database} = Sqlite3.open(path)

    try do
      callback.(database)
    after
      Sqlite3.close(database)
    end
  end
end
