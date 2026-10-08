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
            assert action in ~w(poll advance claim handoff suspend)

          action when is_binary(action) ->
            assert action in ~w(poll advance claim handoff ack observed cancel suspend activate restart qualification_lost report_matches refresh_report)

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

  defp run(events), do: Enum.reduce(events, Model.new(), &Model.step(&2, &1))
end
