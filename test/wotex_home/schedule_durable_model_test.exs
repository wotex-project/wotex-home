defmodule WotexHome.ScheduleDurableModelTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.DurableModel, as: Model

  test "the checked-in executable corpus has a closed scope, unique bounded traces and no opaque actions" do
    path = Path.expand("../fixtures/schedules/durable_trace_vectors.json", __DIR__)
    bytes = File.read!(path)
    assert byte_size(bytes) <= 65_536
    corpus = JSON.decode!(bytes)
    assert Enum.sort(Map.keys(corpus)) == ~w(format scope vectors)
    assert corpus["format"] == "wotex-home.schedule-durable-traces.v1"
    assert corpus["scope"] == "single_utc_interval_durable_software_correspondence"
    assert length(corpus["vectors"]) in 1..64
    ids = Enum.map(corpus["vectors"], & &1["id"])
    assert length(Enum.uniq(ids)) == length(ids)

    for vector <- corpus["vectors"] do
      assert Enum.sort(Map.keys(vector)) == ~w(id steps)
      assert vector["id"] =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/
      assert length(vector["steps"]) in 1..32

      for step <- vector["steps"] do
        case step do
          ["time", lower, upper] ->
            assert is_integer(lower) and is_integer(upper)
            assert lower >= 0 and upper >= lower and upper <= 253_402_300_739_999

          ["fault", action] ->
            assert action in ~w(poll advance claim handoff suspend grant_lost override_on maintenance_begin maintenance_end)

          action when is_binary(action) ->
            assert action in ~w(poll advance claim handoff ack observed cancel suspend activate restart qualification_lost report_matches refresh_report grant_lost grant_restored override_on override_off maintenance_begin maintenance_end)

          _ ->
            flunk("unsupported corpus action: #{inspect(step)}")
        end
      end
    end
  end

  test "closed independent source attributes refuse unknown, noninteger and unsupported bounds" do
    source = %{anchor: 0, period: 60_000, late: 1_000, tolerance: 0, watermark: -1}
    assert {:ok, _} = Model.new(source)

    for changed <- [
          Map.put(source, :author, true),
          Map.delete(source, :watermark),
          %{source | anchor: -1},
          %{source | anchor: 253_402_300_740_000},
          %{source | period: 59_999},
          %{source | period: 2_678_400_001},
          %{source | late: 60_001},
          %{source | tolerance: 30_001},
          %{source | watermark: -2},
          %{source | period: 60_000.0}
        ] do
      assert {:error, :invalid_trace_source} = Model.new(changed)
    end

    assert {:error, :unsupported_trace_event} = Model.step(Model.new(), :send)
    assert {:error, :unsupported_trace_event} = Model.step(Model.new(), {:fault, :send})

    assert {:error, :unsupported_trace_event} =
             Model.step(Model.new(), {:time, 0, 253_402_300_740_000})
  end

  test "one considered uncertain coordinate cannot acquire a root when time narrows" do
    state = run([{:time, 100_000, 102_001}, :poll, {:time, 100_001, 100_001}, :poll, :advance])
    assert state.considerations == 1
    assert state.watermark == 100_000
    assert %{phase: :blocked, spent: nil, reason: "clock_uncertain"} = state.records[100_000]
  end

  test "long downtime summarizes missed windows and creates only one current candidate" do
    state = run([{:time, 960_100_000, 960_100_000}, :poll, :poll])
    assert map_size(state.records) == 1
    assert state.considerations == 1
    assert state.missed == 16_000
    assert state.missed_ranges == 1
    assert state.watermark == 960_100_000
  end

  test "an empty early poll and a backward correction do not publish or rewind" do
    state = run([{:time, 99_999, 99_999}, :poll, {:time, 80_000, 80_000}, :poll])
    assert state.watermark == 90_000
    assert state.considerations == 0
    assert state.records == %{}
  end

  test "no-send retains zero spend while queue, claim, cancellation and restart conserve one spend" do
    assert %{phase: :rejected, reason: "already_reported_no_send", spent: 0} =
             run([:report_matches, :poll, :advance]).records[100_000]

    assert %{phase: :rejected, reason: "cancelled_before_claim", spent: 1} =
             run([:poll, :advance, {:cancel, 100_000}, :restart]).records[100_000]

    assert %{phase: :claimed, spent: 1, handed: false} =
             run([:poll, :advance, {:claim, 100_000}, :restart]).records[100_000]
  end

  test "tentative SQL failure remains unsent; only a committed handoff becomes uncertain on restart" do
    state = run([:poll, :advance, {:claim, 100_000}, {:fault, :handoff}])
    assert state.writable == false
    assert %{phase: :claimed, handed: false, spent: 1} = state.records[100_000]

    state = Model.step(state, :restart)
    assert state.writable == true
    assert %{phase: :claimed, handed: false, spent: 1} = state.records[100_000]

    assert %{phase: :outcome_unknown, handed: true, spent: 1, reason: "crash_after_handoff"} =
             run([:poll, :advance, {:claim, 100_000}, {:handoff, 100_000}, :restart]).records[
               100_000
             ]
  end

  test "suspension preserves handed uncertainty and explicit reactivation excludes earlier coordinates" do
    state =
      run([:poll, :advance, {:claim, 100_000}, {:handoff, 100_000}, :suspend, :activate, :poll])

    assert state.generation == 3
    assert state.considerations == 1
    assert %{phase: :outcome_unknown, handed: true, spent: 1} = state.records[100_000]
  end

  test "qualified restarted definition needs a fresh report; a consumed old-boot root remains terminal" do
    state =
      run([
        :poll,
        :restart,
        {:time, 100_001, 100_001},
        :advance,
        :poll,
        :refresh_report,
        {:time, 160_001, 160_001},
        :poll,
        :advance
      ])

    assert %{phase: :rejected, spent: 0, reason: "schedule_blocked:temporal_basis_changed"} =
             state.records[100_000]

    assert %{phase: :queued, spent: 1} = state.records[160_000]
    assert state.considerations == 2
  end

  test "grant loss fences every unsent phase and conserves committed spend and uncertainty" do
    for pending <- [[], [:advance], [:advance, {:claim, 100_000}]] do
      state = run([:poll] ++ pending ++ [:grant_lost])
      assert state.active == false
      assert state.target_granted == false
      assert state.generation == 2

      assert %{phase: :rejected, reason: "target_grant_revoked", handed: false} =
               state.records[100_000]

      assert state.records[100_000].spent == if(pending == [], do: 0, else: 1)
    end

    for accepted <- [[], [{:ack, 100_000}]] do
      state =
        run(
          [:poll, :advance, {:claim, 100_000}, {:handoff, 100_000}] ++ accepted ++ [:grant_lost]
        )

      assert %{
               phase: :outcome_unknown,
               reason: "target_grant_revoked_after_handoff",
               spent: 1,
               handed: true
             } = state.records[100_000]
    end
  end

  test "restoring a grant needs explicit activation and cannot replay the original coordinate" do
    withdrawn = run([:poll, :advance, :grant_lost])
    assert Model.step(withdrawn, :activate) == withdrawn
    restored = Model.step(withdrawn, :grant_restored)
    assert restored.active == false
    assert restored.generation == 2
    assert Model.step(restored, :poll) == restored
    active = Model.step(restored, :activate)
    assert active.generation == 3
    assert Model.step(active, :poll).considerations == 1
    assert active.records == withdrawn.records
  end

  test "failed grant withdrawal preserves grant, original activation and pending work" do
    original = run([:poll, :advance, {:claim, 100_000}])
    failed = Model.step(original, {:fault, :grant_lost})
    assert failed == %{original | writable: false}
    assert Model.step(failed, :grant_lost) == failed
    assert Model.step(failed, :restart).target_granted == true
  end

  test "override at consumption is terminal without a root while later loss conserves spend" do
    blocked = run([:override_on, :poll, :override_off, :poll, :advance])

    assert %{phase: :blocked, reason: "operator_override_active", spent: nil} =
             blocked.records[100_000]

    assert blocked.considerations == 1
    queued = run([:poll, :advance, :override_on, {:claim, 100_000}])
    assert queued.records[100_000].phase == :queued
    assert queued.records[100_000].spent == 1
    rejected = Model.step(queued, :advance)
    assert rejected.records[100_000].reason == "schedule_blocked:operator_override_active"
    assert rejected.records[100_000].spent == 1

    resumed =
      run([:poll, :advance, :override_on, {:claim, 100_000}, :override_off, {:claim, 100_000}])

    assert resumed.records[100_000].phase == :claimed
  end

  test "maintenance persists across restart and ending it cannot reactivate the old generation" do
    original = run([:poll, :advance, {:claim, 100_000}, {:handoff, 100_000}])
    maintained = Model.step(original, :maintenance_begin)
    assert maintained.maintenance == true
    assert maintained.active == false
    assert maintained.generation == 2
    assert Model.step(maintained, :activate) == maintained
    assert maintained.records[100_000].reason == "rule_generation_fenced_after_handoff"
    assert maintained.records[100_000].spent == 1
    restarted = Model.step(maintained, :restart)
    assert restarted.maintenance == true
    ended = Model.step(restarted, :maintenance_end)
    assert ended.maintenance == false
    assert ended.active == false
    assert ended.generation == 2
    assert ended.records == maintained.records
  end

  test "override expiry on restart and publication failures preserve immutable work" do
    original = run([:poll, :advance, :override_on])
    assert Model.step(original, :restart).override == false

    for action <- [:override_on, :maintenance_begin] do
      state = run([:poll, :advance])
      assert Model.step(state, {:fault, action}) == %{state | writable: false}
    end

    maintained = run([:poll, :advance, :maintenance_begin])
    assert Model.step(maintained, {:fault, :maintenance_end}) == %{maintained | writable: false}
  end

  defp run(events), do: Enum.reduce(events, Model.new(), &Model.step(&2, &1))
end
