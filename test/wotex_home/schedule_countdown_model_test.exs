defmodule WotexHome.ScheduleCountdownModelTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.DurableModel, as: Model

  @maximum 9_223_372_036_854_775_807
  @source %{start: 1_000, duration: 60_000, late: 10_000, watermark: 2_000, clock_generation: 1}

  test "the independent countdown source is closed and uses signed monotonic bounds rather than UTC" do
    assert {:ok, _} = Model.new_countdown(@source)
    assert {:ok, _} = Model.new_countdown(%{@source | duration: 1_000, watermark: 1_999})
    assert {:ok, _} = Model.new_countdown(%{@source | duration: 86_400_000})

    assert {:ok, _} =
             Model.new_countdown(%{
               @source
               | start: @maximum - 70_000,
                 watermark: @maximum - 69_000
             })

    for changed <- [
          Map.put(@source, :utc, true),
          Map.delete(@source, :watermark),
          %{@source | start: -1},
          %{@source | duration: 999},
          %{@source | duration: 86_400_001},
          %{@source | duration: 60_000.0},
          %{@source | late: 999},
          %{@source | late: 60_001},
          %{@source | watermark: 999},
          %{@source | watermark: 61_000},
          %{@source | clock_generation: 0},
          %{@source | clock_generation: @maximum + 1},
          %{@source | start: @maximum - 69_999, watermark: @maximum - 69_000}
        ] do
      assert {:error, :invalid_trace_source} = Model.new_countdown(changed)
    end

    assert {:error, :invalid_trace_source} = Model.new_countdown(nil)
    {:ok, model} = Model.new_countdown(@source)
    assert {:error, :unsupported_trace_event} = Model.step(model, {:time, 61_000, 61_000})
    assert {:error, :unsupported_trace_event} = Model.step(model, {:monotonic, -1})
    assert {:error, :unsupported_trace_event} = Model.step(model, {:monotonic, @maximum + 1})
    assert {:error, :unsupported_trace_event} = Model.step(Model.new(), {:monotonic, 61_000})

    assert {:error, :unsupported_trace_event} =
             Model.step(Model.new(), {:fault, :clock_withdrawn})
  end

  test "one-second through one-day countdowns consume exactly once at the half-open boundaries" do
    for duration <- [1_000, 60_000, 86_400_000], late <- [1_000, 10_000, 60_000] do
      {:ok, initial} =
        Model.new_countdown(%{@source | duration: duration, late: late, watermark: 1_000})

      due = initial.anchor
      early = run(initial, [{:monotonic, due - 1}, :poll])
      assert early.records == %{} and early.considerations == 0

      for now <- [due, due + late - 1] do
        held = run(initial, [{:monotonic, now}, :poll, :poll])
        assert held.considerations == 1 and map_size(held.records) == 1
        assert %{phase: :held, spent: 0, reason: nil} = held.records[due]
      end

      expired = run(initial, [{:monotonic, due + late}, :poll, :poll, :advance])
      assert expired.considerations == 1 and map_size(expired.records) == 1
      assert %{phase: :blocked, spent: nil, reason: "occurrence_expired"} = expired.records[due]
      assert expired.missed == 0 and expired.missed_ranges == 0
      assert Model.step(expired, {:monotonic, due}).records == expired.records
    end
  end

  test "restart fences every phase once, preserves spend and recovers only committed handoffs" do
    {:ok, initial} = Model.new_countdown(@source)
    due = initial.anchor

    prefixes = [
      [],
      [:advance],
      [:advance, {:claim, due}],
      [:advance, {:claim, due}, {:handoff, due}]
    ]

    prefixes =
      prefixes ++
        [
          List.last(prefixes) ++ [{:ack, due}],
          List.last(prefixes) ++ [{:ack, due}, {:observed, due}]
        ]

    for prefix <- prefixes do
      before = run(initial, [{:monotonic, due}, :poll] ++ prefix)
      restarted = Model.step(before, :restart)
      assert restarted.active == false and restarted.generation == 2
      assert restarted.expiry_reason == "countdown_missed:old_boot"
      assert restarted.records[due].spent == before.records[due].spent

      case before.records[due].phase do
        phase when phase in [:held, :queued, :claimed] ->
          assert %{phase: :rejected, reason: "rule_generation_fenced", handed: false} =
                   restarted.records[due]

        phase when phase in [:dispatching, :protocol_accepted] ->
          assert %{phase: :outcome_unknown, reason: "crash_after_handoff", handed: true} =
                   restarted.records[due]

        :observed ->
          assert restarted.records == before.records
      end

      twice = Model.step(restarted, :restart)
      assert twice.records == restarted.records and twice.generation == 2
      assert twice.expiry_reason == restarted.expiry_reason
      assert run(twice, [:clock_restored, :activate, :poll]).active == false
    end
  end

  test "observed clock loss is sticky even when the same original clock returns before due" do
    {:ok, initial} = Model.new_countdown(@source)
    missed = run(initial, [:clock_lost, :poll, :clock_restored, :activate, :poll])
    assert missed.active == false and missed.generation == 2
    assert missed.expiry_reason == "countdown_missed:clock_unavailable"
    assert missed.records == %{} and missed.considerations == 0
    assert Model.step(missed, :restart).expiry_reason == missed.expiry_reason
    suspended = run(initial, [:suspend, :activate])
    assert suspended.active == true and suspended.generation == 3
    assert suspended.expiry_reason == nil
    assert run(initial, [:suspend, {:monotonic, initial.anchor}, :activate]).active == false
  end

  test "generation withdrawal and failed publication preserve the original clock and durable phase" do
    {:ok, initial} = Model.new_countdown(@source)
    due = initial.anchor
    claimed = run(initial, [{:monotonic, due}, :poll, :advance, {:claim, due}])
    failed = Model.step(claimed, {:fault, :clock_withdrawn})
    assert failed == %{claimed | writable: false}
    assert Model.step(failed, :clock_withdrawn) == failed
    restarted = Model.step(failed, :restart)
    assert restarted.records[due].spent == 1
    assert restarted.expiry_reason == "countdown_missed:old_boot"
    withdrawn = Model.step(claimed, :clock_withdrawn)
    assert withdrawn.clock_generation == 2 and withdrawn.generation == 2
    assert withdrawn.expiry_reason == "countdown_missed:clock_changed"
    assert withdrawn.records[due].spent == 1 and withdrawn.records[due].handed == false
    assert run(withdrawn, [:clock_restored, :activate, :poll]).active == false

    {:ok, exhausted} = Model.new_countdown(%{@source | clock_generation: @maximum})
    assert Model.step(exhausted, :clock_withdrawn).clock_generation == 0
  end

  test "the frozen execution corpus has closed bounded events and independently conserves every root" do
    path = Path.expand("../fixtures/schedules/countdown_execution_trace_vectors.json", __DIR__)
    bytes = File.read!(path)
    assert byte_size(bytes) <= 65_536
    corpus = JSON.decode!(bytes)
    assert Enum.sort(Map.keys(corpus)) == ~w(format scope vectors)
    assert corpus["format"] == "wotex-home.countdown-execution-traces.v1"
    assert corpus["scope"] == "single_countdown_execution_durable_software_correspondence"
    assert length(corpus["vectors"]) == 68
    ids = Enum.map(corpus["vectors"], & &1["id"])
    assert Enum.uniq(ids) == ids

    assert Enum.sort(Enum.uniq(Enum.map(corpus["vectors"], & &1["wall"]))) ==
             ~w(qualified unqualified)

    for vector <- corpus["vectors"] do
      assert Enum.sort(Map.keys(vector)) == ~w(duration id steps wall)
      assert vector["id"] =~ ~r/\A[a-z][a-z0-9_]{0,95}\z/
      assert vector["duration"] in [60_000, 86_400_000]
      assert vector["wall"] in ~w(qualified unqualified)
      assert length(vector["steps"]) in 1..32
      {:ok, model} = Model.new_countdown(%{@source | duration: vector["duration"]})
      due = model.anchor

      Enum.reduce(vector["steps"], model, fn event, before ->
        closed =
          case event do
            ["monotonic", offset] ->
              assert offset in [-10_000, 1, 10_000]
              {:monotonic, due + offset}

            ["fault", action] ->
              assert action in ~w(poll advance claim handoff clock_withdrawn)
              {:fault, String.to_existing_atom(action)}

            action ->
              assert action in ~w(poll poll_lost_reply advance claim handoff ack observed cancel restart clock_lost clock_restored clock_withdrawn suspend activate report_matches refresh_report grant_lost grant_restored author_lost override_on override_off maintenance_begin maintenance_end)

              cond do
                action == "poll_lost_reply" ->
                  :poll

                action in ~w(claim handoff ack observed cancel) ->
                  {String.to_existing_atom(action), due}

                true ->
                  String.to_existing_atom(action)
              end
          end

        assert %Model{} = after_event = Model.step(before, closed)
        assert map_size(after_event.records) <= 1
        assert after_event.missed == 0 and after_event.missed_ranges == 0

        for {coordinate, record} <- before.records do
          after_record = after_event.records[coordinate]

          if is_integer(record.spent),
            do: assert(is_integer(after_record.spent) and after_record.spent >= record.spent),
            else: assert(after_record.spent == nil)

          if record.handed, do: assert(after_record.handed)
        end

        after_event
      end)
    end
  end

  defp run(model, events), do: Enum.reduce(events, model, &Model.step(&2, &1))
end
