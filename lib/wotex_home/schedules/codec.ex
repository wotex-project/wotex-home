defmodule WotexHome.Schedules.Codec do
  @moduledoc "Bounded canonical inert schedule records. Decoding never establishes time, admission or author authority."

  alias WotexHome.Id
  alias WotexHome.Profiles.Codec, as: ProfileCodec

  @maximum 9_223_372_036_854_775_807
  @utc_maximum 253_402_300_799_999
  @format "wotex-home.schedule-source.v1"
  @fields ~w(id source_revision author_id rule_id rule_source_digest target_id resource_revision late_window_ms uncertainty_tolerance_ms trigger)

  def maximum, do: @maximum
  def utc_maximum, do: @utc_maximum

  def encode(input) do
    if exact?(input, @fields) and
         Enum.all?(~w(id author_id rule_id target_id), &Id.valid?(input[&1])) and
         integer?(input["source_revision"], 0, @maximum) and
         integer?(input["resource_revision"], 0, @maximum) and
         ProfileCodec.digest?(input["rule_source_digest"]) and
         integer?(input["late_window_ms"], 1_000, 60_000) and
         integer?(input["uncertainty_tolerance_ms"], 0, 1_000) and
         trigger?(input["trigger"]) do
      {:ok, JSON.encode!([@format | Enum.map(@fields, &input[&1])])}
    else
      {:error, :invalid_schedule_source}
    end
  end

  def decode(bytes) do
    with {:ok, [@format | values]} <- record(bytes),
         true <- length(values) == length(@fields),
         input = Map.new(Enum.zip(@fields, values)),
         {:ok, ^bytes} <- encode(input),
         do: {:ok, input},
         else: (_ -> {:error, :invalid_schedule_source})
  end

  def digest(input) do
    with {:ok, bytes} <- encode(input), do: {:ok, hash(bytes)}
  end

  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def exact?(input, fields),
    do: is_map(input) and not is_struct(input) and Enum.sort(Map.keys(input)) == Enum.sort(fields)

  def integer?(value, lower, upper),
    do: is_integer(value) and value >= lower and value <= upper

  def utc?(value), do: integer?(value, 0, @utc_maximum - 60_000)

  def record(bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096 do
    with true <- String.valid?(bytes),
         {value, {0, 0, nil}, ""} <- JSON.decode(bytes, {0, 0, nil}, decoders()),
         true <- is_list(value),
         do: {:ok, value},
         else: (_ -> {:error, :invalid_schedule_record})
  catch
    :throw, :invalid_schedule_record -> {:error, :invalid_schedule_record}
  end

  def record(_), do: {:error, :invalid_schedule_record}

  defp trigger?(["once", zone, digest, date, time, utc]),
    do: zone?(zone) and ProfileCodec.digest?(digest) and date?(date) and time?(time) and utc?(utc)

  defp trigger?(["daily", zone, digest, time, start, finish]),
    do: zone?(zone) and ProfileCodec.digest?(digest) and time?(time) and bounds?(start, finish)

  defp trigger?(["weekdays", zone, digest, time, days, start, finish]),
    do:
      zone?(zone) and ProfileCodec.digest?(digest) and time?(time) and bounds?(start, finish) and
        is_list(days) and length(days) in 1..7 and days == Enum.uniq(Enum.sort(days)) and
        Enum.all?(days, &integer?(&1, 1, 7))

  defp trigger?(["interval", anchor, period, start, finish]),
    do: utc?(anchor) and integer?(period, 60_000, 2_678_400_000) and bounds?(start, finish)

  defp trigger?(["countdown", boot, generation, start, duration]),
    do:
      Id.valid?(boot) and integer?(generation, 1, @maximum) and
        integer?(start, 0, @maximum - 86_460_000) and integer?(duration, 1_000, 86_400_000)

  defp trigger?(_), do: false
  defp bounds?(start, nil), do: utc?(start)
  defp bounds?(start, finish), do: utc?(start) and utc?(finish) and finish > start

  def zone?(zone) when is_binary(zone) and byte_size(zone) in 1..128 do
    Regex.match?(~r/\A[A-Za-z0-9_+-]+(?:\/[A-Za-z0-9_+-]+)*\z/, zone)
  end

  def zone?(_), do: false

  defp date?(value) when is_binary(value) and byte_size(value) == 10 do
    case Date.from_iso8601(value) do
      {:ok, date} -> date.year in 1970..9999 and Date.to_iso8601(date) == value
      _ -> false
    end
  end

  defp date?(_), do: false

  defp time?(value) when is_binary(value) and byte_size(value) == 8 do
    case Time.from_iso8601(value) do
      {:ok, time} -> Time.to_iso8601(time) == value
      _ -> false
    end
  end

  defp time?(_), do: false

  defp reject, do: throw(:invalid_schedule_record)

  defp decoders do
    [
      array_start: fn
        {depth, _, _} when depth < 3 -> {depth + 1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {depth, count, values} when count < 16 -> {depth, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {_, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 128, do: value, else: reject() end,
      integer: fn text ->
        if byte_size(text) <= 19 do
          value = String.to_integer(text)
          if integer?(value, 0, @maximum), do: value, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end
end
