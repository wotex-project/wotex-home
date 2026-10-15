Code.require_file(Path.expand("lifx_qualification_fixture.exs", __DIR__))

defmodule WotexHome.TestSupport.RuleKernelRuntimeFixture do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.Durable.Store.{Integrity, SQL}
  alias WotexHome.Rules.InvocationPreparation
  alias WotexHome.Semantics.Thing

  def new(path) do
    {:ok, thing} =
      Thing.new(%{
        "id" => "lamp_runtime",
        "role" => "Light",
        "profile_ref" => "fixture:runtime:1",
        "capabilities" => [
          %{
            "thing_id" => "lamp_runtime",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:runtime:1",
            "evidence_ref" => "fixture:runtime:1",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, store} = Store.start_link(path: path)
    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, manager, 2} =
      Store.provision_principal(
        store,
        "manager:runtime",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    {:ok, control, 3} =
      Store.provision_principal(store, "operator:runtime", ["control:ordinary"], [thing.id])

    authority = Authority.new(store: store)

    {:ok, %{revision: 4}} =
      Authority.admit_rule(authority, manager, 1, "admit:runtime", 3, [source()])

    {:ok, %{rule_generation: 1}} =
      Authority.activate_rule(authority, manager, 1, "activate:runtime", 4, 4)

    %{store: store, authority: authority, manager: manager, control: control, path: path}
  end

  def qualified(path) do
    data = WotexHome.TestSupport.LifxQualificationFixture.data()
    {:ok, candidate} = WotexHome.Discovery.Candidate.new(data.candidate)
    {:ok, interview} = WotexHome.Discovery.Interview.new(data.interview, candidate)
    {:ok, profile} = WotexHome.Discovery.Profile.new(data.profile)

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:desk",
        "role" => "Light",
        "profile_ref" => "lifx.old-eu:1.0.0",
        "capabilities" => [data.power]
      })

    {:ok, initial} = Store.start_link(path: path)
    {:ok, owner, 1} = Store.provision_principal(initial, "owner:1", ["enroll:review"], [])

    {:ok, 2} =
      Store.commit_enrollment(
        initial,
        owner,
        [candidate],
        interview,
        [profile],
        thing,
        data.selection
      )

    {:ok, control, 3} =
      Store.provision_principal(initial, "operator:runtime", ["control:ordinary"], [thing.id])

    {:ok, report} =
      WotexHome.Semantics.Observation.new(
        %{
          "thing_id" => thing.id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => false},
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "source_epoch" => "device:1",
          "source_sequence" => 1,
          "boot_epoch" => "boot:1",
          "source_time_utc_ms" => nil,
          "received_time_utc_ms" => 1_000_100,
          "received_monotonic_ms" => 100
        },
        thing.capabilities["power"]
      )

    {:ok, 4} = Store.record(initial, report, thing.capabilities["power"])
    :ok = GenServer.stop(initial)
    options = WotexHome.TestSupport.LifxQualificationFixture.install(path, 5, thing)
    {:ok, store} = Store.start_link([path: path] ++ options)

    {:ok, manager, 6} =
      Store.provision_principal(
        store,
        "manager:runtime",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    authority = Authority.new(store: store)
    source = put_in(source(), ["effect", "target_id"], thing.id)

    {:ok, %{revision: 7}} =
      Authority.admit_rule(authority, manager, 1, "admit:runtime", 6, [source])

    {:ok, %{rule_generation: 1}} =
      Authority.activate_rule(authority, manager, 1, "activate:runtime", 7, 7)

    %{
      store: store,
      authority: authority,
      manager: manager,
      control: control,
      path: path,
      options: options,
      thing: thing
    }
  end

  def phase(c, :held, operation), do: Store.request_status(c.store, c.control, 1, operation)

  def phase(c, phase, operation)
      when phase in [:queued, :claimed, :dispatching, :protocol_accepted] do
    {:ok, %{disposition: :queued}} =
      Store.admit_held_power(c.store, c.control, 1, operation, "boot:1", 101)

    if phase == :queued do
      Store.request_status(c.store, c.control, 1, operation)
    else
      {:ok, claim} =
        Store.claim_lifx_power(c.store, "operator:runtime", 1, operation, "boot:1", 101)

      if phase in [:dispatching, :protocol_accepted] do
        {:ok, %{disposition: :dispatching}} =
          Store.handoff_claimed_power(c.store, "operator:runtime", 1, operation, claim.token, 101)

        if phase == :protocol_accepted do
          Store.accept_power_ack(c.store, "operator:runtime", 1, operation, claim.token)
        else
          Store.request_status(c.store, c.control, 1, operation)
        end
      else
        Store.request_status(c.store, c.control, 1, operation)
      end
    end
  end

  def source do
    %{
      "version" => 1,
      "id" => "rule:runtime",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => "lamp_runtime",
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

  def prepare(c, operation),
    do: Store.prepare_rule_invocation(c.store, c.control, 1, operation, 1, "rule:runtime")

  def proposal(preparation), do: InvocationPreparation.proposal(preparation)

  def commit(c, preparation, projection),
    do: Store.commit_rule_invocation(c.store, c.control, preparation, projection)

  def invoke(c, operation),
    do: Authority.invoke_rule(c.authority, c.control, 1, operation, 1, "rule:runtime")

  def snapshot(c) do
    read(c.path, fn db ->
      tables =
        ~w(meta enrolled_things principals principal_targets rule_admissions rule_activations authority_journal request_receipts request_outbox request_journal request_causal_roots request_rule_origins request_execution profile_request_pins enrollment_bindings enrollment_review_history profile_qualifications profile_qualification_history journal observation_current)

      Map.new(tables, fn table ->
        {:ok, rows} = SQL.query(db, "SELECT * FROM " <> table <> " ORDER BY rowid")
        {table, rows}
      end)
      |> Map.put(
        :schema,
        elem(
          SQL.query(
            db,
            "SELECT name,sql FROM sqlite_master WHERE type IN ('table','trigger') ORDER BY name"
          ),
          1
        )
      )
    end)
  end

  def recovery_only!(old, current) do
    changed = ["meta", "request_receipts", "request_journal", "request_execution"]
    true = Map.drop(current, changed) == Map.drop(old, changed)
    old_meta = Map.new(old["meta"], fn [key, value] -> {key, value} end)
    new_revision = old_meta["revision"] + 1

    true =
      Map.new(current["meta"], fn [key, value] -> {key, value} end) ==
        Map.put(old_meta, "revision", new_revision)

    [receipt] = old["request_receipts"]

    expected =
      receipt
      |> List.replace_at(10, "outcome_unknown")
      |> List.replace_at(11, "crash_after_handoff")
      |> List.replace_at(12, new_revision)

    true = current["request_receipts"] == [expected]
    [execution] = old["request_execution"]

    expected =
      execution |> List.replace_at(12, "outcome_unknown") |> List.replace_at(17, new_revision)

    true = current["request_execution"] == [expected]

    true =
      current["request_journal"] ==
        old["request_journal"] ++
          [
            [
              new_revision,
              "operator:runtime",
              1,
              "retained:v3",
              "outcome_unknown",
              "crash_after_handoff"
            ]
          ]

    :ok
  end

  def intact(c), do: read(c.path, &Integrity.validate_snapshot/1)

  def read(path, fun) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  def install_final_hook(private_home, source_path) do
    source = File.read!(source_path)
    marker = "    case RuleWriter.final_invocation(db, credential, preparation, clock) do\n"
    true = length(String.split(source, marker)) == 2
    hook = "    if callback = Process.delete(:rka_final_test_hook), do: callback.(db)\n"
    load_matching(Store, String.replace(source, marker, hook <> marker), private_home)
  end

  def load_matching(module, source, directory) do
    Code.compiler_options(ignore_module_conflict: true)
    [{^module, bytes}] = Code.compile_string(source)
    File.write!(Path.join(directory, Atom.to_string(module) <> ".beam"), bytes)
    :code.purge(module)
    :ok
  end

  def final_hook(c, callback) do
    :sys.replace_state(c.store, fn state ->
      Process.put(:rka_final_test_hook, callback)
      state
    end)

    :ok
  end

  def mutation(paths, application, kind) when kind in [:bytes, :absent] do
    module =
      if application == :wotex_home,
        do: WotexHome.Schedules.Window,
        else: hd(Application.spec(application, :modules))

    path = Path.join(Map.fetch!(paths, application), Atom.to_string(module) <> ".beam")
    original = File.read!(path)

    change =
      case kind do
        :absent ->
          fn -> File.rm!(path) end

        :bytes ->
          {:ok, ^module, chunks} = :beam_lib.all_chunks(original)

          {:ok, changed} =
            :beam_lib.build_module(chunks ++ [{~c"TEST", "complete retained byte drift"}])

          {:ok, {^module, checksum}} = :beam_lib.md5(original)
          {:ok, {^module, ^checksum}} = :beam_lib.md5(changed)
          fn -> File.write!(path, changed) end
      end

    {change, fn -> File.write!(path, original) end}
  end

  def mutation(paths, application, kind) when kind in [:version, :modules] do
    path = Path.join(Map.fetch!(paths, application), Atom.to_string(application) <> ".app")

    {:ok, [{:application, ^application, properties} = original]} =
      :file.consult(String.to_charlist(path))

    properties =
      case kind do
        :version -> Keyword.put(properties, :vsn, ~c"changed")
        :modules -> Keyword.update!(properties, :modules, &tl/1)
      end

    replace = fn term ->
      :ok = Application.unload(application)
      :ok = :application.load(term)
    end

    {fn -> replace.({:application, application, properties}) end, fn -> replace.(original) end}
  end

  def tentative!(db, operation) do
    for table <- ~w(request_receipts request_outbox request_rule_origins request_causal_roots) do
      {:ok, [[1]]} =
        SQL.query(db, "SELECT COUNT(*) FROM " <> table <> " WHERE operation_id=?", [operation])
    end

    :ok
  end
end
