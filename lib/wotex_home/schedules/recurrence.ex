defmodule WotexHome.Schedules.Recurrence do
  @moduledoc "Bounded pure recurrence under exact immutable timezone bytes. No registration, trusted clock or catch-up effects."
  alias WotexHome.Schedules.{Codec, Tzif}

  def next(source, after_ms, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.integer?(after_ms, -1, Codec.utc_maximum() - 60_000),
         :ok <- validate_source(source, zone) do
      next_trigger(source["trigger"], after_ms, zone)
    else
      false -> {:error, :invalid_schedule_cursor}
      error -> error
    end
  end

  def validate_source(source, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source) do
      case source["trigger"] do
        ["once", _, _, date, time, due] = trigger ->
          with :ok <- calendar_basis(trigger, zone),
               {:ok, local} <- NaiveDateTime.from_iso8601(date <> "T" <> time),
               {:ok, instants} <- Tzif.resolve(zone, local),
               true <- due in instants,
               do: :ok,
               else: (
                 false -> {:error, :invalid_resolved_schedule_time}
                 error -> error
               )

        [kind | _] = trigger when kind in ["daily", "weekdays"] ->
          calendar_basis(trigger, zone)

        _ ->
          :ok
      end
    end
  end

  def coordinate(source, due, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.utc?(due),
         :ok <- validate_source(source, zone) do
      member(source["trigger"], due, zone)
    else
      false -> {:error, :schedule_coordinate_mismatch}
      error -> error
    end
  end

  defp calendar_basis([_, name, digest | _], %Tzif{} = zone) do
    if zone.name == name and zone.digest == digest and Tzif.valid?(zone),
      do: :ok,
      else: {:error, :timezone_basis_mismatch}
  end

  defp calendar_basis(_, _), do: {:error, :timezone_basis_required}

  defp next_trigger(["once", _, _, _, _, due], after_ms, _),
    do: {:ok, if(due > after_ms, do: due)}

  defp next_trigger(["interval", anchor, period, start, finish], after_ms, _) do
    lower = max(start, after_ms + 1)
    index = if lower <= anchor, do: 0, else: div(lower - anchor + period - 1, period)
    due = anchor + index * period
    {:ok, if(Codec.utc?(due) and (finish == nil or due < finish), do: due)}
  end

  defp next_trigger([kind | _] = trigger, after_ms, zone) when kind in ["daily", "weekdays"] do
    {time, days, start, finish} = calendar(trigger)
    seed = max(start, after_ms + 1)

    if seed > Codec.utc_maximum() - 60_000 or (finish != nil and seed >= finish) do
      {:ok, nil}
    else
      with {:ok, local} <- local(zone, seed) do
        date = if local.year < 1970, do: ~D[1970-01-01], else: NaiveDateTime.to_date(local)
        find_date(zone, date, time, days, start, finish, after_ms, 32)
      else
        # A valid UTC seed plus a validated bounded offset can exceed the
        # supported local calendar only beyond its final year. No later local
        # label can create another supported coordinate.
        {:error, :invalid_unix_time} -> {:ok, nil}
        error -> error
      end
    end
  end

  defp next_trigger(["countdown" | _], _, _), do: {:error, :monotonic_schedule}

  defp find_date(_, _, _, _, _, _, _, 0), do: {:error, :calendar_search_horizon}

  defp find_date(zone, date, time, days, start, finish, after_ms, remaining) do
    with {:ok, local} <- NaiveDateTime.new(date, Time.from_iso8601!(time)),
         {:ok, instants} <-
           if(Date.day_of_week(date) in days, do: Tzif.resolve(zone, local), else: {:ok, []}) do
      # Fold policy selects the first instant even if it has already passed.
      first = List.first(instants)

      cond do
        first != nil and finish != nil and first >= finish ->
          {:ok, nil}

        first != nil and first > after_ms and first >= start ->
          {:ok, first}

        date.year == 9999 and date.month == 12 and date.day == 31 ->
          {:ok, nil}

        true ->
          find_date(zone, Date.add(date, 1), time, days, start, finish, after_ms, remaining - 1)
      end
    end
  end

  defp member(["once", _, _, _, _, due], due, _), do: :ok

  defp member(["interval", anchor, period, start, finish], due, _) do
    if due >= anchor and due >= start and (finish == nil or due < finish) and
         rem(due - anchor, period) == 0,
       do: :ok,
       else: {:error, :schedule_coordinate_mismatch}
  end

  defp member([kind | _] = trigger, due, zone) when kind in ["daily", "weekdays"] do
    {time, days, start, finish} = calendar(trigger)

    with true <- due >= start and (finish == nil or due < finish) and rem(due, 1_000) == 0,
         {:ok, local} <- local(zone, due),
         true <-
           Time.to_iso8601(NaiveDateTime.to_time(local)) == time and
             Date.day_of_week(NaiveDateTime.to_date(local)) in days,
         {:ok, [^due | _]} <- Tzif.resolve(zone, local),
         do: :ok,
         else: (_ -> {:error, :schedule_coordinate_mismatch})
  end

  defp member(_, _, _), do: {:error, :schedule_coordinate_mismatch}

  defp calendar(["daily", _, _, time, start, finish]),
    do: {time, Enum.to_list(1..7), start, finish}

  defp calendar(["weekdays", _, _, time, days, start, finish]), do: {time, days, start, finish}

  defp local(zone, utc_ms) do
    with {:ok, %{offset: offset}} <- Tzif.offset(zone, utc_ms),
         {:ok, shifted} <- DateTime.from_unix(utc_ms + offset * 1_000, :millisecond),
         do: {:ok, shifted |> DateTime.truncate(:second) |> DateTime.to_naive()}
  end
end
