defmodule WotexHome.DurableRuleInvocationTest do
  @moduledoc false

  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.{Authority, Mutation}
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.LocalAPI.{Client, Server}
  alias WotexHome.Rules.InvocationPreparation
  alias WotexHome.Semantics.Thing

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-rule-invocation-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

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
        "manager:kernel",
        ~w(rule:review rule:manage control:ordinary host:maintain policy:manage read),
        [thing.id]
      )

    {:ok, control, 3} =
      Store.provision_principal(store, "operator:kernel", ["control:ordinary"], [thing.id])

    authority = Authority.new(store: store)

    {:ok, %{revision: 4}} =
      Authority.admit_rule(authority, manager, 1, "admit:kernel", 3, [rule()])

    {:ok, %{rule_generation: 1}} =
      Authority.activate_rule(authority, manager, 1, "activate:kernel", 4, 4)

    %{
      store: store,
      authority: authority,
      manager: manager,
      control: control,
      path: path,
      thing: thing
    }
  end

  test "preparation is closed, independently committed inert data with no durable write", c do
    before = snapshot(c)
    assert {:ok, preparation} = prepare(c)
    assert :ok = InvocationPreparation.identity(preparation)
    assert {:ok, _artifact} = InvocationPreparation.decode(preparation)
    assert preparation.principal_id == "operator:kernel"
    assert preparation.admission_revision == 4 and preparation.rule_generation == 1
    assert preparation.preparation_digest == preparation_digest(preparation)
    assert snapshot(c) == before
    assert {:ok, projection} = InvocationPreparation.proposal(preparation)
    assert projection["preparation_digest"] == preparation.preparation_digest
    assert snapshot(c) == before
    assert {:ok, %{disposition: :held, revision: 6}} = commit(c, preparation, projection)
    assert roots(c) == [[4, 1, 0]]
    assert :ok = integrity(c)
  end

  test "both public APIs calculate the actual invocation original in the caller process", c do
    parent = self()
    tracer = spawn(fn -> trace_loop(parent) end)
    :erlang.trace_pattern({Wotex.Routines.Kernel, :advance, 7}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    :erlang.trace(c.store, true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, %{disposition: :held}} = invoke(c, "actual:authority")

      assert {:ok, %{disposition: :held}} =
               Store.invoke_rule(c.store, c.control, 1, "actual:compatibility", 1, "rule:kernel")

      reference = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^reference}
      marker = make_ref()
      send(tracer, {:drain, marker})
      assert_receive {:drained, ^marker}
      calls = trace_calls([])

      for operation <- ["actual:authority", "actual:compatibility"] do
        original = generic_original(operation)
        assert [{pid, ^original}] = Enum.filter(calls, &(elem(&1, 1) == original))
        assert pid == self()
        refute pid == c.store
      end

      assert length(roots(c)) == 2
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace(c.store, false, [:call])
      :erlang.trace_pattern({Wotex.Routines.Kernel, :advance, 7}, false, [:local])
      send(tracer, :stop)
    end
  end

  test "concurrent callers and a stale calculated duplicate recover one held original", c do
    {:ok, preparation} = prepare(c)
    {:ok, projection} = InvocationPreparation.proposal(preparation)
    tasks = for _ <- 1..2, do: Task.async(fn -> invoke(c, "invoke:kernel") end)
    assert [{:ok, receipt}, {:ok, receipt}] = Enum.map(tasks, &Task.await(&1, 15_000))
    assert receipt.disposition == :held
    before = snapshot(c)
    assert {:ok, ^receipt} = commit(c, preparation, %{"stale" => projection})
    assert {:ok, :existing, ^receipt} = prepare(c)
    assert snapshot(c) == before
    assert roots(c) == [[4, 1, 0]]
  end

  test "unrelated revision changes preserve a preparation's exact relevant basis", c do
    {:ok, preparation} = prepare(c)
    {:ok, projection} = InvocationPreparation.proposal(preparation)

    assert {:ok, _, 6} =
             Store.provision_principal(c.store, "observer:other", ["rule:review"], [c.thing.id])

    assert {:ok, %{disposition: :held, revision: 7}} = commit(c, preparation, projection)
  end

  test "replacing the active source fences the calculated old value and admits only the new source",
       c do
    {:ok, preparation} = prepare(c)
    {:ok, projection} = InvocationPreparation.proposal(preparation)

    replacement =
      rule() |> Map.put("source_revision", 2) |> put_in(["effect", "value", "value"], false)

    assert {:ok, %{revision: 6}} =
             Authority.admit_rule(c.authority, c.manager, 1, "admit:replacement", 5, [replacement])

    assert {:ok, %{rule_generation: 2}} =
             Authority.activate_rule(c.authority, c.manager, 1, "activate:replacement", 6, 6)

    before = snapshot(c)
    assert {:error, :stale_rule_generation} = commit(c, preparation, projection)
    assert snapshot(c) == before

    assert {:ok, %{disposition: :held, revision: 8}} =
             Authority.invoke_rule(c.authority, c.control, 1, "invoke:kernel", 2, "rule:kernel")

    assert [["0"]] =
             read(c, fn db ->
               {:ok, rows} =
                 SQL.query(
                   db,
                   "SELECT value_a FROM request_receipts WHERE operation_id='invoke:kernel'"
                 )

               rows
             end)

    assert roots(c) == [[6, 2, 0]]
    assert :ok = integrity(c)
  end

  test "a valid inert proposal for a different epoch cannot authorize a current Store original",
       c do
    {:ok, preparation} = prepare(c)
    changed = %{preparation | authority_epoch: 2}
    changed = %{changed | preparation_digest: preparation_digest(changed)}
    assert :ok = InvocationPreparation.identity(changed)
    assert {:ok, projection} = InvocationPreparation.proposal(changed)
    before = snapshot(c)

    assert {:error, :stale_authority_epoch} = commit(c, changed, projection)

    assert {:error, :stale_authority_epoch} =
             Store.prepare_rule_invocation(
               c.store,
               c.control,
               2,
               "invoke:kernel",
               1,
               "rule:kernel"
             )

    assert snapshot(c) == before
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(c.store)
    assert :ok = integrity(c)
    assert {:ok, %{disposition: :held}} = invoke(c, "invoke:kernel")
    assert roots(c) == [[4, 1, 0]]
  end

  test "malformed preparations, foreign credentials and malformed results publish nothing", c do
    {:ok, preparation} = prepare(c)
    {:ok, projection} = InvocationPreparation.proposal(preparation)
    before = snapshot(c)

    for changed <- [
          nil,
          %{},
          Map.put(preparation, :extra, true),
          Map.delete(preparation, :runtime_digest),
          %{preparation | authority_epoch: true},
          %{preparation | preparation_digest: String.duplicate("f", 64)},
          %{preparation | artifact_document: String.duplicate("x", 4_194_305)}
        ] do
      assert {:error, :invalid_rule_operation_input} = commit(c, changed, projection)
    end

    assert {:error, :permission_denied} =
             Store.commit_rule_invocation(c.store, c.manager, preparation, projection)

    assert {:error, :unauthorized} =
             Store.commit_rule_invocation(c.store, <<>>, preparation, projection)

    assert {:error, :unauthorized} =
             Store.prepare_rule_invocation(c.store, <<>>, 1, "new:bad", 1, "rule:kernel")

    for changed <- [
          nil,
          %{},
          Map.put(projection, "extra", true),
          put_in(projection, ["result", "proposals"], []),
          put_in(projection, ["result", "proposals", Access.at!(0), "input"], false)
        ] do
      assert {:error, :invalid_kernel_projection} = commit(c, preparation, changed)
    end

    assert snapshot(c) == before
    assert {:ok, %{writable: true}} = Store.health(c.store)
    {:ok, fresh} = prepare(c)
    {:ok, fresh_projection} = InvocationPreparation.proposal(fresh)
    assert {:ok, %{disposition: :held}} = commit(c, fresh, fresh_projection)
  end

  for {_name, action, expected} <- [
        {"invoker grant", :invoker_grant, :permission_denied},
        {"author grant", :author_grant, :permission_denied},
        {"invoker status", :invoker_status, :unauthorized},
        {"author status", :author_status, :principal_unavailable},
        {"generation", :generation, :stale_rule_generation},
        {"maintenance", :maintenance, :maintenance_active},
        {"operator override", :override, :operator_override_active},
        {"declaration", :declaration, :rule_basis_changed},
        {"target", :target, :target_unavailable},
        {"invariant", :invariant, :rule_basis_changed}
      ] do
    @action action
    @expected expected
    test "changed #{@action} between preparation and commit refuses without publication", c do
      {:ok, preparation} = prepare(c)
      {:ok, projection} = InvocationPreparation.proposal(preparation)
      assert {:ok, _} = mutate(c, @action)
      before = snapshot(c)
      assert {:error, @expected} = commit(c, preparation, projection)
      assert snapshot(c) == before
      assert {:ok, %{writable: true}} = Store.health(c.store)
      assert before["request_receipts"] == []
    end
  end

  for {_name, sql, expected} <- [
        {"invoker status",
         "UPDATE principals SET status='revoked' WHERE principal_id='operator:kernel'",
         :unauthorized},
        {"invoker grant", "DELETE FROM principal_targets WHERE principal_id='operator:kernel'",
         :permission_denied},
        {"author status",
         "UPDATE principals SET status='revoked' WHERE principal_id='manager:kernel'",
         :principal_unavailable},
        {"author grant", "DELETE FROM principal_targets WHERE principal_id='manager:kernel'",
         :permission_denied}
      ] do
    @sql sql
    @expected expected
    test "final #{@sql} is checked after tentative origin and rolls back all publication", c do
      {:ok, preparation} = prepare(c)
      {:ok, projection} = InvocationPreparation.proposal(preparation)

      execute(
        c,
        "CREATE TRIGGER final_drift AFTER INSERT ON request_rule_origins BEGIN " <>
          @sql <> "; END"
      )

      before = snapshot(c)
      assert {:error, @expected} = commit(c, preparation, projection)
      assert snapshot(c) == before
      assert {:ok, %{writable: true}} = Store.health(c.store)
      execute(c, "DROP TRIGGER final_drift")
      {:ok, fresh} = prepare(c)
      {:ok, fresh_projection} = InvocationPreparation.proposal(fresh)
      assert {:ok, %{disposition: :held}} = commit(c, fresh, fresh_projection)
      assert :ok = integrity(c)
    end
  end

  for table <-
        ~w(request_receipts request_outbox request_journal request_causal_roots request_rule_origins) do
    @table table
    test "SQL publication failure in #{@table} rolls back every row and disables writing", c do
      {:ok, preparation} = prepare(c)
      {:ok, projection} = InvocationPreparation.proposal(preparation)

      execute(
        c,
        "CREATE TRIGGER publication_fault BEFORE INSERT ON " <>
          @table <>
          " BEGIN SELECT RAISE(ABORT, 'permission_denied'); END"
      )

      before = snapshot(c)
      assert {:error, :store_unavailable} = commit(c, preparation, projection)
      assert snapshot(c) == before
      assert {:ok, %{writable: false}} = Store.health(c.store)
      assert :ok = integrity(c)
    end
  end

  test "pending capacity refusal retains no rejected invocation or new root", c do
    {:ok, initial_preparation} = prepare(c)
    {:ok, artifact} = InvocationPreparation.decode(initial_preparation)
    [resource] = artifact.resources

    for number <- 1..32 do
      {:ok, mutation} =
        Mutation.new(%{
          "api_version" => 1,
          "authority_epoch" => 1,
          "operation_id" => "manual:" <> Integer.to_string(number),
          "expected_revision" => resource["resource_revision"],
          "target_id" => c.thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false}
        })

      assert {:ok, %{disposition: :held}} = Store.submit_request(c.store, c.control, mutation)
    end

    {:ok, preparation} = prepare(c)
    {:ok, projection} = InvocationPreparation.proposal(preparation)
    before = snapshot(c)
    assert {:error, :receipt_capacity} = commit(c, preparation, projection)
    assert snapshot(c) == before
    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  @tag :requires_socket
  test "the actual private socket invokes and recovers the same original while refusing stale work",
       c do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "woh-rule-api-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    socket = Path.join(root, "ipc/home.sock")
    start_supervised!({Server, authority: c.authority, socket_path: socket})

    request = %{
      "api_version" => 1,
      "operation" => "invoke_rule",
      "credential" => Base.url_encode64(c.control, padding: false),
      "authority_epoch" => 1,
      "operation_id" => "invoke:socket",
      "rule_generation" => 1,
      "rule_id" => "rule:kernel"
    }

    assert {:ok, %{"outcome" => "ok", "receipt" => %{"disposition" => "held"}} = response} =
             Client.request(socket, request)

    before = snapshot(c)
    assert {:ok, ^response} = Client.request(socket, request)
    assert Server.route(c.authority, request) == response
    assert {:ok, %{disposition: :held}} = invoke(c, "invoke:socket")

    assert {:ok, %{"outcome" => "error", "reason" => "stale_rule_generation"}} =
             Client.request(
               socket,
               Map.merge(request, %{
                 "operation_id" => "invoke:socket-stale",
                 "rule_generation" => 2
               })
             )

    assert snapshot(c) == before
    assert roots(c) == [[4, 1, 0]]
    assert :ok = integrity(c)
  end

  test "legacy raw messages and external preparation routes cannot bypass the join", c do
    before = snapshot(c)

    assert {:error, :invalid_rule_operation_input} =
             GenServer.call(
               c.store,
               {:invoke_rule, c.control, 1, "raw:invoke", 1, "rule:kernel"}
             )

    for operation <- ["prepare_rule_invocation", "commit_rule_invocation"] do
      bytes =
        JSON.encode!(%{
          "api_version" => 1,
          "operation" => operation,
          "credential" => Base.url_encode64(c.control, padding: false)
        })

      assert {:ok, <<size::32, response::binary-size(size)>>} =
               Server.route_frame(c.authority, <<byte_size(bytes)::32, bytes::binary>>)

      assert %{"outcome" => "error"} = JSON.decode!(response)
    end

    assert snapshot(c) == before
    assert {:ok, %{writable: true}} = Store.health(c.store)
  end

  test "restart recovers the committed original with the generic producer absent", _c do
    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-rule-history-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, declaration} = WotexHome.Durable.Registry.encode_thing(elem(thing(), 1))

    script = """
    alias WotexHome.{Authority, Durable.Store}
    alias WotexHome.Durable.Store.SQL
    alias Exqlite.Sqlite3
    path = #{inspect(Path.join(directory, "home.sqlite"))}
    {:ok, thing} = WotexHome.Durable.Registry.decode_thing(#{inspect(declaration)})
    {:ok, store} = Store.start_link(path: path)
    {:ok, 1} = Store.enroll_thing(store, thing)
    {:ok, manager, 2} = Store.provision_principal(store, "manager:kernel", ~w(rule:review rule:manage control:ordinary), [thing.id])
    {:ok, control, 3} = Store.provision_principal(store, "operator:kernel", ["control:ordinary"], [thing.id])
    authority = Authority.new(store: store)
    {:ok, _} = Authority.admit_rule(authority, manager, 1, "admit:kernel", 3, [#{inspect(rule())}])
    {:ok, _} = Authority.activate_rule(authority, manager, 1, "activate:kernel", 4, 4)
    {:ok, receipt} = Authority.invoke_rule(authority, control, 1, "retained:original", 1, "rule:kernel")
    retained = fn ->
      {:ok, db} = Sqlite3.open(path, mode: :readonly)
      try do
        Map.new(~w(rule_admissions request_receipts request_journal request_rule_origins request_causal_roots), fn table ->
          {:ok, rows} = SQL.query(db, "SELECT * FROM " <> table <> " ORDER BY rowid")
          {table, rows}
        end)
      after Sqlite3.close(db) end
    end
    before = retained.()
    :ok = GenServer.stop(store)
    path_to_remove = Application.app_dir(:wotex_routines, "ebin")
    modules = Application.spec(:wotex_routines, :modules)
    true = :code.del_path(String.to_charlist(path_to_remove))
    for module <- modules do
      :code.purge(module)
      :code.delete(module)
    end
    :ok = Application.unload(:wotex_routines)
    false = Code.ensure_loaded?(Wotex.Routines.Kernel)
    {:ok, restarted} = Store.start_link(path: path)
    {:ok, ^receipt} = Store.invoke_rule(restarted, control, 1, "retained:original", 1, "rule:kernel")
    {:ok, ^receipt} = Authority.invoke_rule(Authority.new(store: restarted), control, 1, "retained:original", 1, "rule:kernel")
    false = Code.ensure_loaded?(Wotex.Routines.Kernel)
    {:error, reason} = Store.invoke_rule(restarted, control, 1, "new:absent", 1, "rule:kernel")
    true = reason in [:unsupported_admission_profile, :runtime_artifact_unavailable, :routine_kernel_unavailable]
    {:ok, %{writable: true}} = Store.health(restarted)
    true = retained.() == before
    :ok = GenServer.stop(restarted)
    IO.puts("original recovered without producer")
    """

    arguments =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
        ["-e", script]

    assert {"original recovered without producer\n", 0} =
             System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
  end

  defp prepare(c),
    do: Store.prepare_rule_invocation(c.store, c.control, 1, "invoke:kernel", 1, "rule:kernel")

  defp commit(c, preparation, projection),
    do: Store.commit_rule_invocation(c.store, c.control, preparation, projection)

  defp invoke(c, operation),
    do: Authority.invoke_rule(c.authority, c.control, 1, operation, 1, "rule:kernel")

  defp mutate(c, :invoker_grant),
    do: Store.revoke_target_grant(c.store, "operator:kernel", c.thing.id)

  defp mutate(c, :author_grant),
    do: Store.revoke_target_grant(c.store, "manager:kernel", c.thing.id)

  defp mutate(c, :invoker_status), do: Store.revoke_principal(c.store, "operator:kernel")
  defp mutate(c, :author_status), do: Store.revoke_principal(c.store, "manager:kernel")

  defp mutate(c, :generation),
    do: Authority.suspend_rules(c.authority, c.manager, 1, "suspend:kernel", 5)

  defp mutate(c, :maintenance),
    do: Authority.begin_maintenance(c.authority, c.manager, 1, "maintenance:kernel", 5)

  defp mutate(c, :override),
    do:
      Authority.override_issue(
        c.authority,
        c.control,
        1,
        "override:kernel",
        c.thing.id,
        0,
        60_000
      )

  defp mutate(c, :target), do: Store.revoke_thing(c.store, c.thing.id)

  defp mutate(c, :declaration) do
    narrowed = %{
      c.thing
      | capabilities: %{"power" => %{c.thing.capabilities["power"] | freshness_ms: 4_999}}
    }

    Store.narrow_thing(c.store, narrowed, 0)
  end

  defp mutate(c, :invariant) do
    {:ok, predicate} = WotexHome.Rules.Predicate.new(%{"op" => "literal_true"})

    Authority.set_invariant(
      c.authority,
      c.manager,
      1,
      "invariant:kernel",
      5,
      c.thing.id,
      0,
      predicate
    )
  end

  defp snapshot(c) do
    read(c, fn db ->
      Map.new(
        ~w(meta request_receipts request_outbox request_journal request_causal_roots request_rule_origins authority_journal principals principal_targets),
        fn table ->
          {:ok, rows} = SQL.query(db, "SELECT * FROM " <> table <> " ORDER BY rowid")
          {table, rows}
        end
      )
    end)
  end

  defp roots(c),
    do:
      read(c, fn db ->
        {:ok, rows} =
          SQL.query(
            db,
            "SELECT rule_admission_revision, rule_generation, reserved_effects FROM request_causal_roots ORDER BY rowid"
          )

        rows
      end)

  defp integrity(c), do: read(c, &Integrity.validate_snapshot/1)

  defp read(c, fun) do
    {:ok, db} = Sqlite3.open(c.path, mode: :readonly)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp execute(c, sql) do
    {:ok, db} = Sqlite3.open(c.path)

    try do
      :ok = Sqlite3.execute(db, sql)
    after
      Sqlite3.close(db)
    end
  end

  defp preparation_digest(p),
    do:
      digest(
        {"wotex-home.rule-invocation-preparation.v1", p.principal_id, p.authority_epoch,
         p.operation_id, p.rule_generation, p.admission_revision, p.rule_id, p.artifact_digest,
         p.runtime_digest}
      )

  defp generic_original(operation),
    do:
      "home:rule:" <>
        digest({"wotex-home.rule-original.v1", "operator:kernel", 1, operation})

  defp digest(term),
    do:
      term
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp trace_loop(parent) do
    receive do
      {:drain, marker} ->
        send(parent, {:drained, marker})
        trace_loop(parent)

      :stop ->
        :ok

      message ->
        send(parent, {:kernel_trace, message})
        trace_loop(parent)
    end
  end

  defp trace_calls(acc) do
    receive do
      {:kernel_trace, {:trace, pid, :call, {Wotex.Routines.Kernel, :advance, [_, event | _]}}} ->
        trace_calls([{pid, event["original"]} | acc])
    after
      0 -> acc
    end
  end

  defp rule,
    do: %{
      "version" => 1,
      "id" => "rule:kernel",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => "lamp_desk",
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
        "id" => "lamp_desk",
        "role" => "Light",
        "profile_ref" => "fixture:kernel:1",
        "capabilities" => [
          %{
            "thing_id" => "lamp_desk",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:kernel:1",
            "evidence_ref" => "fixture:kernel:1",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })
end
