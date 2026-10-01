defmodule WotexHome.DurableMaintenanceTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.{Authority, CLI}
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Semantics.{Observation, Thing}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "home-maintenance-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:maintenance",
        "role" => "Light",
        "profile_ref" => "fixture:maintenance:1",
        "capabilities" => [
          %{
            "thing_id" => "light:maintenance",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:maintenance:1",
            "evidence_ref" => "fixture:maintenance",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, 1} = Store.enroll_thing(store, thing)
    {:ok, manager, 2} = Store.provision_principal(store, "maintainer:1", ["host:maintain"], [])

    {:ok, control, 3} =
      Store.provision_principal(store, "operator:1", ["read", "control:ordinary"], [thing.id])

    %{
      store: store,
      authority: Authority.new(store: store),
      directory: directory,
      path: path,
      thing: thing,
      manager: manager,
      control: control
    }
  end

  test "trusted maintenance provisioning is one-time and grants no device control", c do
    assert {:ok, credential, 4} = Authority.provision_maintenance(c.authority)
    assert {:error, :principal_exists} = Authority.provision_maintenance(c.authority)

    assert {:ok, %{disposition: :rejected, reason: "target_unavailable"}} =
             Authority.submit(c.authority, credential, mutation(c, "power:denied"))

    assert {:ok, %{state: :normal, store_revision: 5}} =
             Authority.maintenance_status(c.authority, credential)

    assert {:ok, _} = Authority.begin_maintenance(c.authority, credential, 1, "maint:local", 5)
  end

  test "maintenance requires its own permission and exact epoch/watermark", c do
    assert {:error, :permission_denied} =
             Authority.begin_maintenance(c.authority, c.control, 1, "maint:1", 3)

    assert {:error, :stale_authority_epoch} = begin(c, 2, "maint:1", 3)
    assert {:error, :resnapshot_required} = begin(c, 1, "maint:1", 2)
    assert {:error, :invalid_maintenance_operation} = begin(c, true, "maint:1", 3)
    assert {:error, :invalid_maintenance_operation} = begin(c, 1, "bad id", 3)
    assert {:error, :invalid_maintenance_operation} = begin(c, 1, "maint:1", 3.0)
    assert {:ok, 3} = Store.revision(c.store)

    assert {:ok, %{state: :normal, begin_revision: 0}} =
             Authority.maintenance_status(c.authority, c.manager)
  end

  test "begin rejects held work atomically, retains original identity and survives restart", c do
    mutation = mutation(c, "power:1")

    assert {:ok, %{disposition: :held, revision: 4}} =
             Authority.submit(c.authority, c.control, mutation)

    assert {:ok, receipt} = begin(c, 1, "maint:1", 4)
    assert receipt.revision == 7 and receipt.begin_revision == 7

    assert receipt.affected_requests == 1 and receipt.unknown_outcomes == 0 and
             receipt.rule_generation == 1

    assert {:ok, ^receipt} = begin(c, 1, "maint:1", 4)
    assert {:error, :maintenance_operation_conflict} = begin(c, 1, "maint:1", 7)
    assert {:error, :maintenance_active} = begin(c, 1, "maint:2", 7)

    assert {:ok, %{disposition: :rejected, reason: "rule_generation_fenced"} = cancelled} =
             Authority.submit(c.authority, c.control, mutation)

    assert {:error, :maintenance_active} =
             Authority.submit(c.authority, c.control, mutation(c, "power:2"))

    assert :not_found = Authority.request_status(c.authority, c.control, 1, "power:2")
    assert {:ok, 7} = Store.revision(c.store)
    assert :ok = integrity(c.path)
    :ok = GenServer.stop(c.store)
    store = start_supervised!({Store, path: c.path}, id: :restarted)
    authority = Authority.new(store: store)

    assert {:ok, %{state: :maintenance, begin_revision: 7}} =
             Authority.maintenance_status(authority, c.manager)

    assert {:ok, ^receipt} = Authority.begin_maintenance(authority, c.manager, 1, "maint:1", 4)
    assert {:ok, ^cancelled} = Authority.submit(authority, c.control, mutation)

    assert {:error, :maintenance_active} =
             Authority.submit(authority, c.control, mutation(c, "power:2"))

    assert {:ok, %{writable: true, held_requests: 0}} = Store.health(store)
  end

  test "ending maintenance is explicit revision fenced and never reactivates a rule", c do
    {:ok, receipt} = begin(c, 1, "maint:1", 3)
    assert {:error, :resnapshot_required} = finish(c, "end:1", 3, receipt.revision)
    assert {:error, :maintenance_changed} = finish(c, "end:1", receipt.revision, 1)
    assert {:error, :invalid_maintenance_operation} = finish(c, "end:1", receipt.revision, 0)
    assert {:ok, ending} = finish(c, "end:1", receipt.revision, receipt.revision)
    assert ending.state == :normal and ending.revision == 6 and ending.rule_generation == 1
    assert {:ok, ^ending} = finish(c, "end:1", receipt.revision, receipt.revision)

    assert {:ok, %{state: :normal, begin_revision: 0}} =
             Authority.maintenance_status(c.authority, c.manager)

    assert {:ok, %{disposition: :held}} =
             Authority.submit(c.authority, c.control, mutation(c, "power:after"))

    assert {:ok, db} = Sqlite3.open(c.path, mode: :readonly)

    assert {:ok, [[0]]} =
             SQL.query(db, "SELECT value FROM meta WHERE key='active_rule_admission'")

    assert :ok = Sqlite3.close(db)
    assert :ok = integrity(c.path)
  end

  test "maintenance blocks fresh rule admission, activation and invocation", c do
    {:ok, manager, revision} =
      Store.provision_principal(
        c.store,
        "manager:rule",
        ["rule:manage", "rule:review", "control:ordinary"],
        [c.thing.id]
      )

    source = rule(c)

    {:ok, admitted} =
      Authority.admit_rule(c.authority, manager, 1, "admission:1", revision, [source])

    {:ok, barrier} = begin(c, 1, "maint:1", admitted.revision)

    assert {:error, :maintenance_active} =
             Authority.admit_rule(c.authority, manager, 1, "admission:2", barrier.revision, [
               source
             ])

    assert {:error, :maintenance_active} =
             Authority.activate_rule(
               c.authority,
               manager,
               1,
               "activate:1",
               barrier.revision,
               admitted.revision
             )

    assert {:error, :maintenance_active} =
             Authority.invoke_rule(
               c.authority,
               c.control,
               1,
               "invoke:1",
               barrier.rule_generation,
               source["id"]
             )

    assert {:ok, _} =
             Authority.suspend_rules(c.authority, manager, 1, "suspend:1", barrier.revision)

    assert {:ok, %{state: :maintenance}} = Authority.maintenance_status(c.authority, c.manager)
    assert :ok = integrity(c.path)
  end

  test "a forged unknown count cannot change a historical barrier result", c do
    {:ok, _} = Authority.submit(c.authority, c.control, mutation(c, "power:1"))
    {:ok, _} = begin(c, 1, "maint:1", 4)
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "UPDATE host_maintenance_operations SET unknown_outcomes=1")
    :ok = Sqlite3.close(db)
    assert {:error, :corrupt_maintenance} = Authority.maintenance_status(c.authority, c.manager)
    assert {:ok, %{writable: false}} = Store.health(c.store)
  end

  test "observations, read views and encrypted backup continue while new work is blocked", c do
    {:ok, receipt} = begin(c, 1, "maint:1", 3)
    capability = c.thing.capabilities["power"]

    {:ok, report} =
      Observation.new(
        %{
          "thing_id" => c.thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "source:1",
          "source_sequence" => 1,
          "boot_epoch" => "adapter:1",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1,
          "received_monotonic_ms" => 0
        },
        capability
      )

    assert {:ok, 6} = Store.record(c.store, report, capability)
    assert {:ok, %{store_revision: 6}} = Authority.health(c.authority, c.control)
    archive = Path.join(c.directory, "maintenance.backup")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Store.export_backup(c.store, archive, key)

    assert {:ok,
            %{dependencies: %{host_maintenance_operation_rows: 1, host_maintenance_active: true}}} =
             Backup.verify(archive, key)

    destination = Path.join(c.directory, "staged.sqlite")
    assert {:ok, %{quarantined: true}} = Backup.stage_restore(archive, key, destination)
    assert :ok = integrity(destination)
    assert {:error, :resnapshot_required} = finish(c, "end:1", receipt.revision, receipt.revision)
    assert {:ok, _} = finish(c, "end:1", 6, receipt.revision)
  end

  test "another current maintainer can end the barrier but cannot read its private receipt", c do
    {:ok, receipt} = begin(c, 1, "maint:1", 3)

    {:ok, other, revision} =
      Store.provision_principal(c.store, "maintainer:2", ["host:maintain"], [])

    assert :not_found = Authority.maintenance_operation_status(c.authority, other, 1, "maint:1")
    assert {:ok, _} = Store.revoke_principal(c.store, "maintainer:1")

    assert {:error, :unauthorized} =
             Authority.maintenance_operation_status(c.authority, c.manager, 1, "maint:1")

    assert {:ok, _} =
             Authority.end_maintenance(
               c.authority,
               other,
               1,
               "end:2",
               revision + 1,
               receipt.revision
             )

    assert :ok = integrity(c.path)
  end

  test "a failed transaction cannot leave a partial fence or refund a request", c do
    {:ok, original} = Authority.submit(c.authority, c.control, mutation(c, "power:1"))
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TRIGGER fail_maintenance BEFORE INSERT ON host_maintenance_operations BEGIN SELECT RAISE(ABORT, 'fixture failure'); END"
      )

    assert {:error, :store_unavailable} = begin(c, 1, "maint:1", 4)
    assert {:ok, 4} = Store.revision(c.store)
    assert {:ok, ^original} = Authority.request_status(c.authority, c.control, 1, "power:1")

    assert {:ok, [[0], [0]]} =
             SQL.query(
               db,
               "SELECT value FROM meta WHERE key IN ('maintenance_revision', 'rule_generation') ORDER BY key"
             )

    :ok = Sqlite3.execute(db, "DROP TRIGGER fail_maintenance")
    :ok = Sqlite3.close(db)
    assert :ok = integrity(c.path)
    :ok = GenServer.stop(c.store)
    store = start_supervised!({Store, path: c.path}, id: :retry)

    assert {:ok, %{affected_requests: 1}} =
             Store.begin_maintenance(store, c.manager, 1, "maint:1", 4)
  end

  @tag :requires_socket
  test "CLI and real framed authority agree on begin, status, lookup and end", c do
    socket = Path.join(c.directory, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    encoded = Base.url_encode64(c.manager, padding: false)
    {:ok, request} = CLI.build_request(["maintenance-begin", "1", "maint:1", "3"], encoded)

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             Server.route(c.authority, Map.put(request, "path", c.path))

    assert {:ok,
            %{
              "outcome" => "ok",
              "maintenance_receipt" => %{"revision" => 5, "state" => "maintenance"}
            }} = Client.request(socket, request)

    {:ok, request} = CLI.build_request(["maintenance-status"], encoded)

    assert {:ok, %{"maintenance_status" => %{"begin_revision" => 5, "state" => "maintenance"}}} =
             Client.request(socket, request)

    {:ok, request} = CLI.build_request(["maintenance-operation-status", "1", "maint:1"], encoded)

    assert {:ok, %{"maintenance_receipt" => %{"operation_id" => "maint:1", "action" => "begin"}}} =
             Client.request(socket, request)

    {:ok, request} = CLI.build_request(["maintenance-end", "1", "end:1", "5", "5"], encoded)

    assert {:ok, %{"maintenance_receipt" => %{"revision" => 6, "state" => "normal"}}} =
             Client.request(socket, request)
  end

  for {name, sql} <- [
        {"cleared marker", "UPDATE meta SET value=0 WHERE key='maintenance_revision'"},
        {"removed receipt", "DELETE FROM host_maintenance_operations"},
        {"wrong journal identity",
         "UPDATE authority_journal SET entity_id='host:forged' WHERE event_type='host_maintenance_started'"},
        {"wrong fence", "UPDATE host_maintenance_operations SET fence_revision=1"},
        {"wrong outcome counts",
         "UPDATE host_maintenance_operations SET unknown_outcomes=1, affected_requests=1"}
      ] do
    @sql sql
    test "#{name} disables new work, backup verification and startup", c do
      {:ok, _} = begin(c, 1, "maint:1", 3)
      {:ok, db} = Sqlite3.open(c.path)
      :ok = Sqlite3.execute(db, @sql)

      assert {:error, :corrupt_maintenance} =
               Authority.submit(c.authority, c.control, mutation(c, "power:1"))

      assert {:ok, %{writable: false}} = Store.health(c.store)
      assert {:error, _} = Integrity.validate_snapshot(db)
      archive = Path.join(c.directory, "invalid.backup")
      key = :crypto.strong_rand_bytes(32)
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(c.store)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  test "version seventeen migrates normally and historical backup needs no maintenance table",
       c do
    {:ok, original} = Authority.submit(c.authority, c.control, mutation(c, "power:1"))
    :ok = GenServer.stop(c.store)
    {:ok, db} = Sqlite3.open(c.path)

    :ok =
      Sqlite3.execute(
        db,
        "DROP TABLE host_maintenance_operations; DELETE FROM meta WHERE key='maintenance_revision'; PRAGMA user_version=17"
      )

    assert :ok = Integrity.validate_snapshot(db)
    archive = Path.join(c.directory, "v17.backup")
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Backup.export(db, archive, key)

    assert {:ok,
            %{dependencies: %{host_maintenance_operation_rows: 0, host_maintenance_active: false}}} =
             Backup.verify(archive, key)

    :ok = Sqlite3.close(db)
    store = start_supervised!({Store, path: c.path}, id: :migrated)
    assert {:ok, ^original} = Store.request_status(store, c.control, 1, "power:1")
    assert {:ok, 4} = Store.revision(store)
    assert {:ok, %{state: :normal}} = Store.maintenance_status(store, c.manager)
    assert :ok = integrity(c.path)
  end

  defp begin(c, epoch, operation, revision),
    do: Authority.begin_maintenance(c.authority, c.manager, epoch, operation, revision)

  defp finish(c, operation, revision, begin_revision),
    do: Authority.end_maintenance(c.authority, c.manager, 1, operation, revision, begin_revision)

  defp mutation(c, operation) do
    %{
      "api_version" => 1,
      "authority_epoch" => 1,
      "operation_id" => operation,
      "expected_revision" => 0,
      "target_id" => c.thing.id,
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    }
  end

  defp rule(c),
    do: %{
      "version" => 1,
      "id" => "rule:maintenance",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => c.thing.id,
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => 1,
      "cooldown_ms" => 0,
      "causal_budget" => 1
    }

  defp integrity(path) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      Integrity.validate_snapshot(db)
    after
      Sqlite3.close(db)
    end
  end
end
