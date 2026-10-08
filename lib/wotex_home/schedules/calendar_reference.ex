defmodule WotexHome.Schedules.CalendarReference do
  @moduledoc """
  Independent, bounded calendar reference over original non-leap TZif bytes.

  This module does not call Tzif, TzifFooter or Recurrence. Its private phase
  table, token parser and Erlang Gregorian arithmetic supply calculation
  comparisons only, never a clock source, admission or execution authority.
  """
  alias WotexHome.Schedules.Codec
  @epoch :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  @minimum_seconds -9_223_372_036_854_775_808
  @maximum_seconds 9_223_372_036_854_775_808
  @maximum_due 253_402_300_739_999
  @enforce_keys [:name, :digest, :phases, :offsets, :tail_start, :tail]
  defstruct @enforce_keys

  def decode(name, bytes) when is_binary(bytes) and byte_size(bytes) in 44..65_536 do
    with true <- Codec.zone?(name),
         {:ok, first} <- header(bytes, 0),
         position = 44 + block_size(first, 4),
         {:ok, current} <- header(bytes, position),
         true <- first.version == current.version,
         {:ok, transitions, types, footer} <- data(bytes, position + 44, current),
         {:ok, tail} <- footer(footer, current.version),
         :ok <- join(transitions, types, tail) do
      {phases, tail_start} = phases(transitions, types)
      offsets = Enum.map(types, &elem(&1, 0)) ++ tail_offsets(tail)

      {:ok,
       %__MODULE__{
         name: name,
         digest: Codec.hash(bytes),
         phases: phases,
         offsets: Enum.sort(Enum.uniq(offsets)),
         tail_start: tail_start,
         tail: tail
       }}
    else
      _ -> invalid()
    end
  end

  def decode(_, _), do: invalid()

  def resolve(%__MODULE__{} = reference, %NaiveDateTime{} = local) do
    if local.calendar == Calendar.ISO and local.microsecond == {0, 0} and
         Enum.all?(
           [local.year, local.month, local.day, local.hour, local.minute, local.second],
           &is_integer/1
         ) and
         local.year in 1970..9999 and :calendar.valid_date({local.year, local.month, local.day}) and
         local.hour in 0..23 and local.minute in 0..59 and local.second in 0..59 do
      resolve_label(
        reference,
        {local.year, local.month, local.day},
        {local.hour, local.minute, local.second}
      )
    else
      invalid()
    end
  end

  def resolve(_, _), do: invalid()

  def next(source, after_ms, %__MODULE__{} = reference) do
    with {:ok, _} <- Codec.encode(source),
         true <- Codec.integer?(after_ms, -1, @maximum_due),
         [kind, name, digest | _] <- source["trigger"],
         true <- kind in ~w(once daily weekdays),
         true <- name == reference.name and digest == reference.digest do
      next_calendar(source["trigger"], after_ms, reference)
    else
      _ -> invalid()
    end
  end

  def next(_, _, _), do: invalid()

  def offset(%__MODULE__{} = reference, utc_ms) when utc_ms in 0..@maximum_due do
    with {:ok, {offset, _, _}} <- phase(reference, div(utc_ms, 1_000)), do: {:ok, offset}
  end

  def offset(_, _), do: invalid()

  defp header(bytes, position) when byte_size(bytes) >= position + 44 do
    case binary_part(bytes, position, 44) do
      <<"TZif", version, 0::120, utc::unsigned-big-32, standard::unsigned-big-32,
        0::unsigned-big-32, times::unsigned-big-32, types::unsigned-big-32,
        chars::unsigned-big-32>>
      when version in [?2, ?3, ?4] and times <= 4_096 and types in 1..256 and
             chars in 1..2_048 and utc in [0, types] and standard in [0, types] ->
        {:ok,
         %{
           version: version,
           utc: utc,
           standard: standard,
           times: times,
           types: types,
           chars: chars
         }}

      _ ->
        invalid()
    end
  end

  defp header(_, _), do: invalid()

  defp block_size(h, width),
    do: h.times * (width + 1) + h.types * 6 + h.chars + h.utc + h.standard

  defp data(bytes, position, h) do
    size = block_size(h, 8)

    if byte_size(bytes) >= position + size + 2 do
      time_bytes = h.times * 8
      type_bytes = h.types * 6

      <<raw_times::binary-size(time_bytes), indexes::binary-size(h.times),
        raw_types::binary-size(type_bytes), names::binary-size(h.chars),
        standard::binary-size(h.standard), utc::binary-size(h.utc)>> =
        binary_part(bytes, position, size)

      framing = binary_part(bytes, position + size, byte_size(bytes) - position - size)
      times = for <<time::signed-big-64 <- raw_times>>, do: time
      indexes = :binary.bin_to_list(indexes)

      with true <- Enum.all?(Enum.chunk_every(times, 2, 1, :discard), fn [a, b] -> a < b end),
           true <- Enum.all?(indexes, &(&1 < h.types)),
           true <- indicators?(standard, utc, h.types),
           {:ok, types} <- types(raw_types, names),
           true <- byte_size(framing) in 2..258,
           <<10, rest::binary>> <- framing,
           true <- :binary.last(rest) == 10,
           text = binary_part(rest, 0, byte_size(rest) - 1),
           true <- Enum.all?(:binary.bin_to_list(text), &(&1 in 32..126)) do
        {:ok, Enum.zip(times, indexes), types, text}
      else
        _ -> invalid()
      end
    else
      invalid()
    end
  end

  defp types(raw, names) do
    Enum.reduce_while(
      for(<<offset::signed-big-32, dst, index <- raw>>, do: {offset, dst, index}),
      {:ok, []},
      fn {offset, dst, index}, {:ok, types} ->
        with true <- offset in -89_999..93_599 and dst in [0, 1] and index < byte_size(names),
             rest = binary_part(names, index, byte_size(names) - index),
             {length, 1} <- :binary.match(rest, <<0>>),
             true <- length <= 32,
             name = binary_part(rest, 0, length),
             true <- Regex.match?(~r/\A[A-Za-z0-9+-]*\z/, name) do
          {:cont, {:ok, [{offset, dst, name} | types]}}
        else
          _ -> {:halt, invalid()}
        end
      end
    )
    |> case do
      {:ok, types} -> {:ok, Enum.reverse(types)}
      error -> error
    end
  end

  defp indicators?(standard, utc, count) do
    s = if standard == "", do: List.duplicate(0, count), else: :binary.bin_to_list(standard)
    u = if utc == "", do: List.duplicate(0, count), else: :binary.bin_to_list(utc)
    Enum.all?(Enum.zip(s, u), fn {s, u} -> s in [0, 1] and u in [0, 1] and u <= s end)
  end

  defp phases([], types), do: {[], {@minimum_seconds, hd(types)}}

  defp phases(transitions, types) do
    boundaries = [
      {@minimum_seconds, hd(types)}
      | Enum.map(transitions, fn {t, i} -> {t, Enum.at(types, i)} end)
    ]

    phases =
      for [{a, type}, {b, _}] <- Enum.chunk_every(boundaries, 2, 1, :discard), do: {a, b, type}

    {phases, {elem(List.last(transitions), 0), nil}}
  end

  defp join([], _, _), do: :ok
  defp join(_, _, nil), do: :ok

  defp join(transitions, types, tail) do
    {time, index} = List.last(transitions)

    with {:ok, type} <- tail_type(tail, time),
         true <- type == Enum.at(types, index),
         do: :ok,
         else: (_ -> invalid())
  end

  defp phase(reference, seconds) do
    {tail_start, constant} = reference.tail_start

    result =
      if seconds >= tail_start do
        cond do
          reference.tail != nil -> tail_type(reference.tail, seconds)
          constant != nil -> {:ok, constant}
          true -> {:error, :timezone_undefined}
        end
      else
        case Enum.find(reference.phases, fn {a, b, _} -> a <= seconds and seconds < b end) do
          {_, _, type} -> {:ok, type}
          nil -> invalid()
        end
      end

    case result do
      {:ok, {_, _, "-00"}} -> {:error, :timezone_undefined}
      other -> other
    end
  end

  defp footer("", _), do: {:ok, nil}

  defp footer(text, version) do
    with [core | rules] <- String.split(text, ","),
         {:ok, standard_name, rest} <- name(core),
         {:ok, standard, rest} <- duration_prefix(rest, 24, true) do
      case {rest, rules} do
        {"", []} ->
          make_tail({-standard, 0, standard_name}, nil, nil)

        {daylight_core, [start, finish]} ->
          with {:ok, daylight_name, rest} <- name(daylight_core),
               {:ok, daylight} <- daylight(rest, -standard),
               {:ok, start} <- date_rule(start, version),
               {:ok, finish} <- date_rule(finish, version),
               do:
                 make_tail(
                   {-standard, 0, standard_name},
                   {daylight, 1, daylight_name},
                   {start, finish}
                 )

        _ ->
          invalid()
      end
    end
  end

  defp make_tail(standard, daylight, rules) do
    if elem(standard, 0) in -89_999..93_599 and
         (daylight == nil or elem(daylight, 0) in -89_999..93_599),
       do: {:ok, {standard, daylight, rules}},
       else: invalid()
  end

  defp name("<" <> rest) do
    case String.split(rest, ">", parts: 2) do
      [name, rest] when byte_size(name) in 3..6 ->
        if Regex.match?(~r/\A[A-Za-z0-9+-]+\z/, name), do: {:ok, name, rest}, else: invalid()

      _ ->
        invalid()
    end
  end

  defp name(text) do
    case Regex.run(~r/\A([A-Za-z]{3,6})(.*)\z/, text, capture: :all_but_first) do
      [name, rest] -> {:ok, name, rest}
      _ -> invalid()
    end
  end

  defp duration_prefix(text, maximum, signed) do
    pattern =
      if signed,
        do: ~r/\A([+-]?[0-9]{1,3}(?::[0-9]{1,2}){0,2})(.*)\z/,
        else: ~r/\A([0-9]{1,3}(?::[0-9]{1,2}){0,2})(.*)\z/

    with [clock, rest] <- Regex.run(pattern, text, capture: :all_but_first),
         {sign, digits} =
           if(String.starts_with?(clock, "-"),
             do: {-1, String.slice(clock, 1..-1//1)},
             else: {1, String.trim_leading(clock, "+")}
           ),
         fields = Enum.map(String.split(digits, ":"), &String.to_integer/1),
         true <- hd(fields) <= maximum and Enum.all?(tl(fields), &(&1 <= 59)) do
      {:ok,
       sign * Enum.reduce(fields, 0, fn field, total -> total * 60 + field end) *
         Integer.pow(60, 3 - length(fields)), rest}
    else
      _ -> invalid()
    end
  end

  defp daylight("", standard), do: {:ok, standard + 3_600}

  defp daylight(text, _) do
    with {:ok, value, ""} <- duration_prefix(text, 24, true),
         do: {:ok, -value},
         else: (_ -> invalid())
  end

  defp date_rule(text, version) do
    case String.split(text, "/") do
      [date] ->
        with {:ok, day} <- day_rule(date), do: {:ok, {day, 7_200}}

      [date, clock] ->
        with {:ok, day} <- day_rule(date),
             {:ok, seconds, ""} <-
               duration_prefix(clock, if(version == ?2, do: 24, else: 167), version != ?2),
             do: {:ok, {day, seconds}},
             else: (_ -> invalid())

      _ ->
        invalid()
    end
  end

  defp day_rule("M" <> fields) do
    with [month, week, weekday] <- String.split(fields, "."),
         {:ok, m} <- number(month, 1, 12),
         {:ok, w} <- number(week, 1, 5),
         {:ok, d} <- number(weekday, 0, 6),
         do: {:ok, {:month, m, w, d}},
         else: (_ -> invalid())
  end

  defp day_rule("J" <> text), do: with({:ok, n} <- number(text, 1, 365), do: {:ok, {:julian, n}})
  defp day_rule(text), do: with({:ok, n} <- number(text, 0, 365), do: {:ok, {:ordinal, n}})

  defp number(text, lower, upper) do
    if Regex.match?(~r/\A[0-9]{1,3}\z/, text) do
      value = String.to_integer(text)
      if value in lower..upper, do: {:ok, value}, else: invalid()
    else
      invalid()
    end
  end

  defp tail_offsets(nil), do: []
  defp tail_offsets({standard, nil, _}), do: [elem(standard, 0)]
  defp tail_offsets({standard, daylight, _}), do: [elem(standard, 0), elem(daylight, 0)]

  defp tail_type({standard, nil, _}, _), do: {:ok, standard}

  defp tail_type({standard, daylight, {start, finish}}, seconds) do
    with {:ok, {{year, _, _}, _}} <- datetime(seconds), true <- year in 1..9999 do
      years = Enum.filter((year - 2)..(year + 2), &(&1 in 1..9999))

      starts =
        Enum.map(years, &transition(&1, start, elem(standard, 0)))
        |> Enum.filter(&(&1 <= seconds))

      finishes =
        Enum.map(years, &transition(&1, finish, elem(daylight, 0)))
        |> Enum.filter(&(&1 <= seconds))

      s = Enum.max(starts, fn -> @minimum_seconds end)
      f = Enum.max(finishes, fn -> @minimum_seconds end)

      if s == @minimum_seconds and f == @minimum_seconds,
        do: invalid(),
        else: {:ok, if(s >= f, do: daylight, else: standard)}
    else
      _ -> invalid()
    end
  end

  defp transition(year, {rule, seconds}, previous_offset),
    do: unix({rule_date(year, rule), {0, 0, 0}}) + seconds - previous_offset

  defp rule_date(year, {:month, month, week, weekday}) do
    days =
      for day <- 1..:calendar.last_day_of_the_month(year, month),
          rem(:calendar.day_of_the_week(year, month, day), 7) == weekday,
          do: day

    {year, month, if(week == 5, do: List.last(days), else: Enum.at(days, week - 1))}
  end

  defp rule_date(year, {:julian, day}) do
    extra = if :calendar.is_leap_year(year) and day >= 60, do: 1, else: 0

    :calendar.gregorian_days_to_date(
      :calendar.date_to_gregorian_days({year, 1, 1}) + day - 1 + extra
    )
  end

  defp rule_date(year, {:ordinal, day}),
    do: :calendar.gregorian_days_to_date(:calendar.date_to_gregorian_days({year, 1, 1}) + day)

  defp resolve_label(reference, date, time) do
    label = unix({date, time})

    candidates =
      Enum.map(reference.offsets, &(label - &1))
      |> Enum.filter(&(&1 >= 0 and &1 * 1_000 <= @maximum_due))

    with :ok <- defined_candidates(reference, candidates) do
      phases = local_phases(reference, label)

      instants =
        for {a, b, {offset, _, _}} <- phases,
            candidate = label - offset,
            candidate >= a and candidate < b and candidate >= 0 and
              candidate * 1_000 <= @maximum_due,
            do: candidate * 1_000

      {:ok, Enum.sort(Enum.uniq(instants))}
    end
  end

  defp defined_candidates(reference, candidates) do
    Enum.reduce_while(candidates, :ok, fn candidate, :ok ->
      case phase(reference, candidate) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp local_phases(reference, label) do
    {tail_start, constant} = reference.tail_start

    tail =
      case reference.tail do
        nil ->
          if constant == nil, do: [], else: [{tail_start, @maximum_seconds, constant}]

        {standard, nil, _} ->
          [{tail_start, @maximum_seconds, standard}]

        {standard, daylight, {start, finish}} ->
          {:ok, {{year, _, _}, _}} = datetime(label)

          events =
            for y <- (year - 2)..(year + 2),
                y in 1..9999,
                event <- [
                  {transition(y, start, elem(standard, 0)), daylight},
                  {transition(y, finish, elem(daylight, 0)), standard}
                ],
                do: event

          events = Enum.sort_by(events, fn {time, {_, dst, _}} -> {time, dst} end)
          events = Enum.reverse(Enum.uniq_by(Enum.reverse(events), &elem(&1, 0)))

          for [{a, type}, {b, _}] <-
                Enum.chunk_every(events ++ [{@maximum_seconds, nil}], 2, 1, :discard),
              b > tail_start,
              do: {max(a, tail_start), b, type}
      end

    reference.phases ++ tail
  end

  defp next_calendar(["once", _, _, date, time, due], after_ms, reference) do
    with {:ok, local} <- NaiveDateTime.from_iso8601(date <> "T" <> time),
         {:ok, instants} <- resolve(reference, local),
         true <- due in instants,
         do: {:ok, if(due > after_ms, do: due)},
         else: (_ -> invalid())
  end

  defp next_calendar(trigger, after_ms, reference) do
    {time, days, start, finish} =
      case trigger do
        ["daily", _, _, time, start, finish] -> {time, Enum.to_list(1..7), start, finish}
        ["weekdays", _, _, time, days, start, finish] -> {time, days, start, finish}
      end

    seed = max(start, after_ms + 1)

    if finish != nil and seed >= finish do
      {:ok, nil}
    else
      with {:ok, {offset, _, _}} <- phase(reference, div(seed, 1_000)),
           {:ok, {date, _}} <- datetime(div(seed, 1_000) + offset) do
        date = max(date, {1970, 1, 1})
        [h, m, s] = Enum.map(String.split(time, ":"), &String.to_integer/1)

        search(
          reference,
          :calendar.date_to_gregorian_days(date),
          {h, m, s},
          days,
          start,
          finish,
          after_ms,
          32
        )
      end
    end
  end

  defp search(_, _, _, _, _, _, _, 0), do: {:error, :calendar_search_horizon}

  defp search(reference, day, time, days, start, finish, after_ms, remaining) do
    date = :calendar.gregorian_days_to_date(day)

    if date > {9999, 12, 31} do
      {:ok, nil}
    else
      with {:ok, instants} <-
             if(:calendar.day_of_the_week(date) in days,
               do: resolve_label(reference, date, time),
               else: {:ok, []}
             ) do
        first = List.first(instants)

        cond do
          first != nil and finish != nil and first >= finish -> {:ok, nil}
          first != nil and first > after_ms and first >= start -> {:ok, first}
          date == {9999, 12, 31} -> {:ok, nil}
          true -> search(reference, day + 1, time, days, start, finish, after_ms, remaining - 1)
        end
      end
    end
  end

  defp datetime(seconds) when seconds + @epoch >= 0,
    do: {:ok, :calendar.gregorian_seconds_to_datetime(seconds + @epoch)}

  defp datetime(_), do: invalid()
  defp unix(datetime), do: :calendar.datetime_to_gregorian_seconds(datetime) - @epoch
  defp invalid, do: {:error, :invalid_calendar_reference}
end
