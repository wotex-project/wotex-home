defmodule WotexHome.Schedules.RoutineCalendar do
  @moduledoc """
  Calculates Home calendar candidates through the optional public civil producer.

  Supply a closed once/daily/weekdays source and a fully checked
  `WotexHome.Schedules.Tzif` value matching its timezone name and digest.
  Calculation uses `WotexHome.Schedules.CivilTimezone` and only public WoTEx
  civil seams, without an RRULE anchor, ordinal or fallback calculator.
  Interval and countdown sources do not enter this calendar seam.

  `resolve/3` takes an exact whole-second nominal label matching the source and
  returns `{:ok, instants}`: the complete UTC-ordered set of at most 258 original
  millisecond coordinates. Gaps and nonselected weekdays produce an empty set.
  Source windows and cursors do not trim this set. A one-shot's reviewed choice
  must belong to it; the choice may be any position in an ambiguity.

  `validate_source/2` returns `:ok` after source/basis validation, including that
  one-shot choice check. `next/3` returns `{:ok, due_or_nil}` strictly after the
  supplied UTC cursor. Recurring sources search at most 32 successive local
  dates in local-date order, choosing each label's first instant before checking
  cursor/start/end bounds. A passed first fold never substitutes a later fold.
  Gaps advance the date; exhausted search returns
  `{:error, :calendar_search_horizon}`
  unless the source end or final supported date has established completion.
  `coordinate/3` returns `:ok` for exact membership: recurring sources retain
  this first-fold policy, while a one-shot retains its reviewed instant.

  Failures return `{:error, reason}`. Missing public producer capability maps to
  `:routine_calendar_unavailable`, its whole-query work refusal to
  `:routine_calendar_work_bound`, and other producer refusals to
  `:routine_calendar_refused`. Malformed projections or producer faults use
  `:invalid_routine_calendar_projection`; source, basis, cursor and membership
  checks retain their specific atom refusals. No partial result or implicit
  retry is returned, and undefined data does not become a gap.

  This pure candidate is independently comparable before runtime adoption.
  Generic projection IDs never replace Home occurrence IDs. Current compiled
  code, Store admission, author grants, clock trust and effects have separate
  owners; calling this module establishes none of those facts.
  """

  alias WotexHome.Schedules.{CivilTimezone, Codec, Tzif}

  @producer_basis "sha256:" <>
                    Base.encode16(
                      :crypto.hash(:sha256, "wotex-home.routine-civil-calculation.v1"),
                      case: :lower
                    )
  @limits %{
    "max_bytes" => 1_048_576,
    "max_depth" => 32,
    "max_nodes" => 100_000,
    "max_string_bytes" => 65_536,
    "max_collection_size" => 1024,
    "max_integer" => 9_223_372_036_854_775_807
  }
  @time %{
    "clock_generation" => "civil-calculation:1",
    "epoch" => "civil-calculation:1",
    "elapsed_ms" => 0,
    "utc_low_ms" => nil,
    "utc_high_ms" => nil
  }
  @seams [
    {Wotex.Routines.Limits, :new, 1},
    {Wotex.Routines.Schedule, :semantic_digest, 2},
    {Wotex.Routines.CivilRequest, :new, 4},
    {Wotex.Routines.Civil, :page, 3}
  ]
  @naive_fields NaiveDateTime |> struct() |> Map.keys() |> Enum.sort()
  @point_fields Enum.sort(
                  ~w(original due_ms nominal starts_at resolution schedule_digest time_zone_basis producer_basis database_basis event)
                )
  @input_errors ~w(invalid_schedule_source invalid_schedule_cursor schedule_coordinate_mismatch
    invalid_resolved_schedule_time timezone_basis_required timezone_basis_mismatch
    invalid_timezone_data invalid_timezone_projection unsupported_timezone_coordinate
    timezone_undefined calendar_search_horizon invalid_unix_time)a

  @doc "Resolves one exact source label into the complete ordered original UTC millisecond set."
  @spec resolve(term(), term(), term()) :: {:ok, [non_neg_integer()]} | {:error, atom()}
  def resolve(source, nominal, zone) do
    result =
      with {:ok, _} <- Codec.encode(source),
           {:ok, pattern} <- pattern(source["trigger"]),
           :ok <- basis(source["trigger"], zone),
           :ok <- nominal(nominal),
           :ok <- label(pattern, nominal) do
        if Date.day_of_week(NaiveDateTime.to_date(nominal)) in pattern.days,
          do: enumerate(source, nominal, zone, pattern),
          else: {:ok, []}
      end

    outcome(result)
  rescue
    _ -> invalid()
  end

  @doc "Checks the exact calendar source and the explicitly reviewed one-shot choice."
  @spec validate_source(term(), term()) :: :ok | {:error, atom()}
  def validate_source(source, zone) do
    with {:ok, _} <- Codec.encode(source),
         {:ok, _} <- pattern(source["trigger"]),
         :ok <- basis(source["trigger"], zone) do
      case source["trigger"] do
        ["once", _, _, date, time, _] ->
          {:ok, nominal} = NaiveDateTime.from_iso8601(date <> "T" <> time)
          with {:ok, _} <- resolve(source, nominal, zone), do: :ok

        _ ->
          :ok
      end
    end
  end

  @doc "Returns the next calendar original strictly after a UTC cursor, searching at most 32 local dates."
  @spec next(term(), term(), term()) :: {:ok, non_neg_integer() | nil} | {:error, atom()}
  def next(source, after_ms, zone) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.integer?(after_ms, -1, Codec.utc_maximum() - 60_000),
         :ok <- validate_source(source, zone) do
      next_calendar(source, after_ms, zone)
    else
      false -> {:error, :invalid_schedule_cursor}
      error -> error
    end
  end

  @doc "Checks exact calendar membership, retaining the first-fold recurring policy."
  @spec coordinate(term(), term(), term()) :: :ok | {:error, atom()}
  def coordinate(source, due, zone) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.utc?(due),
         :ok <- validate_source(source, zone) do
      member(source, due, zone)
    else
      false -> {:error, :schedule_coordinate_mismatch}
      error -> error
    end
  end

  defp pattern(["once", _, _, date, time, chosen]),
    do: {:ok, %{time: time, days: Enum.to_list(1..7), date: date, chosen: chosen}}

  defp pattern(["daily", _, _, time, _, _]),
    do: {:ok, %{time: time, days: Enum.to_list(1..7), date: nil, chosen: nil}}

  defp pattern(["weekdays", _, _, time, days, _, _]),
    do: {:ok, %{time: time, days: days, date: nil, chosen: nil}}

  defp pattern(_), do: {:error, :invalid_schedule_source}

  defp basis([_, name, digest | _], %Tzif{} = zone) do
    if zone.name == name and zone.digest == digest and Tzif.valid?(zone),
      do: :ok,
      else: {:error, :timezone_basis_mismatch}
  end

  defp basis(_, _), do: {:error, :timezone_basis_required}

  defp nominal(%NaiveDateTime{calendar: Calendar.ISO} = value)
       when map_size(value) == length(@naive_fields) do
    with true <- Enum.sort(Map.keys(value)) == @naive_fields,
         true <- Calendar.ISO.valid_date?(value.year, value.month, value.day),
         true <-
           Calendar.ISO.valid_time?(value.hour, value.minute, value.second, value.microsecond),
         {:ok, ^value} <-
           NaiveDateTime.new(NaiveDateTime.to_date(value), NaiveDateTime.to_time(value)) do
      if value.year in 1970..9999 and value.microsecond == {0, 0},
        do: :ok,
        else: {:error, :unsupported_timezone_coordinate}
    else
      _ -> {:error, :invalid_timezone_projection}
    end
  rescue
    _ -> {:error, :invalid_timezone_projection}
  end

  defp nominal(_), do: {:error, :invalid_timezone_projection}

  defp label(pattern, nominal) do
    if Time.to_iso8601(NaiveDateTime.to_time(nominal)) == pattern.time and
         (pattern.date == nil or Date.to_iso8601(NaiveDateTime.to_date(nominal)) == pattern.date),
       do: :ok,
       else: {:error, :schedule_coordinate_mismatch}
  end

  defp enumerate(source, nominal, zone, pattern) do
    if Enum.all?(@seams, fn {module, fun, arity} ->
         Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
       end) do
      with {:ok, provider} <- CivilTimezone.provider(zone),
           {:ok, limits} <- invoke(Wotex.Routines.Limits, :new, [@limits]),
           raw = schedule(source, zone, pattern),
           {:ok, digest} <- invoke(Wotex.Routines.Schedule, :semantic_digest, [raw, limits]),
           schedule = Map.put(raw, "definition_digest", digest),
           query = %{
             "first_date" => Date.to_iso8601(NaiveDateTime.to_date(nominal)),
             "days" => 1,
             "from" => "1970-01-01T00:00:00Z",
             "until" => "9999-12-31T23:59:00Z"
           },
           {:ok, request} <-
             invoke(Wotex.Routines.CivilRequest, :new, [schedule, query, provider, limits]),
           {:ok, page} <- invoke(Wotex.Routines.Civil, :page, [request, @time, limits]),
           {:ok, instants} <- project(page, request, schedule, nominal),
           :ok <- chosen(pattern, instants) do
        {:ok, instants}
      end
    else
      {:error, :routine_calendar_unavailable}
    end
  end

  defp invoke(module, function, arguments), do: apply(module, function, arguments)

  defp schedule(source, zone, pattern) do
    %{
      "format" => "wotex.routines.schedule@1",
      "kind" => "civil",
      "schedule_id" => source["id"],
      "late_window_ms" => source["late_window_ms"],
      "time" => pattern.time,
      "weekdays" => pattern.days,
      "time_zone" => zone.name,
      "time_zone_basis" => "sha256:" <> zone.digest,
      "producer_basis" => @producer_basis,
      "gap_policy" => "skip",
      "fold_policy" => "both"
    }
  end

  defp chosen(%{chosen: nil}, _), do: :ok

  defp chosen(%{chosen: due}, instants) do
    if due in instants, do: :ok, else: {:error, :invalid_resolved_schedule_time}
  end

  defp project(
         %{
           __struct__: Wotex.Routines.CivilPage,
           request: request,
           time: @time,
           occurrences: points
         } = page,
         request,
         schedule,
         nominal
       )
       when map_size(page) == 4 and page.time == @time do
    with {:ok, count} <- count(points, 0) do
      points
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, [], -1}, fn {point, index}, {:ok, values, previous} ->
        if point?(point, index, count, nominal, schedule) and point["due_ms"] > previous,
          do: {:cont, {:ok, [point["due_ms"] | values], point["due_ms"]}},
          else: {:halt, invalid()}
      end)
      |> case do
        {:ok, reversed, _} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  defp project(_, _, _, _), do: invalid()

  defp count([], count), do: {:ok, count}
  defp count([_ | rest], count) when count < 258, do: count(rest, count + 1)
  defp count(_, _), do: invalid()

  defp point?(point, index, count, nominal, schedule)
       when is_map(point) and map_size(point) == 10 do
    Enum.sort(Map.keys(point)) == @point_fields and Codec.utc?(point["due_ms"]) and
      rem(point["due_ms"], 1000) == 0 and
      point["nominal"] == NaiveDateTime.to_iso8601(nominal) and
      point["starts_at"] ==
        DateTime.to_iso8601(
          DateTime.from_unix!(point["due_ms"], :millisecond)
          |> DateTime.truncate(:second)
        ) and
      point["resolution"] == resolution(index, count) and
      point["schedule_digest"] == schedule["definition_digest"] and
      point["time_zone_basis"] == schedule["time_zone_basis"] and
      point["producer_basis"] == schedule["producer_basis"] and
      digest?(point["original"]) and digest?(point["database_basis"]) and
      point["event"] == descriptor(point, schedule)
  end

  defp point?(_, _, _, _, _), do: false

  defp resolution(_, 1), do: "unique"
  defp resolution(1, _), do: "first_fold"
  defp resolution(2, _), do: "second_fold"
  defp resolution(index, _), do: ["fold", index]

  defp digest?(value),
    do:
      is_binary(value) and byte_size(value) == 71 and
        Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  defp descriptor(point, schedule),
    do: %{
      "kind" => "due",
      "original" => point["original"],
      "schedule_id" => schedule["schedule_id"],
      "schedule_basis" => schedule["definition_digest"],
      "due_ms" => point["due_ms"],
      "late_window_ms" => schedule["late_window_ms"],
      "clock_generation" => @time["clock_generation"],
      "time_zone_basis" => schedule["time_zone_basis"]
    }

  defp outcome({:ok, instants}), do: {:ok, instants}

  defp outcome({:error, %{__struct__: Wotex.Routines.Error, code: :civil_unavailable}}),
    do: {:error, :routine_calendar_unavailable}

  defp outcome({:error, %{__struct__: Wotex.Routines.Error, code: :civil_work_bound}}),
    do: {:error, :routine_calendar_work_bound}

  defp outcome({:error, %{__struct__: Wotex.Routines.Error, code: :producer_contract_error}}),
    do: invalid()

  defp outcome({:error, %{__struct__: Wotex.Routines.Error}}),
    do: {:error, :routine_calendar_refused}

  defp outcome({:error, :routine_timezone_unavailable}),
    do: {:error, :routine_calendar_unavailable}

  defp outcome({:error, reason}) when reason in @input_errors, do: {:error, reason}

  defp outcome({:error, reason})
       when reason in [:routine_calendar_unavailable, :invalid_routine_calendar_projection],
       do: {:error, reason}

  defp outcome(_), do: invalid()
  defp invalid, do: {:error, :invalid_routine_calendar_projection}

  defp next_calendar(%{"trigger" => ["once", _, _, _, _, due]}, after_ms, _),
    do: {:ok, if(due > after_ms, do: due)}

  defp next_calendar(source, after_ms, zone) do
    {start, finish} = bounds(source["trigger"])
    seed = max(start, after_ms + 1)

    if seed > Codec.utc_maximum() - 60_000 or (finish != nil and seed >= finish) do
      {:ok, nil}
    else
      with {:ok, local} <- local(zone, seed) do
        date = if local.year < 1970, do: ~D[1970-01-01], else: NaiveDateTime.to_date(local)
        find_date(source, date, start, finish, after_ms, zone, 32)
      else
        {:error, :invalid_unix_time} -> {:ok, nil}
        error -> error
      end
    end
  end

  defp find_date(_, _, _, _, _, _, 0), do: {:error, :calendar_search_horizon}

  defp find_date(source, date, start, finish, after_ms, zone, remaining) do
    {:ok, pattern} = pattern(source["trigger"])
    {:ok, nominal} = NaiveDateTime.new(date, Time.from_iso8601!(pattern.time))

    with {:ok, instants} <- resolve(source, nominal, zone) do
      first = List.first(instants)

      cond do
        first != nil and finish != nil and first >= finish -> {:ok, nil}
        first != nil and first > after_ms and first >= start -> {:ok, first}
        date == ~D[9999-12-31] -> {:ok, nil}
        true -> find_date(source, Date.add(date, 1), start, finish, after_ms, zone, remaining - 1)
      end
    end
  end

  defp member(%{"trigger" => ["once", _, _, _, _, due]}, due, _), do: :ok
  defp member(%{"trigger" => ["once" | _]}, _, _), do: {:error, :schedule_coordinate_mismatch}

  defp member(source, due, zone) do
    {start, finish} = bounds(source["trigger"])

    with true <- due >= start and (finish == nil or due < finish) and rem(due, 1000) == 0,
         {:ok, nominal} <- local(zone, due),
         {:ok, [^due | _]} <- resolve(source, nominal, zone),
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> {:error, :schedule_coordinate_mismatch}
         )
  end

  defp bounds(["daily", _, _, _, start, finish]), do: {start, finish}
  defp bounds(["weekdays", _, _, _, _, start, finish]), do: {start, finish}

  defp local(zone, utc_ms) do
    with {:ok, %{offset: offset}} <- Tzif.offset(zone, utc_ms),
         {:ok, shifted} <- DateTime.from_unix(utc_ms + offset * 1000, :millisecond),
         do: {:ok, shifted |> DateTime.truncate(:second) |> DateTime.to_naive()}
  end
end
