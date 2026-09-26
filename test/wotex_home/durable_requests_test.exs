defmodule WotexHome.DurableRequestsTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Mutation
  alias WotexHome.Durable.{Receipt, Store}
  alias WotexHome.Semantics.Thing

  @wrong_credential :binary.copy(<<2>>, 32)

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @request %{
    "api_version" => 1,
    "operation_id" => "op:1",
    "authority_epoch" => 1,
    "expected_revision" => 0,
    "target_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => true}
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-requests-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = Path.join(directory, "home.sqlite")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: path}
  end

  test "persisted enrollment and grants yield a held receipt across restart", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(@request)

    assert {:ok, %Receipt{disposition: :held, reason: nil, revision: 3} = receipt} =
             Store.submit_request(store, credential, mutation)

    assert {:ok,
            %{
              store_revision: 3,
              authority_epoch: 1,
              held_requests: 1,
              active_things: 1,
              active_principals: 1,
              writable: true,
              dispatch_enabled: false
            }} = Store.health(store)

    assert {:ok, ^receipt} = Store.request_status(store, credential, 1, "op:1")
    assert {:ok, 3} = Store.revision(store)
    assert {:ok, ^receipt} = Store.submit_request(store, credential, mutation)
    assert {:ok, 3} = Store.revision(store)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [["held"]] = rows(db, "SELECT state FROM request_outbox")
    assert [[1]] = rows(db, "SELECT COUNT(*) FROM request_journal")
    :ok = Sqlite3.close(db)

    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, %{held_requests: 1, dispatch_enabled: false}} = Store.health(reopened)
    assert {:ok, ^receipt} = Store.request_status(reopened, credential, 1, "op:1")
    assert {:ok, ^receipt} = Store.submit_request(reopened, credential, mutation)
    :ok = GenServer.stop(reopened)
  end

  test "authenticated cancellation atomically withdraws held work and keeps retry identity", %{
    path: path
  } do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(@request)

    assert {:ok, %Receipt{disposition: :held, revision: 3}} =
             Store.submit_request(store, credential, mutation)

    assert {:error, :unauthorized} =
             Store.cancel_request(store, @wrong_credential, 1, "op:1")

    assert :not_found = Store.cancel_request(store, credential, 1, "op:missing")
    assert {:ok, 3} = Store.revision(store)

    assert {:ok, %Receipt{disposition: :rejected, reason: "cancelled", revision: 4} = cancelled} =
             Store.cancel_request(store, credential, 1, "op:1")

    assert {:ok, ^cancelled} = Store.cancel_request(store, credential, 1, "op:1")
    assert {:ok, ^cancelled} = Store.request_status(store, credential, 1, "op:1")
    assert {:ok, ^cancelled} = Store.submit_request(store, credential, mutation)

    assert {:error, :operation_id_conflict} =
             Store.submit_request(store, credential, %{
               mutation
               | value: %{"type" => "boolean", "value" => false}
             })

    assert {:ok, %{held_requests: 0}} = Store.health(store)
    assert {:ok, 4} = Store.revision(store)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM request_outbox")

    assert [["held"], ["rejected"]] =
             rows(db, "SELECT disposition FROM request_journal ORDER BY revision")

    :ok = Sqlite3.close(db)
    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, ^cancelled} = Store.request_status(reopened, credential, 1, "op:1")
    :ok = GenServer.stop(reopened)
  end

  test "startup refuses a held receipt whose outbox row was lost", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(@request)
    assert {:ok, %Receipt{disposition: :held}} = Store.submit_request(store, credential, mutation)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(db, "DELETE FROM request_outbox")
    assert :ok = Sqlite3.close(db)

    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, {:schema_inconsistent, false}}} =
             Store.start_link(path: path)
  end

  test "credentials are required and cannot read another principal's receipt", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(@request)
    assert {:error, :unauthorized} = Store.submit_request(store, @wrong_credential, mutation)
    assert {:ok, %Receipt{}} = Store.submit_request(store, credential, mutation)
    assert {:error, :unauthorized} = Store.request_status(store, @wrong_credential, 1, "op:1")
    :ok = GenServer.stop(store)
  end

  test "read-only principal receives a rejection and revocation cuts off receipts", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "observer:1", ["read"], ["light:desk"])

    assert {:ok, mutation} = Mutation.new(@request)

    assert {:ok, %Receipt{disposition: :rejected, reason: "permission_denied"}} =
             Store.submit_request(store, credential, mutation)

    assert {:ok, 4} = Store.revoke_principal(store, "observer:1")
    assert {:error, :unauthorized} = Store.submit_request(store, credential, mutation)
    assert {:error, :unauthorized} = Store.request_status(store, credential, 1, "op:1")
    :ok = GenServer.stop(store)
  end

  test "combined control and review grants preserve both permissions", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(
               store,
               "operator:1",
               ["control:ordinary", "rule:review"],
               ["light:desk"]
             )

    assert {:ok, scoped, 2} = Store.review_inputs(store, credential)
    assert Map.keys(scoped) == ["light:desk"]
    assert {:ok, mutation} = Mutation.new(@request)
    assert {:ok, %Receipt{disposition: :held}} = Store.submit_request(store, credential, mutation)
    :ok = GenServer.stop(store)
  end

  test "malformed provisioning and duplicate principal are rejected without changing revision", %{
    path: path
  } do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:error, :invalid_provisioning} =
             Store.provision_principal(store, "operator:1", ["admin"], ["light:desk"])

    assert {:error, :invalid_provisioning} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], [
               "light:desk",
               "light:desk"
             ])

    assert {:error, :target_unavailable} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:hall"])

    assert {:ok, _credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:desk"])

    assert {:error, :principal_exists} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:desk"])

    assert {:ok, 2} = Store.revision(store)
    :ok = GenServer.stop(store)
  end

  test "operation ID reuse with changed content conflicts", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(@request)
    assert {:ok, %Receipt{revision: 3}} = Store.submit_request(store, credential, mutation)
    changed = %{mutation | value: %{"type" => "boolean", "value" => false}}
    assert {:error, :operation_id_conflict} = Store.submit_request(store, credential, changed)
    assert {:ok, 3} = Store.revision(store)
    :ok = GenServer.stop(store)
  end

  test "stale resource revision has a rejected receipt and no effect row", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(%{@request | "expected_revision" => 1})

    assert {:ok,
            %Receipt{disposition: :rejected, reason: "stale_resource_revision", revision: 3} =
              receipt} = Store.submit_request(store, credential, mutation)

    assert {:ok, ^receipt} = Store.submit_request(store, credential, mutation)
    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM request_outbox")
    :ok = Sqlite3.close(db)
  end

  test "wrong authority epoch is rejected from persisted ownership state", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, mutation} = Mutation.new(%{@request | "authority_epoch" => 2})

    assert {:ok, %Receipt{disposition: :rejected, reason: "stale_authority_epoch"}} =
             Store.submit_request(store, credential, mutation)

    :ok = GenServer.stop(store)
  end

  test "a principal's persisted target grant restricts staging", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    assert {:ok, desk} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, desk)
    assert {:ok, hall} = thing("light:hall")
    assert {:ok, 2} = Store.enroll_thing(store, hall)

    assert {:ok, credential, 3} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:hall"])

    assert {:ok, mutation} = Mutation.new(@request)

    assert {:ok, %Receipt{disposition: :rejected, reason: "target_unavailable"}} =
             Store.submit_request(store, credential, mutation)

    :ok = GenServer.stop(store)
  end

  test "revoked enrollment cannot stage new work even with an old grant", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, 3} = Store.revoke_thing(store, "light:desk")
    assert {:ok, mutation} = Mutation.new(@request)
    assert {:error, :target_unavailable} = Store.submit_request(store, credential, mutation)
    assert {:ok, 3} = Store.revision(store)
    :ok = GenServer.stop(store)
  end

  test "a principal cannot accumulate more than 32 held requests", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)

    for index <- 1..32 do
      assert {:ok, mutation} =
               Mutation.new(%{@request | "operation_id" => "op:#{index}"})

      assert {:ok, %Receipt{disposition: :held}} =
               Store.submit_request(store, credential, mutation)
    end

    assert {:ok, overflow} = Mutation.new(%{@request | "operation_id" => "op:33"})

    assert {:ok, %Receipt{disposition: :rejected, reason: "pending_capacity"} = receipt} =
             Store.submit_request(store, credential, overflow)

    assert {:ok, ^receipt} = Store.submit_request(store, credential, overflow)
    assert {:ok, %{held_requests: 32, store_revision: 35}} = Store.health(store)

    assert {:ok, %Receipt{reason: "cancelled", revision: 36}} =
             Store.cancel_request(store, credential, 1, "op:1")

    assert {:ok, replacement} = Mutation.new(%{@request | "operation_id" => "op:34"})

    assert {:ok, %Receipt{disposition: :held, revision: 37}} =
             Store.submit_request(store, credential, replacement)

    assert {:ok, ^receipt} = Store.submit_request(store, credential, overflow)
    assert {:ok, %{held_requests: 32, store_revision: 37}} = Store.health(store)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[32]] = rows(db, "SELECT COUNT(*) FROM request_outbox")

    assert [[1]] =
             rows(db, "SELECT COUNT(*) FROM request_receipts WHERE reason = 'pending_capacity'")

    :ok = Sqlite3.close(db)
  end

  test "corrupt persisted enrollment fails closed", %{path: path} do
    assert {:ok, store} = Store.start_link(path: path)
    credential = provision!(store)
    assert {:ok, db} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(db, "UPDATE enrolled_things SET document = '{}' ")
    assert :ok = Sqlite3.close(db)
    assert {:ok, mutation} = Mutation.new(@request)
    assert {:error, :corrupt_enrollment} = Store.submit_request(store, credential, mutation)
    assert {:error, :store_unavailable} = Store.submit_request(store, credential, mutation)
    :ok = GenServer.stop(store)
  end

  test "observation-only schema migrates into the authority registry", %{path: path} do
    assert {:ok, first} = Store.start_link(path: path)
    :ok = GenServer.stop(first)
    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "DROP TABLE principal_targets; DROP TABLE principals; DROP TABLE enrolled_things; DROP TABLE authority_journal; DROP TABLE request_outbox; DROP TABLE request_receipts; DROP TABLE request_journal; DELETE FROM meta WHERE key = 'authority_epoch'; PRAGMA user_version=1"
             )

    :ok = Sqlite3.close(db)
    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, 0} = Store.revision(migrated)
    provision!(migrated)
    :ok = GenServer.stop(migrated)
  end

  defp provision!(store) do
    assert {:ok, thing} = thing()
    assert {:ok, 1} = Store.enroll_thing(store, thing)

    assert {:ok, credential, 2} =
             Store.provision_principal(store, "operator:1", ["control:ordinary"], ["light:desk"])

    credential
  end

  defp thing(id \\ "light:desk") do
    Thing.new(%{
      "id" => id,
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [%{@power | "thing_id" => id}]
    })
  end

  defp rows(db, sql) do
    assert {:ok, statement} = Sqlite3.prepare(db, sql)
    assert {:ok, result} = Sqlite3.fetch_all(db, statement)
    assert :ok = Sqlite3.release(db, statement)
    result
  end
end
