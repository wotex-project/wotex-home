Code.require_file(Path.expand("../support/calendar_trace_inputs.exs", __DIR__))

defmodule WotexHome.DurableScheduleCalendarTracesTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store

  alias WotexHome.Durable.Store.{
    ClockContext,
    Integrity,
    ScheduleLifecycle,
    ScheduleOccurrences,
    SQL
  }

  alias WotexHome.Schedules.{Codec, DurableModel, OperationInput, Tzif}
  alias WotexHome.TestSupport.CalendarTraceInputs
  alias WotexHome.Semantics.Thing
  @fixture Path.expand("../fixtures/schedules/calendar_durable_trace_vectors.json", __DIR__)
  @vectors @fixture |> File.read!() |> JSON.decode!()
  @zones Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)
         |> File.read!()
         |> JSON.decode!()
         |> Map.fetch!("zones")

  setup do
    root =
      Path.join(System.tmp_dir!(), "woh-calendar-trace-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, path: path}, restart: :temporary))

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:calendar",
        "role" => "Light",
        "profile_ref" => "fixture:power",
        "capabilities" => [
          %{
            "thing_id" => "light:calendar",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "fixture:power",
            "evidence_ref" => "fixture:calendar",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, credential, 2} =
      Store.provision_principal(
        store,
        "manager:calendar",
        ~w(rule:review rule:manage control:ordinary),
        [thing.id]
      )

    %{root: root, path: path, store: store, credential: credential}
  end

  test "the frozen calendar corpus has closed bounded sources, horizons and actions" do
    assert byte_size(File.read!(@fixture)) <= 65_536
    assert Enum.sort(Map.keys(@vectors)) == ~w(format oracle scope vectors)
    assert @vectors["format"] == "wotex-home.calendar-durable-traces.v1"
    assert @vectors["scope"] == "bounded_calendar_consumption_software_correspondence"
    assert @vectors["oracle"] == "Python stdlib zoneinfo.from_file over frozen authored TZif"
    assert length(@vectors["vectors"]) == 14
    ids = Enum.map(@vectors["vectors"], & &1["id"])
    assert Enum.uniq(ids) == ids

    for vector <- @vectors["vectors"] do
      assert Enum.sort(Map.keys(vector)) == ~w(finish id instants steps trigger watermark zone)
      assert vector["id"] =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/
      assert hd(vector["trigger"]) in ~w(once daily weekdays)
      assert Enum.at(vector["trigger"], 1) == vector["zone"]

      if hd(vector["trigger"]) != "once",
        do: assert(List.last(vector["trigger"]) == vector["finish"])

      assert {:ok, _} = reference(vector)
      assert length(vector["steps"]) in 1..32

      for event <- vector["steps"] do
        case event do
          ["time", lower, upper] ->
            assert is_integer(lower) and is_integer(upper) and lower >= 0 and upper >= lower
            assert upper <= 253_402_300_739_999

          action ->
            assert action in ~w(poll restart)
        end
      end
    end
  end

  @tag calendar_fixture_refusal: true
  test "a controlled fixture cannot substitute synthetic timezone bytes for installed authority",
       c do
    record = Enum.find(@zones, &(&1["name"] == "Fixture/Stockholm"))
    {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
    trigger = ["daily", zone.name, zone.digest, "02:30:00", 0, nil]

    assert {:ok, %{revision: 3}} =
             Store.retain_schedule_content(c.store, c.credential, admission(trigger), zone)

    {:ok, activation} =
      OperationInput.encode("activate", %{
        "authority_epoch" => 1,
        "operation_id" => "calendar:activate",
        "expected_revision" => 3,
        "admission_revision" => 3
      })

    context = clock_context(c.store, 100_000, 100_000, 1000, zone)

    assert {:ok, {:ok, %{revision: 5}}} =
             writer(c.store, fn state ->
               SQL.transaction(
                 state.db,
                 &ScheduleLifecycle.change(&1, c.credential, activation, context)
               )
             end)

    assert {:ok, {:ok, %{state: :inactive}}} =
             writer(c.store, fn state ->
               SQL.transaction(
                 state.db,
                 &ScheduleOccurrences.consider(&1, context, state.receipt_limit)
               )
             end)

    assert {:ok, 7} = Store.revision(c.store)

    with_db(c.path, fn db ->
      assert [["withdraw", "timezone_basis_changed", 2]] =
               rows(
                 db,
                 "SELECT kind,reason,generation FROM schedule_lifecycle_operations ORDER BY revision DESC LIMIT 1"
               )

      assert [[0, 0]] =
               rows(
                 db,
                 "SELECT (SELECT COUNT(*) FROM schedule_considerations),(SELECT COUNT(*) FROM request_receipts)"
               )

      assert :ok = Integrity.validate_snapshot(db)
    end)
  end

  for vector <- @vectors["vectors"] do
    @tag calendar_trace: true
    test "frozen calendar consumption #{vector["id"]} agrees with actual SQLite history", c do
      vector = unquote(Macro.escape(vector))
      %{zone: zone, trigger: trigger} = CalendarTraceInputs.installed(vector, c.root)
      original = admission(trigger)

      assert {:ok, %{revision: 3}} =
               Store.retain_schedule_content(c.store, c.credential, original, zone)

      {:ok, activation} =
        OperationInput.encode("activate", %{
          "authority_epoch" => 1,
          "operation_id" => "calendar:activate",
          "expected_revision" => 3,
          "admission_revision" => 3
        })

      context = clock_context(c.store, vector["watermark"], vector["watermark"], 1000, zone)

      assert {:ok, {:ok, %{revision: 5}}} =
               writer(c.store, fn state ->
                 SQL.transaction(
                   state.db,
                   &ScheduleLifecycle.change(&1, c.credential, activation, context)
                 )
               end)

      assert {:ok, model} = reference(vector)

      c =
        Map.merge(c, %{clock: {vector["watermark"], vector["watermark"]}, history: %{}, step: 0})

      {c, _model} =
        Enum.reduce(vector["steps"], {c, model}, fn raw, {c, model} ->
          event =
            case raw do
              ["time", lower, upper] -> {:time, lower, upper}
              "poll" -> :poll
              "restart" -> :restart
            end

          assert {:ok, before} = Store.revision(c.store)
          c = run_step(%{c | step: c.step + 1}, event, zone)
          expected = DurableModel.step(model, event)
          actual = projection(c.path, vector["instants"])
          keys = ~w(generation watermark considerations missed missed_ranges records)a

          assert actual == Map.take(DurableModel.projection(expected), keys),
                 "#{vector["id"]}, #{c.step}: #{inspect(event)} actual=#{inspect(actual)} expected=#{inspect(Map.take(DurableModel.projection(expected), keys))}"

          assert {:ok, after_revision} = Store.revision(c.store)

          if event != :poll or actual == Map.take(DurableModel.projection(model), keys),
            do: assert(after_revision == before)

          for {id, {receipt, rows}} <- c.history do
            assert {:ok, ^receipt} = Store.original_schedule_occurrence(c.store, c.credential, id)
            assert rows == with_db(c.path, &original_rows(&1, id))
          end

          assert {:ok,
                  %{
                    writable: true,
                    queued_requests: 0,
                    claimed_requests: 0,
                    dispatch_enabled: false
                  }} = Store.health(c.store)

          {c, expected}
        end)

      assert :ok = GenServer.stop(c.store)
    end
  end

  defp reference(vector),
    do:
      DurableModel.new_calendar(%{
        instants: vector["instants"],
        finish: vector["finish"],
        watermark: vector["watermark"],
        late: 10_000,
        tolerance: 1_000
      })

  defp admission(trigger) do
    {:ok, rule} =
      WotexHome.Rules.OperationInput.source("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "calendar:rule",
        "expected_revision" => 2,
        "rule_id" => "rule:calendar",
        "source_revision" => 1,
        "target_id" => "light:calendar",
        "on" => true
      })

    {:ok, source} =
      Codec.encode(%{
        "id" => "schedule:calendar",
        "source_revision" => 1,
        "author_id" => "manager:calendar",
        "rule_id" => "rule:calendar",
        "rule_source_digest" => Codec.hash(rule),
        "target_id" => "light:calendar",
        "resource_revision" => 0,
        "late_window_ms" => 10_000,
        "uncertainty_tolerance_ms" => 1_000,
        "trigger" => trigger
      })

    {:ok, document} =
      OperationInput.encode("admit", %{
        "authority_epoch" => 1,
        "operation_id" => "calendar:admit",
        "expected_revision" => 2,
        "source_document" => source,
        "rule_document" => rule
      })

    document
  end

  # Trusted, controlled clock/timezone inputs run only in this synchronous
  # borrowed-writer fixture. They establish no installed host/clock authority.
  defp clock_context(store, lower, upper, now, zone) do
    {:ok, binding} = Store.temporal_clock_binding(store)

    sample = %{
      "source_id" => "clock:calendar-fixture",
      "qualification_digest" => String.duplicate("a", 64),
      "boot_epoch" => binding.scope["store_boot_epoch"],
      "generation" => binding.scope["clock_generation"],
      "sampled_monotonic_ms" => now,
      "utc_lower_ms" => lower,
      "utc_upper_ms" => upper,
      "maximum_age_ms" => 60_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }

    snapshot = %{
      scope: binding.scope,
      sample: sample,
      now_ms: now,
      interval: {lower, upper},
      reason: nil
    }

    {:ok, context} =
      ClockContext.new(
        fn -> {binding.scope["store_boot_epoch"], now} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, zone} end
      )

    context
  end

  defp run_step(c, {:time, lower, upper}, _zone), do: %{c | clock: {lower, upper}}

  defp run_step(c, :restart, _zone) do
    assert :ok = GenServer.stop(c.store)

    store =
      start_supervised!(Supervisor.child_spec({Store, path: c.path}, restart: :temporary),
        id: {:restarted, make_ref()}
      )

    assert {:error, :temporal_clock_unavailable} = Store.consider_schedule(store)
    %{c | store: store, clock: nil}
  end

  defp run_step(c, :poll, zone) do
    {lower, upper} = c.clock
    context = clock_context(c.store, lower, upper, 1000 + c.step * 10, zone)

    assert {:ok, {:ok, receipt}} =
             writer(c.store, fn state ->
               SQL.transaction(
                 state.db,
                 &ScheduleOccurrences.consider(&1, context, state.receipt_limit)
               )
             end)

    if is_binary(Map.get(receipt, :occurrence_id)) do
      id = receipt.occurrence_id
      assert {:ok, ^receipt} = Store.original_schedule_occurrence(c.store, c.credential, id)
      %{c | history: Map.put(c.history, id, {receipt, with_db(c.path, &original_rows(&1, id))})}
    else
      c
    end
  end

  defp projection(path, instants) do
    with_db(path, fn db ->
      [[generation]] = rows(db, "SELECT value FROM meta WHERE key='rule_generation'")

      [[watermark]] =
        rows(
          db,
          "SELECT COALESCE(w.considered_through,l.initial_watermark) FROM schedule_lifecycle_operations l LEFT JOIN schedule_watermarks w ON w.activation_revision=l.revision WHERE l.kind='activate' ORDER BY l.revision DESC LIMIT 1"
        )

      [[count, ranges]] =
        rows(
          db,
          "SELECT COUNT(*),COALESCE(SUM(missed_lower IS NOT NULL),0) FROM schedule_considerations"
        )

      missed =
        rows(
          db,
          "SELECT missed_lower,missed_upper FROM schedule_considerations WHERE missed_lower IS NOT NULL"
        )
        |> Enum.reduce(0, fn [lower, upper], total ->
          total + Enum.count(instants, &(&1 > lower and &1 <= upper))
        end)

      records =
        rows(
          db,
          "SELECT s.occurrence_document,COALESCE(r.disposition,'blocked'),CASE WHEN r.principal_id IS NULL THEN COALESCE(e.reason,s.reason) ELSE r.reason END,c.reserved_effects FROM schedule_considerations s LEFT JOIN schedule_effect_operations e ON e.consideration_revision=s.revision LEFT JOIN request_receipts r ON r.principal_id=e.principal_id AND r.authority_epoch=e.authority_epoch AND r.operation_id=e.operation_id LEFT JOIN request_causal_roots c ON c.principal_id=e.principal_id AND c.authority_epoch=e.authority_epoch AND c.operation_id=e.operation_id WHERE s.occurrence_document IS NOT NULL"
        )
        |> Map.new(fn [document, phase, reason, spent] ->
          [_, _, _, _, _, _, ["utc", due]] = JSON.decode!(document)

          {due,
           %{phase: String.to_existing_atom(phase), reason: reason, spent: spent, handed: false}}
        end)

      assert :ok = Integrity.validate_snapshot(db)

      %{
        generation: generation,
        watermark: watermark,
        considerations: count,
        missed: missed,
        missed_ranges: ranges,
        records: records
      }
    end)
  end

  defp original_rows(db, id),
    do: {
      rows(db, "SELECT * FROM schedule_considerations WHERE occurrence_id=?", [id]),
      rows(db, "SELECT * FROM schedule_effect_operations WHERE operation_id=?", [id])
    }

  defp rows(db, sql, params \\ []) do
    {:ok, result} = SQL.query(db, sql, params)
    result
  end

  defp with_db(path, callback) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      callback.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp writer(store, callback) do
    caller = self()
    reference = make_ref()

    :sys.replace_state(store, fn state ->
      send(caller, {reference, callback.(state)})
      state
    end)

    receive do
      {^reference, result} -> result
    after
      20_000 -> flunk("bounded calendar writer fixture did not return")
    end
  end
end
