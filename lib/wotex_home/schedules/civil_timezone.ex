defmodule WotexHome.Schedules.CivilTimezone do
  @moduledoc """
  Supplies complete civil-time resolution from exact immutable Home TZif bytes.

  `provider/1` revalidates a `WotexHome.Schedules.Tzif` value and returns
  `{:ok, provider}` for the optional ExBooking civil operation. Its versioned
  binary context retains the exact zone name and original bytes. Both civil
  callbacks decode that context again and require the supplied name to match;
  they never consult host timezone configuration or substitute another dataset.

  `resolve_civil/3` takes an exact ISO `NaiveDateTime` in years 1970–9999 with
  microsecond precision `{0, 0}`. It returns `:gap`, `{:ok, local}` or
  `{:ambiguous, locals}`. An ambiguity retains every supported instant as a
  strictly UTC-ordered list of 2–258 local DateTimes, without selecting a fold
  policy. A gap means no instant within Home's supported UTC range; undefined
  timezone data remains an error. The required legacy `resolve/3` always returns
  `{:error, :unsupported_timezone_profile}`, so this provider cannot silently
  enter RRULE calculation. `WotexHome.Schedules.RoutineTimezone` keeps that
  separate purpose and its existing bounds.

  `localize/3` accepts an exact valid ISO `DateTime` in years 0000–9999 and returns
  `{:ok, local}` while preserving its UTC instant, microseconds and precision.
  Input offset components may each span `-93_599..93_599` seconds, with their
  total in `-89_999..93_599`. Both civil callbacks use Home's supported UTC range
  of `0..253_402_300_739_999` integral milliseconds. Localization may yield local
  fields in 1969 at the lower boundary. Returned DateTimes retain the exact name
  and designation, put the installed total offset in `utc_offset` and set
  `std_offset` to zero; this does not infer a standard/daylight identity.

  Refusals have shape `{:error, reason}`. Invalid source values use
  `:invalid_timezone_data`; unavailable producer capability uses
  `:routine_timezone_unavailable`. Malformed native inputs/context use
  `:invalid_timezone_projection`, a different retained name uses
  `:timezone_basis_mismatch`. Unsupported nominal year/precision, UTC range or
  projected local year uses `:unsupported_timezone_coordinate`. Undefined-data
  refusals remain errors without becoming gaps or partial results.
  This pure provider supplies calendar correspondence, not clock confidence,
  schedule admission or effect authority.
  """

  alias WotexHome.Schedules.{Codec, Tzif}

  @tag "wotex-home.civil-tzif-provider.v1"
  @naive_fields NaiveDateTime |> struct() |> Map.keys() |> Enum.sort()
  @datetime_fields DateTime |> struct() |> Map.keys() |> Enum.sort()

  @doc "Constructs the civil provider from a fully checked immutable timezone value."
  @spec provider(term()) :: {:ok, map()} | {:error, atom()}
  def provider(zone) do
    cond do
      not Tzif.valid?(zone) ->
        {:error, :invalid_timezone_data}

      not available?() ->
        {:error, :routine_timezone_unavailable}

      true ->
        context = <<@tag, 0, byte_size(zone.name)::16, zone.name::binary, zone.bytes::binary>>
        arguments = [__MODULE__, context]
        apply(ExBooking.TimeZoneProvider, :new, arguments)
    end
  rescue
    UndefinedFunctionError -> {:error, :routine_timezone_unavailable}
  end

  @doc "Refuses the legacy recurrence purpose; use the complete civil callback."
  @spec resolve(term(), term(), term()) :: {:error, :unsupported_timezone_profile}
  def resolve(_, _, _), do: {:error, :unsupported_timezone_profile}

  @doc "Resolves the complete ordered set for an exact whole-second local label."
  @spec resolve_civil(term(), term(), term()) ::
          {:ok, DateTime.t()} | {:ambiguous, [DateTime.t()]} | :gap | {:error, atom()}
  def resolve_civil(nominal, name, context) do
    with {:ok, zone} <- context(context, name),
         :ok <- nominal(nominal),
         {:ok, instants} <- Tzif.resolve(zone, nominal) do
      resolved(instants, nominal, zone)
    end
  rescue
    _ -> invalid()
  end

  @doc "Localizes an explicit civil-profile ISO instant without losing microsecond precision."
  @spec localize(term(), term(), term()) :: {:ok, DateTime.t()} | {:error, atom()}
  def localize(datetime, name, context) do
    with {:ok, zone} <- context(context, name),
         true <- datetime?(datetime),
         {:ok, utc} <- DateTime.shift_zone(datetime, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase),
         :ok <- coordinate(utc),
         {:ok, type} <- Tzif.offset(zone, DateTime.to_unix(utc, :millisecond)),
         {:ok, wall} <- shifted(utc, type.offset) do
      {:ok,
       %{
         wall
         | time_zone: name,
           utc_offset: type.offset,
           std_offset: 0,
           zone_abbr: type.designation
       }}
    else
      false -> invalid()
      error -> error
    end
  rescue
    _ -> invalid()
  end

  defp available? do
    Code.ensure_loaded?(ExBooking.TimeZoneProvider) and
      function_exported?(ExBooking.TimeZoneProvider, :new, 2) and
      Code.ensure_loaded?(ExBooking) and function_exported?(ExBooking, :civil_occurrences, 3)
  end

  defp context(<<@tag, 0, size::16, rest::binary>>, name)
       when size in 1..128 and byte_size(rest) >= size + 44 and byte_size(rest) <= size + 65_536 do
    <<installed::binary-size(size), bytes::binary>> = rest

    cond do
      not Codec.zone?(name) ->
        invalid()

      installed != name ->
        {:error, :timezone_basis_mismatch}

      true ->
        case Tzif.decode(installed, bytes) do
          {:ok, zone} -> {:ok, zone}
          _ -> invalid()
        end
    end
  end

  defp context(_, _), do: invalid()

  defp nominal(%NaiveDateTime{calendar: Calendar.ISO} = value)
       when map_size(value) == length(@naive_fields) do
    cond do
      Enum.sort(Map.keys(value)) != @naive_fields or not fields?(value) ->
        invalid()

      value.year not in 1970..9999 or value.microsecond != {0, 0} ->
        {:error, :unsupported_timezone_coordinate}

      true ->
        :ok
    end
  end

  defp nominal(_), do: invalid()

  defp resolved([], _, _), do: :gap
  defp resolved([due], nominal, zone), do: local(due, nominal, zone)

  defp resolved(instants, nominal, zone) when length(instants) in 2..258 do
    Enum.reduce_while(instants, {:ok, []}, fn due, {:ok, locals} ->
      case local(due, nominal, zone) do
        {:ok, value} -> {:cont, {:ok, [value | locals]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, locals} -> {:ambiguous, Enum.reverse(locals)}
      error -> error
    end
  end

  defp resolved(_, _, _), do: invalid()

  defp local(due, nominal, zone) do
    with {:ok, type} <- Tzif.offset(zone, due),
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

  defp coordinate(utc) do
    if Codec.utc?(DateTime.to_unix(utc, :millisecond)),
      do: :ok,
      else: {:error, :unsupported_timezone_coordinate}
  end

  defp shifted(utc, offset) do
    case DateTime.from_unix(
           DateTime.to_unix(utc, :microsecond) + offset * 1_000_000,
           :microsecond
         ) do
      {:ok, wall} -> {:ok, %{wall | microsecond: utc.microsecond}}
      _ -> {:error, :unsupported_timezone_coordinate}
    end
  end

  defp datetime?(%DateTime{calendar: Calendar.ISO} = value)
       when map_size(value) == length(@datetime_fields) do
    Enum.sort(Map.keys(value)) == @datetime_fields and value.year in 0..9999 and fields?(value) and
      text?(value.time_zone, 1) and text?(value.zone_abbr, 0) and
      is_integer(value.utc_offset) and is_integer(value.std_offset) and
      value.utc_offset in -93_599..93_599 and value.std_offset in -93_599..93_599 and
      (value.utc_offset + value.std_offset) in -89_999..93_599
  end

  defp datetime?(_), do: false

  defp fields?(value) do
    Calendar.ISO.valid_date?(value.year, value.month, value.day) and
      Calendar.ISO.valid_time?(value.hour, value.minute, value.second, value.microsecond) and
      Codec.integer?(elem(value.microsecond, 1), 0, 6)
  end

  defp text?(value, minimum),
    do: is_binary(value) and byte_size(value) in minimum..256 and String.valid?(value)

  defp invalid, do: {:error, :invalid_timezone_projection}
end
