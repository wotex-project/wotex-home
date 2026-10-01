defmodule WotexHome.DurableRuleActivationTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Authority
  alias WotexHome.CLI
  alias WotexHome.Durable.{Backup, Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Rules.AdmissionArtifact
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Semantics.Thing

  setup do
    directory =
      Path.join(System.tmp_dir!(), "home-rule-activation-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))
    {:ok, thing} = thing()
    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, manager, 2} =
      Store.provision_principal(
        store,
        "manager:1",
        ["rule:review", "rule:manage", "control:ordinary"],
        [thing.id]
      )

    {:ok, control, 3} =
      Store.provision_principal(store, "operator:1", ["control:ordinary"], [thing.id])

    %{
      store: store,
      authority: Authority.new(store: store),
      path: path,
      directory: directory,
      manager: manager,
      control: control,
      thing: thing
    }
  end

  test "a closed restricted artifact becomes active only through epoch/revision CAS", c do
    assert {:ok, admission} = admit(c, "admission:1", 3)
    assert admission.state == :admitted and admission.revision == 4
    assert {:ok, ^admission} = admit(c, "admission:1", 3)

    assert {:ok, %{state: :inactive, rule_generation: 0}} =
             Authority.rule_status(c.authority, c.manager)

    assert {:error, :resnapshot_required} = activate(c, "activation:1", 3, 4)
    assert {:ok, active} = activate(c, "activation:1", 4, 4)
    assert active.state == :active and active.rule_generation == 1 and active.store_revision == 5
    assert {:ok, ^active} = activate(c, "activation:1", 4, 4)
    assert {:error, :rule_operation_conflict} = activate(c, "activation:1", 4, 0)

    assert {:ok, %{authority_epoch: 1, rule_generation: 1, admission_revision: 4}} =
             Authority.rule_status(c.authority, c.manager)

    assert :ok = integrity(c.path)

    assert {:ok, %{kind: :admission, revision: 4}} =
             Authority.rule_operation_status(c.authority, c.manager, 1, "admission:1")

    assert {:ok, %{kind: :activation, rule_generation: 1}} =
             Authority.rule_operation_status(c.authority, c.manager, 1, "activation:1")

    assert :not_found = Authority.rule_operation_status(c.authority, c.manager, 1, "missing:1")
    assert {:error, :rule_operation_conflict} = activate(c, "admission:1", 5, 0)
  end

  test "framed and CLI operations share the authenticated lifecycle and closed fields", c do
    encoded = Base.url_encode64(c.manager, padding: false)
    rules = Path.join(c.directory, "rules.json")
    File.write!(rules, JSON.encode!(%{"rules" => [rule()]}))
    File.chmod!(rules, 0o600)
    {:ok, admit} = CLI.build_request(["admit-rule", "1", "admission:1", "3", rules], encoded)

    assert %{"outcome" => "error", "reason" => "unsupported_operation_or_fields"} =
             Server.route(
               c.authority,
               Map.put(admit, "runtime_digest", String.duplicate("0", 64))
             )

    assert %{"outcome" => "ok", "rule_receipt" => %{"state" => "admitted", "revision" => 4}} =
             framed(c.authority, admit)

    {:ok, activate} = CLI.build_request(["activate-rule", "1", "activation:1", "4", "4"], encoded)

    assert %{"outcome" => "ok", "rule_receipt" => %{"state" => "active", "rule_generation" => 1}} =
             framed(c.authority, activate)

    {:ok, invoke} =
      CLI.build_request(
        ["invoke-rule", "1", "request:1", "1", "rule:explicit"],
        Base.url_encode64(c.control, padding: false)
      )

    assert %{"outcome" => "ok", "receipt" => %{"disposition" => "held"}} =
             framed(c.authority, invoke)

    {:ok, status} = CLI.build_request(["rule-operation-status", "1", "activation:1"], encoded)

    assert %{
             "outcome" => "ok",
             "rule_receipt" => %{"kind" => "activation", "rule_generation" => 1}
           } = framed(c.authority, status)

    {:ok, status} = CLI.build_request(["rule-status"], encoded)

    assert %{"outcome" => "ok", "rule_status" => %{"state" => "active"}} =
             framed(c.authority, status)

    for command <- [
          ["invoke-rule", "1", "request:1", "1", "bad id"],
          ["activate-rule", "1", "activation:1", "-1", "4"]
        ],
        do: assert({:error, _reason} = CLI.build_request(command, encoded))
  end

  @tag :requires_socket
  test "the real private socket returns the same admission, activation and operation receipts",
       c do
    socket = Path.join(c.directory, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})
    encoded = Base.url_encode64(c.manager, padding: false)

    request = %{
      "api_version" => 1,
      "operation" => "admit_rule",
      "credential" => encoded,
      "authority_epoch" => 1,
      "operation_id" => "admission:1",
      "expected_revision" => 3,
      "rules" => [rule()]
    }

    assert {:ok, %{"outcome" => "ok", "rule_receipt" => %{"revision" => 4}}} =
             Client.request(socket, request)

    request = %{
      "api_version" => 1,
      "operation" => "activate_rule",
      "credential" => encoded,
      "authority_epoch" => 1,
      "operation_id" => "activation:1",
      "expected_revision" => 4,
      "admission_revision" => 4
    }

    assert {:ok, %{"outcome" => "ok", "rule_receipt" => %{"rule_generation" => 1}}} =
             Client.request(socket, request)

    assert {:ok, %{"outcome" => "ok", "rule_receipt" => %{"kind" => "activation"}}} =
             Client.request(
               socket,
               Map.take(request, ["api_version", "credential", "authority_epoch", "operation_id"])
               |> Map.put("operation", "rule_operation_status")
             )
  end

  test "review/control permissions do not imply management or activation", c do
    assert {:error, :permission_denied} =
             Authority.admit_rule(c.authority, c.control, 1, "admission:1", 3, [rule()])

    assert {:error, :permission_denied} =
             Authority.activate_rule(c.authority, c.control, 1, "activation:1", 3, 0)

    {:ok, reviewer, _} =
      Store.provision_principal(c.store, "reviewer:1", ["rule:review"], [c.thing.id])

    assert {:error, :permission_denied} =
             Authority.admit_rule(c.authority, reviewer, 1, "admission:1", 4, [rule()])
  end

  test "unsupported grammar and ownership semantics remain inactive", c do
    for bad <- [
          put_in(rule()["cooldown_ms"], 1),
          put_in(rule()["causal_budget"], 2),
          put_in(rule()["ownership_ms"], 2),
          put_in(rule()["predicate"], %{"op" => "not", "predicate" => %{"op" => "literal_true"}})
        ] do
      assert {:error, :unsupported_admission_profile} =
               Authority.admit_rule(c.authority, c.manager, 1, "admission:1", 3, [bad])
    end

    assert {:ok, 3} = Store.revision(c.store)

    assert {:error, :unsupported_admission_profile} =
             Authority.admit_rule(c.authority, c.manager, 1, "admission:1", 3, [
               rule(),
               Map.put(rule(), "id", "rule:other")
             ])

    assert {:ok, %{rule_generation: 0, dispatch_enabled: false, writable: true}} =
             Store.health(c.store)
  end

  test "explicit invocation is a held immutable request with a single durable root", c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)
    assert {:error, :stale_rule_generation} = invoke(c, "request:1", 0)

    assert {:error, :rule_inactive} =
             Authority.invoke_rule(c.authority, c.control, 1, "request:1", 1, "rule:other")

    assert {:ok, receipt} = invoke(c, "request:1", 1)
    assert receipt.disposition == :held and receipt.revision == 6
    assert {:ok, ^receipt} = invoke(c, "request:1", 1)
    assert {:ok, ^receipt} = Authority.request_status(c.authority, c.control, 1, "request:1")

    assert {:ok, %{held_requests: 1, queued_requests: 0, dispatch_enabled: false}} =
             Store.health(c.store)

    assert :ok = integrity(c.path)

    assert {:ok, %{state: :inactive, rule_generation: 2, affected_requests: 1}} =
             Authority.suspend_rules(c.authority, c.manager, 1, "suspend:1", 6)

    assert {:ok, %{disposition: :rejected, reason: "rule_generation_changed"} = cancelled} =
             invoke(c, "request:1", 1)

    assert {:ok, ^cancelled} = Authority.request_status(c.authority, c.control, 1, "request:1")
    assert {:error, :rule_inactive} = invoke(c, "request:2", 2)
    assert :ok = integrity(c.path)
  end

  test "live operator override blocks invocation without spending a root or changing revision",
       c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)

    assert {:ok, _} =
             Authority.override_issue(
               c.authority,
               c.control,
               1,
               "override:1",
               c.thing.id,
               0,
               60_000
             )

    {:ok, revision} = Store.revision(c.store)
    assert {:error, :operator_override_active} = invoke(c, "request:1", 1)
    assert {:ok, ^revision} = Store.revision(c.store)
    assert :not_found = Authority.request_status(c.authority, c.control, 1, "request:1")
    assert {:ok, _} = Authority.override_revoke(c.authority, c.control, 1, "override:1")
    assert {:ok, %{disposition: :held}} = invoke(c, "request:1", 1)
  end

  test "revoked management authority blocks new rule effects but retains immutable history", c do
    {:ok, receipt} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)
    assert {:ok, _} = Store.revoke_target_grant(c.store, "manager:1", c.thing.id)
    assert {:error, :permission_denied} = invoke(c, "request:1", 1)
    assert {:ok, ^receipt} = admit(c, "admission:1", 3)
    assert :not_found = Authority.request_status(c.authority, c.control, 1, "request:1")
    assert :ok = integrity(c.path)
  end

  test "maintenance generation fence suspends the active pointer", c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)
    assert {:ok, %{rule_generation: 2}} = Store.fence_rule_generation(c.store, 5, 1)

    assert {:ok, %{state: :inactive, admission_revision: 0}} =
             Authority.rule_status(c.authority, c.manager)

    assert :ok = integrity(c.path)
  end

  test "restart retains generation, active bytes and exact retry without resending", c do
    {:ok, admission} = admit(c, "admission:1", 3)
    {:ok, activation} = activate(c, "activation:1", 4, 4)
    {:ok, request} = invoke(c, "request:1", 1)
    :ok = GenServer.stop(c.store)
    store = start_supervised!({Store, path: c.path}, id: :restarted)
    authority = Authority.new(store: store)

    assert {:ok, ^admission} =
             Authority.admit_rule(authority, c.manager, 1, "admission:1", 3, [rule()])

    assert {:ok, ^activation} =
             Authority.activate_rule(authority, c.manager, 1, "activation:1", 4, 4)

    assert {:ok, ^request} =
             Authority.invoke_rule(authority, c.control, 1, "request:1", 1, "rule:explicit")

    assert {:ok, %{held_requests: 1, queued_requests: 0, rule_generation: 1}} =
             Store.health(store)

    assert :ok = integrity(c.path)
  end

  test "encrypted backup preserves rule history but staging cannot activate it", c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)
    key = :crypto.strong_rand_bytes(32)
    archive = Path.join(c.directory, "rules.backup")
    assert {:ok, _} = Store.export_backup(c.store, archive, key)

    assert {:ok,
            %{
              dependencies: %{
                rule_admission_rows: 1,
                rule_activation_rows: 1,
                rule_history_reactivates_on_restore: false
              }
            }} = Backup.verify(archive, key)

    assert {:ok, %{quarantined: true}} =
             Backup.stage_restore(archive, key, Path.join(c.directory, "staged.sqlite"))
  end

  test "a runtime receipt or rewritten IR cannot be substituted for current admission", c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)
    {:ok, [[document]]} = SQL.query(db, "SELECT artifact_document FROM rule_admissions")
    :ok = Sqlite3.close(db)
    assert {:ok, _} = AdmissionArtifact.current(document)
    data = JSON.decode!(document)

    bad =
      data
      |> put_in(["proposal_basis", "runtime_digest"], String.duplicate("0", 64))
      |> JSON.encode!()

    assert {:error, _} = AdmissionArtifact.current(bad)
  end

  test "live status rejects a damaged activation receipt and disables writes", c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "UPDATE rule_activations SET previous_generation=1")
    :ok = Sqlite3.close(db)

    assert {:error, :corrupt_rule_admission} =
             Authority.rule_operation_status(c.authority, c.manager, 1, "activation:1")

    assert {:ok, %{writable: false}} = Store.health(c.store)
    assert {:error, :store_unavailable} = invoke(c, "request:1", 1)
  end

  test "live rule status rejects a damaged active pointer and disables writes", c do
    {:ok, _} = admit(c, "admission:1", 3)
    {:ok, _} = activate(c, "activation:1", 4, 4)
    {:ok, db} = Sqlite3.open(c.path)
    :ok = Sqlite3.execute(db, "UPDATE meta SET value=0 WHERE key='active_rule_admission'")
    :ok = Sqlite3.close(db)
    assert {:error, :corrupt_rule_admission} = Authority.rule_status(c.authority, c.manager)
    assert {:ok, %{writable: false}} = Store.health(c.store)
  end

  for {name, sql} <- [
        {"missing rule origin", "DELETE FROM request_rule_origins"},
        {"missing root marker",
         "UPDATE request_causal_roots SET rule_admission_revision=NULL, rule_generation=NULL"},
        {"wrong source rule", "UPDATE request_rule_origins SET rule_id='rule:forged'"},
        {"cleared active pointer", "UPDATE meta SET value=0 WHERE key='active_rule_admission'"},
        {"changed request value", "UPDATE request_receipts SET value_a='0'"},
        {"changed activation generation", "UPDATE rule_activations SET previous_generation=1"}
      ] do
    @sql sql
    test "#{name} prevents startup and encrypted verification", c do
      {:ok, _} = admit(c, "admission:1", 3)
      {:ok, _} = activate(c, "activation:1", 4, 4)
      {:ok, _} = invoke(c, "request:1", 1)
      {:ok, db} = Sqlite3.open(c.path)
      :ok = Sqlite3.execute(db, @sql)
      assert {:error, _} = Integrity.validate_snapshot(db)
      key = :crypto.strong_rand_bytes(32)
      archive = Path.join(c.directory, "invalid.backup")
      assert {:ok, _} = Backup.export(db, archive, key)
      assert {:error, :invalid_backup} = Backup.verify(archive, key)
      :ok = Sqlite3.close(db)
      :ok = GenServer.stop(c.store)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_open_failed, _}} = Store.start_link(path: c.path)
    end
  end

  defp admit(c, id, revision),
    do: Authority.admit_rule(c.authority, c.manager, 1, id, revision, [rule()])

  defp activate(c, id, revision, admission),
    do: Authority.activate_rule(c.authority, c.manager, 1, id, revision, admission)

  defp invoke(c, id, generation),
    do: Authority.invoke_rule(c.authority, c.control, 1, id, generation, "rule:explicit")

  defp integrity(path) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      Integrity.validate_snapshot(db)
    after
      Sqlite3.close(db)
    end
  end

  defp framed(authority, request) do
    body = JSON.encode!(request)

    {:ok, <<size::32, response::binary-size(size)>>} =
      Server.route_frame(authority, <<byte_size(body)::32, body::binary>>)

    JSON.decode!(response)
  end

  defp rule,
    do: %{
      "version" => 1,
      "id" => "rule:explicit",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => "light:rule",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => true}
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => 1,
      "cooldown_ms" => 0,
      "causal_budget" => 1
    }

  defp thing,
    do:
      Thing.new(%{
        "id" => "light:rule",
        "role" => "Light",
        "profile_ref" => "fixture:rule:1",
        "capabilities" => [
          %{
            "thing_id" => "light:rule",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:rule:1",
            "evidence_ref" => "cohort:rule",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })
end
