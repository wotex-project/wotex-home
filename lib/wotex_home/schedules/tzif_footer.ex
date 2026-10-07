defmodule WotexHome.Schedules.TzifFooter do
  @moduledoc "Closed POSIX TZ footer calculation; no environment mutation or platform timezone fallback."
  @name "(?:[A-Za-z]{3,6}|<[A-Za-z0-9+-]{3,6}>)"
  @offset "[+-]?[0-9]{1,3}(?::[0-9]{1,2}(?::[0-9]{1,2})?)?"
  @pattern Regex.compile!(
             "\\A(" <>
               @name <>
               ")(" <> @offset <> ")(?:(" <> @name <> ")(" <> @offset <> ")?,([^,]+),([^,]+))?\\z"
           )

  def decode("", _version), do: {:ok, nil}

  def decode(text, version)
      when is_binary(text) and byte_size(text) <= 256 and version in [?2, ?3, ?4] do
    case Regex.run(@pattern, text, capture: :all_but_first) do
      [name, offset] ->
        with {:ok, seconds} <- seconds(offset, 24, true),
             true <- -seconds in -89_999..93_599 do
          {:ok, %{standard: type(name, -seconds, 0), daylight: nil, start: nil, finish: nil}}
        else
          _ -> invalid()
        end

      [name, offset, daylight, dst_offset, start, finish] ->
        with {:ok, seconds} <- seconds(offset, 24, true),
             {:ok, dst} <- daylight_offset(dst_offset, -seconds),
             true <- -seconds in -89_999..93_599 and dst in -89_999..93_599,
             {:ok, start_rule} <- rule(start, version),
             {:ok, end_rule} <- rule(finish, version) do
          {:ok,
           %{
             standard: type(name, -seconds, 0),
             daylight: type(daylight, dst, 1),
             start: start_rule,
             finish: end_rule
           }}
        else
          _ -> invalid()
        end

      _ ->
        invalid()
    end
  end

  def decode(_, _), do: invalid()

  def at(%{daylight: nil, standard: standard}, _utc_seconds), do: {:ok, standard}

  def at(%{standard: standard, daylight: daylight, start: start, finish: finish}, utc_seconds) do
    with {:ok, datetime} <- DateTime.from_unix(utc_seconds) do
      events =
        for year <- (datetime.year - 2)..(datetime.year + 2),
            year in 1..9999,
            event <- [
              {transition(year, start, standard.offset), 1, daylight},
              {transition(year, finish, daylight.offset), 0, standard}
            ],
            elem(event, 0) <= utc_seconds,
            do: event

      case Enum.max_by(events, &{elem(&1, 0), elem(&1, 1)}, fn -> nil end) do
        {_, _, type} -> {:ok, type}
        nil -> invalid()
      end
    else
      _ -> invalid()
    end
  end

  defp transition(year, {day, seconds}, offset) do
    date = day(year, day)
    datetime = NaiveDateTime.new!(date, ~T[00:00:00]) |> DateTime.from_naive!("Etc/UTC")
    DateTime.to_unix(datetime) + seconds - offset
  end

  defp day(year, {:month, month, week, weekday}) do
    first = Date.new!(year, month, 1)
    iso_weekday = if weekday == 0, do: 7, else: weekday
    date = Date.add(first, rem(iso_weekday - Date.day_of_week(first) + 7, 7) + 7 * (week - 1))
    if date.month == month, do: date, else: Date.add(date, -7)
  end

  defp day(year, {:julian, number}) do
    leap_adjustment = if Calendar.ISO.leap_year?(year) and number >= 60, do: 1, else: 0
    Date.add(Date.new!(year, 1, 1), number - 1 + leap_adjustment)
  end

  defp day(year, {:ordinal, number}), do: Date.add(Date.new!(year, 1, 1), number)

  defp rule(text, version) do
    case String.split(text, "/") do
      [day] ->
        with {:ok, date} <- date_rule(day), do: {:ok, {date, 7_200}}

      [day, time] ->
        with {:ok, date} <- date_rule(day),
             {:ok, seconds} <- seconds(time, if(version == ?2, do: 24, else: 167), version != ?2),
             do: {:ok, {date, seconds}}

      _ ->
        invalid()
    end
  end

  defp date_rule("M" <> value) do
    case String.split(value, ".") do
      [month, week, weekday] ->
        with {:ok, m} <- unsigned(month, 1, 12),
             {:ok, w} <- unsigned(week, 1, 5),
             {:ok, d} <- unsigned(weekday, 0, 6),
             do: {:ok, {:month, m, w, d}}

      _ ->
        invalid()
    end
  end

  defp date_rule("J" <> value),
    do: with({:ok, n} <- unsigned(value, 1, 365), do: {:ok, {:julian, n}})

  defp date_rule(value), do: with({:ok, n} <- unsigned(value, 0, 365), do: {:ok, {:ordinal, n}})

  defp daylight_offset("", standard), do: {:ok, standard + 3_600}

  defp daylight_offset(text, _),
    do: with({:ok, value} <- seconds(text, 24, true), do: {:ok, -value})

  defp seconds(text, maximum_hour, signed) do
    {sign, rest} =
      case text do
        "-" <> rest when signed -> {-1, rest}
        "+" <> rest when signed -> {1, rest}
        _ -> {1, text}
      end

    case String.split(rest, ":") do
      [hour] ->
        with {:ok, h} <- unsigned(hour, 0, maximum_hour), do: {:ok, sign * h * 3_600}

      [hour, minute] ->
        with {:ok, h} <- unsigned(hour, 0, maximum_hour),
             {:ok, m} <- unsigned(minute, 0, 59),
             do: {:ok, sign * (h * 3_600 + m * 60)}

      [hour, minute, second] ->
        with {:ok, h} <- unsigned(hour, 0, maximum_hour),
             {:ok, m} <- unsigned(minute, 0, 59),
             {:ok, s} <- unsigned(second, 0, 59),
             do: {:ok, sign * (h * 3_600 + m * 60 + s)}

      _ ->
        invalid()
    end
  end

  defp unsigned(text, lower, upper) do
    if byte_size(text) in 1..3 and Regex.match?(~r/\A[0-9]+\z/, text) do
      number = String.to_integer(text)
      if number in lower..upper, do: {:ok, number}, else: invalid()
    else
      invalid()
    end
  end

  defp type(name, offset, dst),
    do: %{
      designation: String.trim(name, "<") |> String.trim_trailing(">"),
      offset: offset,
      dst: dst
    }

  defp invalid, do: {:error, :unsupported_timezone_footer}
end
