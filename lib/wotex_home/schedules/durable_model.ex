defmodule WotexHome.Schedules.DurableModel do
  @moduledoc """
  Independent reference for one active fixed-UTC-interval schedule's durable
  traces. This module imports no planner, guard, writer, transport or credential
  code. Its predictions grant no admission, clock confidence or effect authority.
  """

  defstruct anchor: 100_000,
            period: 60_000,
            late: 10_000,
            tolerance: 1_000,
            watermark: 90_000,
            boot: 1,
            generation: 1,
            active: true,
            target_granted: true,
            author_active: true,
            override: false,
            maintenance: false,
            writable: true,
            clock: {100_001, 100_001},
            qualified: true,
            matching_report: false,
            fresh_report: true,
            considerations: 0,
            missed: 0,
            missed_ranges: 0,
            records: %{}

  @unsent [:held, :queued, :claimed]
  @source_fields [:anchor, :period, :late, :tolerance, :watermark]
  @maximum_utc 253_402_300_739_999

  def new, do: %__MODULE__{}

  def new(attributes) when is_map(attributes) and map_size(attributes) == 5 do
    valid =
      Enum.sort(Map.keys(attributes)) == Enum.sort(@source_fields) and
        Enum.all?(Map.values(attributes), &is_integer/1) and
        attributes.anchor in 0..@maximum_utc and
        attributes.period in 60_000..2_678_400_000 and
        attributes.late in 1_000..60_000 and
        attributes.tolerance in 0..30_000 and
        attributes.watermark in -1..@maximum_utc

    if valid, do: {:ok, struct!(__MODULE__, attributes)}, else: {:error, :invalid_trace_source}
  end

  def new(_), do: {:error, :invalid_trace_source}

  def step(%__MODULE__{} = state, {:time, lower, upper})
      when is_integer(lower) and is_integer(upper) and lower >= 0 and upper >= lower and
             upper <= @maximum_utc,
      do: %{state | clock: {lower, upper}}

  def step(%__MODULE__{} = state, :clock_lost), do: %{state | clock: nil}
  def step(%__MODULE__{} = state, :qualification_lost), do: %{state | qualified: false}

  def step(%__MODULE__{} = state, :report_matches),
    do: %{state | matching_report: true, fresh_report: true}

  def step(%__MODULE__{} = state, :refresh_report), do: %{state | fresh_report: true}

  def step(%__MODULE__{} = state, :restart) do
    records =
      Map.new(state.records, fn {due, record} ->
        next =
          if record.phase in [:dispatching, :protocol_accepted],
            do: %{record | phase: :outcome_unknown, reason: "crash_after_handoff"},
            else: record

        {due, next}
      end)

    %{
      state
      | boot: state.boot + 1,
        override: false,
        writable: true,
        clock: nil,
        fresh_report: false,
        records: records
    }
  end

  def step(%__MODULE__{} = state, {:fault, action})
      when action in [
             :poll,
             :advance,
             :claim,
             :handoff,
             :suspend,
             :grant_lost,
             :author_lost,
             :override_on,
             :maintenance_begin,
             :maintenance_end
           ],
      do: %{state | writable: false}

  def step(%__MODULE__{writable: false} = state, _), do: state

  def step(%__MODULE__{active: false} = state, :poll), do: state
  def step(%__MODULE__{clock: nil} = state, :poll), do: state

  def step(%__MODULE__{} = state, :poll) do
    {lower, upper} = state.clock
    cutoff = max(state.watermark, lower - state.late)
    first = first_after(state, cutoff)
    skipped = first_after(state, state.watermark) <= cutoff
    missed = ordinal(state, cutoff) - ordinal(state, state.watermark)
    candidate = first <= lower

    if candidate or skipped do
      state = %{
        state
        | watermark: max(state.watermark, lower),
          considerations: state.considerations + 1,
          missed: state.missed + missed,
          missed_ranges: state.missed_ranges + if(cutoff > state.watermark, do: 1, else: 0)
      }

      if candidate do
        certain = upper - lower <= 2 * state.tolerance and upper < first + state.late

        reason =
          cond do
            not certain -> "clock_uncertain"
            state.override -> "operator_override_active"
            true -> nil
          end

        record = %{
          phase: if(reason == nil, do: :held, else: :blocked),
          reason: reason,
          spent: if(reason == nil, do: 0, else: nil),
          boot: state.boot,
          generation: state.generation,
          handed: false
        }

        %{state | records: Map.put(state.records, first, record)}
      else
        state
      end
    else
      state
    end
  end

  def step(%__MODULE__{} = state, :advance) do
    records =
      Map.new(state.records, fn {due, record} ->
        next =
          if record.phase in @unsent do
            case refusal(state, due, record) do
              nil when record.phase == :held ->
                if state.matching_report,
                  do: %{record | phase: :rejected, reason: "already_reported_no_send"},
                  else: %{record | phase: :queued, spent: 1}

              nil ->
                record

              reason ->
                %{record | phase: :rejected, reason: "schedule_blocked:" <> reason}
            end
          else
            record
          end

        {due, next}
      end)

    %{state | records: records}
  end

  def step(%__MODULE__{} = state, {:claim, due}),
    do: transition(state, due, :queued, :claimed)

  def step(%__MODULE__{} = state, {:handoff, due}),
    do: transition(state, due, :claimed, :dispatching)

  def step(%__MODULE__{} = state, {:ack, due}),
    do: transition(state, due, :dispatching, :protocol_accepted, false)

  def step(%__MODULE__{} = state, {:observed, due}) do
    next = transition(state, due, :protocol_accepted, :observed, false)

    if match?(%{phase: :observed}, next.records[due]),
      do: %{next | matching_report: true, fresh_report: true},
      else: next
  end

  def step(%__MODULE__{} = state, {:cancel, due}) do
    case state.records[due] do
      %{phase: phase} = record when phase in [:held, :queued] ->
        reason = if phase == :held, do: "cancelled", else: "cancelled_before_claim"

        %{
          state
          | records: Map.put(state.records, due, %{record | phase: :rejected, reason: reason})
        }

      _ ->
        state
    end
  end

  def step(%__MODULE__{} = state, :grant_lost) do
    state = %{state | target_granted: false, override: false}
    if state.active, do: fence(state, "target_grant_revoked"), else: state
  end

  def step(%__MODULE__{} = state, :grant_restored),
    do: %{state | target_granted: true, override: false}

  def step(%__MODULE__{} = state, :author_lost) do
    state = %{state | author_active: false, override: false}
    if state.active, do: fence(state, "principal_revoked"), else: state
  end

  def step(%__MODULE__{} = state, :override_on), do: %{state | override: true}
  def step(%__MODULE__{} = state, :override_off), do: %{state | override: false}

  def step(%__MODULE__{} = state, :maintenance_begin),
    do: fence(%{state | maintenance: true}, "rule_generation_fenced")

  def step(%__MODULE__{} = state, :maintenance_end), do: %{state | maintenance: false}

  def step(%__MODULE__{} = state, :suspend), do: fence(state, "rule_generation_fenced")

  def step(%__MODULE__{target_granted: false} = state, :activate), do: state
  def step(%__MODULE__{author_active: false} = state, :activate), do: state
  def step(%__MODULE__{maintenance: true} = state, :activate), do: state

  def step(%__MODULE__{clock: {_, upper}} = state, :activate),
    do: %{state | active: true, generation: state.generation + 1, watermark: upper}

  def step(_, _), do: {:error, :unsupported_trace_event}

  def projection(%__MODULE__{} = state) do
    %{
      active: state.active,
      target_granted: state.target_granted,
      author_active: state.author_active,
      override: state.override,
      maintenance: state.maintenance,
      writable: state.writable,
      generation: state.generation,
      watermark: state.watermark,
      considerations: state.considerations,
      missed: state.missed,
      missed_ranges: state.missed_ranges,
      records:
        Map.new(state.records, fn {due, record} ->
          {due, Map.take(record, [:phase, :reason, :spent, :handed])}
        end)
    }
  end

  defp fence(state, reason) do
    records =
      Map.new(state.records, fn {due, record} ->
        next =
          cond do
            record.phase in @unsent ->
              %{record | phase: :rejected, reason: reason}

            record.phase in [:dispatching, :protocol_accepted] ->
              %{record | phase: :outcome_unknown, reason: reason <> "_after_handoff"}

            true ->
              record
          end

        {due, next}
      end)

    %{state | active: false, generation: state.generation + 1, records: records}
  end

  defp first_after(state, cursor) do
    if cursor < state.anchor,
      do: state.anchor,
      else: state.anchor + (div(cursor - state.anchor, state.period) + 1) * state.period
  end

  defp ordinal(state, cursor) do
    if cursor < state.anchor, do: 0, else: div(cursor - state.anchor, state.period) + 1
  end

  defp transition(state, due, from, to, guarded \\ true) do
    case state.records[due] do
      %{phase: ^from} = record ->
        if not guarded or refusal(state, due, record) == nil do
          record = %{record | phase: to, handed: record.handed or to == :dispatching}
          %{state | records: Map.put(state.records, due, record)}
        else
          state
        end

      _ ->
        state
    end
  end

  defp refusal(state, due, record) do
    cond do
      not state.active or record.generation != state.generation ->
        "schedule_basis_changed"

      record.boot != state.boot ->
        "temporal_basis_changed"

      state.clock == nil ->
        "temporal_clock_unavailable"

      elem(state.clock, 1) - elem(state.clock, 0) > 2 * state.tolerance ->
        "clock_uncertain"

      elem(state.clock, 1) < due ->
        "occurrence_early"

      elem(state.clock, 0) >= due + state.late ->
        "occurrence_expired"

      elem(state.clock, 0) < due or elem(state.clock, 1) >= due + state.late ->
        "clock_uncertain"

      state.override ->
        "operator_override_active"

      not state.fresh_report ->
        "observation_unavailable"

      record.phase != :held and state.matching_report ->
        "basis_changed"

      not state.qualified and not (record.phase == :held and state.matching_report) ->
        "qualification_artifact_unavailable"

      true ->
        nil
    end
  end
end
