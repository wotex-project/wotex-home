defmodule WotexHome.ThingCurrentTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{SQL, ThingReadModel}
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Semantics.{Observation, Thing}

  @power %{
    "thing_id" => "light:inspect",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "fixture:inspection:1",
    "evidence_ref" => "fixture:inspection",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  setup do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "ti-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!({Store, path: path})

    {:ok, thing} =
      Thing.new(%{
        "id" => @power["thing_id"],
        "role" => "Light",
        "profile_ref" => @power["profile_ref"],
        "capabilities" => [@power]
      })

    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, credential, 2} =
      Store.provision_principal(store, "reader:inspection", ["read"], [thing.id])

    {:ok, capability} = Thing.capability(thing, "power")

    %{
      root: root,
      path: path,
      store: store,
      authority: Authority.new(store: store),
      thing: thing,
      capability: capability,
      credential: credential
    }
  end

  test "missing and reported inspection preserve declaration and complete original evidence without writes",
       c do
    assert {:ok, view} = view(c)
    assert view.principal_id == "reader:inspection" and view.resource_revision == 0
    assert view.store_revision == 2 and view.authority_epoch == 1
    assert view.declaration["capabilities"] == [@power]

    assert [
             %{
               freshness: "missing",
               report: nil,
               current_value: nil,
               age_ms: nil,
               remaining_ms: 0,
               profile_status: "usable"
             }
           ] = view.capabilities

    assert {:ok, 3} = Store.record(c.store, report(c), c.capability)
    assert {:ok, current} = view(c)
    assert [entry] = current.capabilities

    assert entry.freshness == "fresh" and
             entry.current_value == %{"type" => "boolean", "value" => true}

    assert entry.remaining_ms in 0..5_000 and entry.age_ms in 0..5_000
    assert entry.report["boot_epoch"] == "adapter:inspection"
    assert entry.report["received_monotonic_ms"] == 999_999_999
    assert entry.report["received_store_boot_epoch"] == current.store_boot_epoch
    assert map_size(entry.report) == 16 and entry.report["revision"] == 3
    assert {:ok, 3} = Store.revision(c.store)
  end

  test "exact receipt-clock boundary excludes future, stale and other boots", c do
    assert {:ok, 3} = Store.record(c.store, report(c), c.capability)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)

    {:ok, [[epoch, received]]} =
      SQL.query(
        db,
        "SELECT received_store_boot_epoch,received_store_monotonic_ms FROM observation_current"
      )

    for {delta, expected} <- [{0, "fresh"}, {1, "fresh"}, {5_000, "fresh"}, {5_001, "stale"}] do
      assert {:ok, %{capabilities: [entry]}} =
               ThingReadModel.read(db, c.credential, c.thing.id, {epoch, received + delta})

      assert entry.freshness == expected
      assert entry.age_ms == delta
      assert entry.remaining_ms == if(expected == "fresh", do: 5_000 - delta, else: 0)
      assert is_nil(entry.current_value) == (expected != "fresh")
    end

    assert {:ok, %{capabilities: [%{freshness: "old_boot", current_value: nil, age_ms: nil}]}} =
             ThingReadModel.read(db, c.credential, c.thing.id, {"store:other", received})

    :ok = Sqlite3.close(db)
  end

  test "synthetic and unknown reports never become a current physical value", c do
    assert {:ok, 3} = Store.record(c.store, %{report(c) | trust: "synthetic_lab"}, c.capability)

    assert {:ok,
            %{
              capabilities: [
                %{
                  freshness: "synthetic",
                  current_value: nil,
                  report: %{"trust" => "synthetic_lab"}
                }
              ]
            }} = view(c)

    assert {:ok, 4} =
             Store.record(
               c.store,
               %{report(c) | source_sequence: 2, quality: "unknown", value: nil},
               c.capability
             )

    assert {:ok,
            %{
              capabilities: [
                %{freshness: "unknown", current_value: nil, report: %{"value" => nil}}
              ]
            }} = view(c)
  end

  test "untimed legacy and future receipts retain evidence without a current value", c do
    assert {:ok, 3} = Store.record(c.store, report(c), c.capability)
    {:ok, db} = Sqlite3.open(c.path)

    for table <- ~w(observation_current journal),
        do: :ok = Sqlite3.execute(db, "UPDATE #{table} SET received_store_monotonic_ms=999999")

    assert {:ok,
            %{
              capabilities: [
                %{freshness: "future", current_value: nil, age_ms: nil, remaining_ms: 0}
              ]
            }} = view(c)

    for table <- ~w(observation_current journal),
        do:
          :ok =
            Sqlite3.execute(
              db,
              "UPDATE #{table} SET received_store_monotonic_ms=NULL,received_store_boot_epoch=NULL"
            )

    assert {:ok,
            %{
              capabilities: [
                %{
                  freshness: "untimed",
                  current_value: nil,
                  age_ms: nil,
                  report: %{"received_store_boot_epoch" => nil}
                }
              ]
            }} = view(c)

    :ok = Sqlite3.close(db)
  end

  test "restart preserves original stored report but cannot renew freshness", c do
    assert {:ok, 3} = Store.record(c.store, report(c), c.capability)
    assert {:ok, before} = view(c)
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, path: c.path})
    assert {:ok, after_restart} = Store.current_thing(store, c.credential, c.thing.id)

    assert [%{freshness: "old_boot", current_value: nil, report: report}] =
             after_restart.capabilities

    assert report == hd(before.capabilities).report
    assert {:duplicate, 3} = Store.record(store, report(c), c.capability)

    assert {:ok, %{capabilities: [%{freshness: "old_boot"}]}} =
             Store.current_thing(store, c.credential, c.thing.id)

    assert {:ok, 3} = Store.revision(store)
  end

  test "current permissions and grant are required before source disclosure", c do
    assert {:error, :permission_denied} =
             Store.current_thing(c.store, c.credential, "light:other")

    assert {:ok, reviewer, 3} =
             Store.provision_principal(c.store, "reviewer:inspection", ["rule:review"], [
               c.thing.id
             ])

    assert {:error, :permission_denied} = Store.current_thing(c.store, reviewer, c.thing.id)
    assert {:ok, 4} = Store.revoke_target_grant(c.store, "reader:inspection", c.thing.id)
    assert {:error, :permission_denied} = view(c)
    assert {:ok, 5} = Store.revoke_principal(c.store, "reader:inspection")
    assert {:error, :unauthorized} = view(c)
  end

  test "strict framed route refuses supplied time or evidence and uses the same scoped read", c do
    socket = Path.join(c.root, "api.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})

    request = %{
      "api_version" => 1,
      "operation" => "thing_current",
      "credential" => Base.url_encode64(c.credential, padding: false),
      "thing_id" => c.thing.id
    }

    assert %{
             "outcome" => "ok",
             "thing_current" => %{
               "format" => "wotex-home.thing-current.v1",
               "principal_id" => "reader:inspection"
             }
           } = framed(socket, request)

    for key <- ~w(store_boot_epoch sampled_monotonic_ms report endpoint principal_id) do
      assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
               framed(socket, Map.put(request, key, 1))
    end

    assert {:ok, 2} = Store.revision(c.store)
  end

  for {name, sql} <- [
        {"missing journal", "DELETE FROM journal WHERE event_type='observation'"},
        {"changed sequence",
         "UPDATE journal SET source_sequence=2 WHERE event_type='observation'"},
        {"changed clock", "UPDATE observation_current SET received_store_monotonic_ms=999999"},
        {"changed value", "UPDATE observation_current SET value_a='0'"}
      ] do
    @sql sql
    test "#{name} refuses inspection and disables writes", c do
      assert {:ok, 3} = Store.record(c.store, report(c), c.capability)
      {:ok, db} = Sqlite3.open(c.path)
      :ok = Sqlite3.execute(db, @sql)
      assert {:error, :corrupt_value} = view(c)
      assert {:ok, %{writable: false}} = Store.health(c.store)
      assert {:error, :store_unavailable} = view(c)
      :ok = Sqlite3.close(db)
    end
  end

  defp view(c), do: Authority.current_thing(c.authority, c.credential, c.thing.id)

  defp framed(socket, request) do
    {:ok, result} = Client.request(socket, request)
    result
  end

  defp report(c) do
    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => c.thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => true},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "source:inspection",
          "source_sequence" => 1,
          "boot_epoch" => "adapter:inspection",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_700_000_000_000,
          "received_monotonic_ms" => 999_999_999
        },
        c.capability
      )

    report
  end
end
