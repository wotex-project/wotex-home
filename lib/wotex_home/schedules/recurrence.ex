defmodule WotexHome.Schedules.Recurrence do
  @moduledoc """
  Calculates and checks supported schedule coordinates from an exact source.

  `next/3` returns `{:ok, due_or_nil}` strictly after the supplied UTC
  millisecond cursor. UTC intervals use integer arithmetic. Calendar sources
  delegate to `WotexHome.Schedules.RoutineCalendar` and require the exact
  immutable timezone name, digest and bytes.

  Calendar search considers at most 32 successive local dates in local-date
  order. Recurring labels skip gaps and select their first resolved instant
  before checking cursor and source bounds; a passed first fold never
  substitutes a later alternative. One-shots retain their explicitly reviewed
  resolved instant, which may belong to any position in an ambiguity.
  Producer unavailability or refusal propagates without a legacy calculator
  or host timezone fallback.

  `validate_source/2` checks the source and calendar basis, including a
  one-shot's reviewed choice. `coordinate/3` checks exact membership.
  Both return `:ok` or `{:error, reason}` without registering a schedule.
  Countdowns require their separate monotonic path; `next/3` returns
  `{:error, :monotonic_schedule}` for those sources.

  Calculation preserves Home's coordinate and occurrence identity semantics.
  It supplies no clock confidence, catch-up effects, durable occurrence
  consumption or admission authority.
  """

  alias WotexHome.Schedules.{Codec, RoutineCalendar}

  @calendar ~w(once daily weekdays)

  def next(source, after_ms, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.integer?(after_ms, -1, Codec.utc_maximum() - 60_000) do
      case source["trigger"] do
        [kind | _] when kind in @calendar -> RoutineCalendar.next(source, after_ms, zone)
        trigger -> next_trigger(trigger, after_ms)
      end
    else
      false -> {:error, :invalid_schedule_cursor}
      error -> error
    end
  end

  def validate_source(source, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source) do
      case source["trigger"] do
        [kind | _] when kind in @calendar -> RoutineCalendar.validate_source(source, zone)
        _ -> :ok
      end
    end
  end

  def coordinate(source, due, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.utc?(due) do
      case source["trigger"] do
        [kind | _] when kind in @calendar -> RoutineCalendar.coordinate(source, due, zone)
        trigger -> member(trigger, due)
      end
    else
      false -> {:error, :schedule_coordinate_mismatch}
      error -> error
    end
  end

  defp next_trigger(["interval", anchor, period, start, finish], after_ms) do
    lower = max(start, after_ms + 1)
    index = if lower <= anchor, do: 0, else: div(lower - anchor + period - 1, period)
    due = anchor + index * period
    {:ok, if(Codec.utc?(due) and (finish == nil or due < finish), do: due)}
  end

  defp next_trigger(["countdown" | _], _), do: {:error, :monotonic_schedule}

  defp member(["interval", anchor, period, start, finish], due) do
    if due >= anchor and due >= start and (finish == nil or due < finish) and
         rem(due - anchor, period) == 0,
       do: :ok,
       else: {:error, :schedule_coordinate_mismatch}
  end

  defp member(_, _), do: {:error, :schedule_coordinate_mismatch}
end
