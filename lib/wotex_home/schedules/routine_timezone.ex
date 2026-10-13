defmodule WotexHome.Schedules.RoutineTimezone do
  @moduledoc "Pure explicit TZif provider for optional original-occurrence calculation. It establishes no clock confidence or execution authority."

  alias WotexHome.Schedules.{Codec, Tzif}

  @tag "wotex-home.tzif-provider.v1"

  @doc "Constructs the optional producer provider from fully revalidated immutable zone bytes."
  @spec provider(term()) :: {:ok, map()} | {:error, atom()}
  def provider(zone) do
    cond do
      not Tzif.valid?(zone) ->
        {:error, :invalid_timezone_data}

      not Code.ensure_loaded?(ExBooking.TimeZoneProvider) ->
        {:error, :routine_timezone_unavailable}

      true ->
        context =
          <<@tag, 0, byte_size(zone.name)::unsigned-big-16, zone.name::binary,
            zone.bytes::binary>>

        arguments = [__MODULE__, context]
        apply(ExBooking.TimeZoneProvider, :new, arguments)
    end
  rescue
    UndefinedFunctionError -> {:error, :routine_timezone_unavailable}
  end

  @doc "Resolves the exact named whole-second local label using only its supplied retained context."
  @spec resolve(term(), term(), term()) ::
          {:ok, DateTime.t()} | {:ambiguous, DateTime.t(), DateTime.t()} | :gap | {:error, atom()}
  def resolve(nominal, name, context) do
    with {:ok, zone} <- context(context, name),
         :ok <- nominal(nominal),
         {:ok, instants} <- Tzif.resolve(zone, nominal) do
      resolved(instants, nominal, zone)
    end
  rescue
    _ -> {:error, :invalid_timezone_projection}
  end

  @doc "Projects an explicit ISO instant into the retained zone, preserving microseconds and precision."
  @spec localize(term(), term(), term()) :: {:ok, DateTime.t()} | {:error, atom()}
  def localize(%DateTime{calendar: Calendar.ISO} = datetime, name, context) do
    with {:ok, zone} <- context(context, name),
         true <- datetime?(datetime),
         {:ok, utc} <- DateTime.shift_zone(datetime, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase),
         {:ok, type} <- Tzif.offset(zone, DateTime.to_unix(utc, :millisecond)),
         :ok <- offset(type.offset) do
      shifted = DateTime.add(utc, type.offset, :second, Calendar.UTCOnlyTimeZoneDatabase)

      {:ok,
       %{
         shifted
         | time_zone: name,
           utc_offset: type.offset,
           std_offset: 0,
           zone_abbr: type.designation
       }}
    else
      false -> {:error, :invalid_timezone_projection}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_timezone_projection}
  end

  def localize(_, _, _), do: {:error, :invalid_timezone_projection}

  defp context(<<@tag, 0, size::unsigned-big-16, rest::binary>>, name)
       when size in 1..128 and byte_size(rest) >= size + 44 and byte_size(rest) <= size + 65_536 do
    <<installed::binary-size(size), bytes::binary>> = rest

    if installed == name,
      do: Tzif.decode(installed, bytes),
      else: {:error, :timezone_basis_mismatch}
  end

  defp context(_, _), do: {:error, :invalid_timezone_projection}

  defp nominal(%NaiveDateTime{calendar: Calendar.ISO, year: year, microsecond: {0, 0}} = value)
       when year in 1970..9999 do
    case NaiveDateTime.new(NaiveDateTime.to_date(value), NaiveDateTime.to_time(value)) do
      {:ok, ^value} -> :ok
      _ -> {:error, :invalid_timezone_projection}
    end
  end

  defp nominal(%NaiveDateTime{}), do: {:error, :unsupported_timezone_coordinate}
  defp nominal(_), do: {:error, :invalid_timezone_projection}

  defp resolved([], _, _), do: :gap
  defp resolved([due], nominal, zone), do: local(due, nominal, zone)

  defp resolved([first, second], nominal, zone) do
    with {:ok, first} <- local(first, nominal, zone),
         {:ok, second} <- local(second, nominal, zone),
         do: {:ambiguous, first, second}
  end

  defp resolved(_, _, _), do: {:error, :unsupported_timezone_multiplicity}

  defp local(due, nominal, zone) do
    with {:ok, type} <- Tzif.offset(zone, due),
         :ok <- offset(type.offset),
         {:ok, wall} <- DateTime.from_naive(nominal, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase) do
      {:ok,
       %{
         wall
         | time_zone: zone.name,
           utc_offset: type.offset,
           std_offset: 0,
           zone_abbr: type.designation
       }}
    end
  end

  defp offset(value) when value in -86_400..86_400, do: :ok
  defp offset(_), do: {:error, :unsupported_timezone_offset}

  defp datetime?(value) do
    is_integer(value.utc_offset) and is_integer(value.std_offset) and
      value.utc_offset in -86_400..86_400 and value.std_offset in -86_400..86_400 and
      (value.utc_offset + value.std_offset) in -86_400..86_400 and
      Calendar.ISO.valid_date?(value.year, value.month, value.day) and
      Calendar.ISO.valid_time?(value.hour, value.minute, value.second, value.microsecond) and
      Codec.integer?(elem(value.microsecond, 1), 0, 6)
  end
end
