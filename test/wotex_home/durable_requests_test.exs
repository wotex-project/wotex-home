defmodule WotexHome.DurableRequestsTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.{Mutation, Policy}
  alias WotexHome.Durable.{Receipt, Store}
  alias WotexHome.Policy.Context
  alias WotexHome.Semantics.Thing

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

  test "policy-passing request gets a durable held receipt and outbox row", %{path: path} do
    {mutation, thing, context} = request_fixture()
    assert :ok = Policy.check(mutation, thing, context)
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, %Receipt{disposition: :held, reason: nil, revision: 1} = receipt} =
             Store.stage_request(store, "operator:1", mutation, thing, context)

    assert {:ok, ^receipt} = Store.request_status(store, "operator:1", 1, "op:1")
    assert {:ok, 1} = Store.revision(store)
    assert {:ok, ^receipt} = Store.stage_request(store, "operator:1", mutation, thing, context)
    assert {:ok, 1} = Store.revision(store)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [["held"]] = rows(db, "SELECT state FROM request_outbox")
    assert [[1]] = rows(db, "SELECT COUNT(*) FROM request_journal")
    :ok = Sqlite3.close(db)

    assert {:ok, reopened} = Store.start_link(path: path)
    assert {:ok, ^receipt} = Store.request_status(reopened, "operator:1", 1, "op:1")
    assert {:ok, ^receipt} = Store.stage_request(reopened, "operator:1", mutation, thing, context)
    :ok = GenServer.stop(reopened)
  end

  test "operation ID reuse with different content conflicts without another effect row", %{
    path: path
  } do
    {mutation, thing, context} = request_fixture()
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, %Receipt{revision: 1}} =
             Store.stage_request(store, "operator:1", mutation, thing, context)

    changed = %{mutation | value: %{"type" => "boolean", "value" => false}}

    assert {:error, :operation_id_conflict} =
             Store.stage_request(store, "operator:1", changed, thing, context)

    assert {:ok, 1} = Store.revision(store)
    :ok = GenServer.stop(store)
  end

  test "denied request gets a receipt and no outbox row", %{path: path} do
    {mutation, thing, context} = request_fixture()
    assert {:ok, store} = Store.start_link(path: path)
    denied = %{context | permissions: []}

    assert {:ok,
            %Receipt{disposition: :rejected, reason: "permission_denied", revision: 1} = receipt} =
             Store.stage_request(store, "operator:1", mutation, thing, denied)

    assert {:ok, ^receipt} = Store.stage_request(store, "operator:1", mutation, thing, context)
    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM request_outbox")
    :ok = Sqlite3.close(db)
  end

  test "stale ownership epoch and spoofed principal cannot stage device work", %{path: path} do
    {mutation, thing, context} = request_fixture()
    assert {:ok, store} = Store.start_link(path: path)

    assert {:error, :invalid_request} =
             Store.stage_request(store, "other", mutation, thing, context)

    stale = %{mutation | authority_epoch: 2}

    assert {:ok, %Receipt{disposition: :rejected, reason: "stale_authority_epoch"}} =
             Store.stage_request(store, "operator:1", stale, thing, %{
               context
               | authority_epoch: 2
             })

    :ok = GenServer.stop(store)
    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert [[0]] = rows(db, "SELECT COUNT(*) FROM request_outbox")
    :ok = Sqlite3.close(db)
  end

  test "the observation-only schema migrates without losing its revision", %{path: path} do
    assert {:ok, first} = Store.start_link(path: path)
    :ok = GenServer.stop(first)

    assert {:ok, db} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               db,
               "DROP TABLE request_outbox; DROP TABLE request_receipts; DROP TABLE request_journal; DELETE FROM meta WHERE key = 'authority_epoch'; PRAGMA user_version=1"
             )

    :ok = Sqlite3.close(db)

    {mutation, thing, context} = request_fixture()
    assert {:ok, migrated} = Store.start_link(path: path)
    assert {:ok, 0} = Store.revision(migrated)

    assert {:ok, %Receipt{disposition: :held, revision: 1}} =
             Store.stage_request(migrated, "operator:1", mutation, thing, context)

    :ok = GenServer.stop(migrated)
  end

  defp request_fixture do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, mutation} = Mutation.new(@request)

    context = %Context{
      principal_id: "operator:1",
      permissions: ["control:ordinary"],
      allowed_targets: MapSet.new(["light:desk"]),
      authority_epoch: 1,
      resource_revision: 0,
      enrollment_valid: true,
      profile_valid: true,
      invariants: :allow
    }

    {mutation, thing, context}
  end

  defp rows(db, sql) do
    assert {:ok, statement} = Sqlite3.prepare(db, sql)
    assert {:ok, result} = Sqlite3.fetch_all(db, statement)
    assert :ok = Sqlite3.release(db, statement)
    result
  end
end
