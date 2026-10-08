defmodule WotexHome.Schedules.DurableModel do
  @moduledoc """
  Independent reference for one active UTC interval, finite calendar or boot-local countdown's durable
  traces. This module imports no planner, guard, writer, transport or credential
  code. Its predictions grant no admission, clock confidence or effect authority.
  """

  defstruct anchor: 100_000,
            period: 60_000,
            instants: nil,
            countdown: nil,
            clock_generation: 1,
            expiry_reason: nil,
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

  # Calendar instants come from a separate frozen-data oracle, not a Home
  # recurrence helper. The source's exclusive end closes this finite horizon.
  def new_calendar(attributes) when is_map(attributes) and map_size(attributes) == 5 do
    with true <- Enum.sort(Map.keys(attributes)) == ~w(finish instants late tolerance watermark)a,
         %{
           instants: instants,
           finish: finish,
           late: late,
           tolerance: tolerance,
           watermark: watermark
         } <- attributes,
         true <- is_list(instants) and length(instants) in 1..64,
         true <- is_integer(finish) and finish in 1..@maximum_utc,
         true <- is_integer(watermark) and watermark in -1..(finish - 1),
         true <- is_integer(late) and late in 1_000..60_000,
         true <- is_integer(tolerance) and tolerance in 0..30_000,
         true <- Enum.all?(instants, &(is_integer(&1) and &1 in 0..(finish - 1))),
         true <- instants == Enum.sort(Enum.uniq(instants)),
         true <-
           Enum.all?(Enum.chunk_every(instants, 2, 1, :discard), fn [a, b] -> b - a >= 60_000 end) do
      {:ok,
       %__MODULE__{instants: instants, late: late, tolerance: tolerance, watermark: watermark}}
    else
      _ -> {:error, :invalid_trace_source}
    end
  end

  def new_calendar(_), do: {:error, :invalid_trace_source}

  def new_countdown(attributes) when is_map(attributes) and map_size(attributes) == 5 do
    with true <-
           Enum.sort(Map.keys(attributes)) == ~w(clock_generation duration late start watermark)a,
         %{
           start: start,
           duration: duration,
           late: late,
           watermark: watermark,
           clock_generation: generation
         } <- attributes,
         true <- Enum.all?([start, duration, late, watermark, generation], &is_integer/1),
         true <- start >= 0 and duration in 1_000..86_400_000 and late in 1_000..60_000,
         true <- start + duration + late <= 9_223_372_036_854_775_807,
         true <- watermark >= start and watermark < start + duration,
         true <- generation in 1..9_223_372_036_854_775_807 do
      {:ok,
       %__MODULE__{
         countdown: %{due: start + duration, generation: generation},
         anchor: start + duration,
         watermark: watermark,
         late: late,
         clock: {watermark, watermark},
         clock_generation: generation
       }}
    else
      _ -> {:error, :invalid_trace_source}
    end
  end

  def new_countdown(_), do: {:error, :invalid_trace_source}

  def step(%__MODULE__{countdown: countdown} = state, {:monotonic, now})
      when countdown != nil and is_integer(now) and now in 0..9_223_372_036_854_775_807,
      do: %{state | clock: {now, now}}

  def step(%__MODULE__{countdown: countdown} = state, :clock_restored) when countdown != nil,
    do: %{state | clock: {state.watermark, state.watermark}}

  def step(%__MODULE__{countdown: countdown, writable: true} = state, :clock_withdrawn)
      when countdown != nil do
    generation =
      if state.clock_generation < 9_223_372_036_854_775_807,
        do: state.clock_generation + 1,
        else: 0

    state = %{state | clock_generation: generation, clock: nil}
    if state.active, do: expire_countdown(state, "countdown_missed:clock_changed"), else: state
  end

  def step(%__MODULE__{countdown: nil} = state, {:time, lower, upper})
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

    restarted = %{
      state
      | boot: state.boot + 1,
        override: false,
        writable: true,
        clock: nil,
        clock_generation: 1,
        fresh_report: false,
        records: records
    }

    if state.countdown != nil and state.active,
      do: expire_countdown(restarted, "countdown_missed:old_boot"),
      else: restarted
  end

  def step(%__MODULE__{countdown: countdown} = state, {:fault, :clock_withdrawn})
      when countdown != nil,
      do: %{state | writable: false}

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

  def step(%__MODULE__{countdown: countdown, clock: nil} = state, event)
      when countdown != nil and event in [:poll, :advance],
      do: expire_countdown(state, "countdown_missed:clock_unavailable")

  def step(%__MODULE__{clock: nil} = state, :poll), do: state

  def step(%__MODULE__{countdown: %{due: due}} = state, :poll) do
    {now, now} = state.clock

    if now >= due and state.watermark < due do
      reason =
        cond do
          now >= due + state.late -> "occurrence_expired"
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

      %{
        state
        | watermark: now,
          considerations: state.considerations + 1,
          records: Map.put(state.records, due, record)
      }
    else
      state
    end
  end

  def step(%__MODULE__{} = state, :poll) do
    {lower, upper} = state.clock
    cutoff = max(state.watermark, lower - state.late)
    first = first_after(state, cutoff)
    previous_next = first_after(state, state.watermark)
    skipped = previous_next != nil and previous_next <= cutoff
    missed = ordinal(state, cutoff) - ordinal(state, state.watermark)
    candidate = first != nil and first <= lower

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

  def step(%__MODULE__{countdown: countdown, active: true, clock: nil} = state, {event, _due})
      when countdown != nil and event in [:claim, :handoff],
      do: expire_countdown(state, "countdown_missed:clock_unavailable")

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

  def step(
        %__MODULE__{countdown: %{due: due, generation: original}, clock: {now, now}} = state,
        :activate
      ) do
    if state.boot == 1 and state.clock_generation == original and state.expiry_reason == nil and
         now < due,
       do: %{state | active: true, generation: state.generation + 1, watermark: now},
       else: state
  end

  def step(%__MODULE__{countdown: countdown} = state, :activate) when countdown != nil, do: state

  def step(%__MODULE__{clock: {_, upper}} = state, :activate),
    do: %{state | active: true, generation: state.generation + 1, watermark: upper}

  def step(_, _), do: {:error, :unsupported_trace_event}

  def projection(%__MODULE__{} = state) do
    projection = %{
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

    if state.countdown == nil,
      do: projection,
      else:
        Map.merge(projection, %{
          clock_generation: state.clock_generation,
          expiry_reason: state.expiry_reason
        })
  end

  defp expire_countdown(%{active: false} = state, _), do: state

  defp expire_countdown(state, reason),
    do: %{fence(state, "rule_generation_fenced") | expiry_reason: reason}

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

  defp first_after(%{instants: instants}, cursor) when is_list(instants),
    do: Enum.find(instants, &(&1 > cursor))

  defp first_after(state, cursor) do
    if cursor < state.anchor,
      do: state.anchor,
      else: state.anchor + (div(cursor - state.anchor, state.period) + 1) * state.period
  end

  defp ordinal(%{instants: instants}, cursor) when is_list(instants),
    do: Enum.count(instants, &(&1 <= cursor))

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
