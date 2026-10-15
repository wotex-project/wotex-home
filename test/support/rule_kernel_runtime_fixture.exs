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
        ~w(meta enrolled_things principals principal_targets rule_admissions rule_activations authority_journal request_receipts request_outbox request_journal request_causal_roots request_rule_origins request_execution profile_request_pins)

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
