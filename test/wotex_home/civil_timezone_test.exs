defmodule WotexHome.CivilTimezoneTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Schedules.{CalendarReference, CivilTimezone, RoutineTimezone, Tzif}

  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  test "the complete callback preserves all 230 independent labels and round trips" do
    corpus = JSON.decode!(File.read!(@fixture))

    count =
      for record <- corpus["zones"], reduce: 0 do
        count ->
          bytes = Base.decode64!(record["data_base64"])
          {:ok, reference} = CalendarReference.decode(record["name"], bytes)
          encoded = context(record["name"], bytes)

          for vector <- record["vectors"] do
            nominal = NaiveDateTime.from_iso8601!(vector["local"])
            assert CalendarReference.resolve(reference, nominal) == {:ok, vector["utc_ms"]}
            result = CivilTimezone.resolve_civil(nominal, record["name"], encoded)
            assert instants(result) == vector["utc_ms"]

            for local <- locals(result) do
              utc = local |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)
              utc = %{utc | microsecond: local.microsecond}
              assert {:ok, ^local} = CivilTimezone.localize(utc, record["name"], encoded)
            end
          end

          count + length(record["vectors"])
      end

    assert count == 230
  end

  test "wider offsets and complete threefold resolution retain exact metadata and legacy refusal" do
    for offset <- [-89_999, -86_400, 86_400, 93_599] do
      bytes = timezone([offset], [], String.duplicate("A", 32))
      name = "Fixture/Wide"

      assert {:ok, local} =
               CivilTimezone.resolve_civil(~N[2026-07-13 12:00:00], name, context(name, bytes))

      assert DateTime.to_unix(local) == DateTime.to_unix(~U[2026-07-13 12:00:00Z]) - offset
      assert local.utc_offset == offset and local.std_offset == 0
      assert local.zone_abbr == String.duplicate("A", 32)
      assert DateTime.to_naive(local) == ~N[2026-07-13 12:00:00]
      utc = DateTime.from_unix!(DateTime.to_unix(local))
      assert {:ok, ^local} = CivilTimezone.localize(utc, name, context(name, bytes))
    end

    ten = DateTime.to_unix(~U[2026-07-13 10:00:00Z])
    bytes = timezone([7200, 3600, 0], [{ten, 1}, {ten + 3600, 2}, {ten + 7200, 2}])
    encoded = context("Fixture/Multiple", bytes)

    assert {:ambiguous, values} =
             CivilTimezone.resolve_civil(~N[2026-07-13 11:30:00], "Fixture/Multiple", encoded)

    assert Enum.map(values, &DateTime.to_unix/1) ==
             Enum.map(
               [~U[2026-07-13 09:30:00Z], ~U[2026-07-13 10:30:00Z], ~U[2026-07-13 11:30:00Z]],
               &DateTime.to_unix/1
             )

    assert {:error, :unsupported_timezone_profile} = CivilTimezone.resolve(nil, nil, nil)
    legacy = <<"wotex-home.tzif-provider.v1", 0, 16::16, "Fixture/Multiple", bytes::binary>>

    assert {:error, :unsupported_timezone_multiplicity} =
             RoutineTimezone.resolve(~N[2026-07-13 11:30:00], "Fixture/Multiple", legacy)

    assert {:error, :invalid_timezone_projection} =
             CivilTimezone.resolve_civil(~N[2026-07-13 11:30:00], "Fixture/Multiple", legacy)
  end

  test "maximum type and distinct offset sets remain complete" do
    wall = DateTime.to_unix(~U[2026-07-13 12:00:00Z])
    offsets = Enum.to_list(255..0//-1)
    transitions = for(index <- 1..255, do: {wall - 255 + index, index}) ++ [{wall + 1, 255}]
    bytes = timezone(offsets, transitions)
    name = "Fixture/Maximum"
    {:ok, reference} = CalendarReference.decode(name, bytes)

    assert {:ambiguous, values} =
             CivilTimezone.resolve_civil(~N[2026-07-13 12:00:00], name, context(name, bytes))

    assert length(values) == 256
    expected = for index <- 0..255, do: (wall - 255 + index) * 1000
    assert Enum.map(values, &DateTime.to_unix(&1, :millisecond)) == expected
    assert CalendarReference.resolve(reference, ~N[2026-07-13 12:00:00]) == {:ok, expected}

    bytes = timezone(Enum.to_list(100..355), [], "UTC", "AAA0BBB-1,M3.2.0,M11.1.0")
    {:ok, zone} = Tzif.decode(name, bytes)
    assert length(zone.offsets) == 258

    assert {:ok, local} =
             CivilTimezone.resolve_civil(~N[2026-07-13 12:00:00], name, context(name, bytes))

    assert DateTime.to_unix(local) == wall - 3600
    assert local.zone_abbr == "BBB"
  end

  test "fractional and boundary localization retains the instant and precision" do
    for offset <- [-89_999, 0, 93_599],
        utc <- [~U[1970-01-01 00:00:00Z], ~U[2026-07-13 12:00:00.123456Z]] do
      bytes = timezone([offset], [])

      assert {:ok, local} =
               CivilTimezone.localize(utc, "Fixture/Wide", context("Fixture/Wide", bytes))

      assert local.microsecond == utc.microsecond
      assert DateTime.compare(local, utc) == :eq
      assert local.year in 1969..2026
    end

    encoded = context("Fixture/UTC", timezone([0], []))

    assert {:ok, local} =
             CivilTimezone.localize(~U[9999-12-31 23:58:59.999999Z], "Fixture/UTC", encoded)

    assert local.microsecond == {999_999, 6}

    assert {:error, :unsupported_timezone_coordinate} =
             CivilTimezone.localize(~U[9999-12-31 23:59:00Z], "Fixture/UTC", encoded)

    assert :gap == CivilTimezone.resolve_civil(~N[9999-12-31 23:59:00], "Fixture/UTC", encoded)
    assert {:ok, _} = CivilTimezone.resolve_civil(~N[1970-01-01 00:00:00], "Fixture/UTC", encoded)
    wide = context("Fixture/Wide", timezone([93_599], []))

    assert {:error, :unsupported_timezone_coordinate} =
             CivilTimezone.localize(~U[9999-12-31 23:58:59Z], "Fixture/Wide", wide)
  end

  test "undefined phases refuse explicitly and a genuine gap remains empty" do
    first = DateTime.to_unix(~U[2026-07-13 10:00:00Z])
    bytes = timezone([0, 3600], [{first, 1}, {first + 7200, 1}])
    name = "Fixture/Finite"
    encoded = context(name, bytes)
    assert :gap == CivilTimezone.resolve_civil(~N[2026-07-13 10:30:00], name, encoded)

    assert {:error, :timezone_undefined} =
             CivilTimezone.resolve_civil(~N[2026-07-14 12:00:00], name, encoded)

    assert {:error, :timezone_undefined} =
             CivilTimezone.localize(~U[2026-07-14 12:00:00Z], name, encoded)
  end

  test "invalid native values, context and producer absence fail without private payloads" do
    name = "Fixture/UTC"
    bytes = timezone([0], [])
    encoded = context(name, bytes)
    {:ok, zone} = Tzif.decode(name, bytes)
    assert {:error, :invalid_timezone_data} = CivilTimezone.provider(%{zone | offsets: [1]})

    if Code.ensure_loaded?(ExBooking.TimeZoneProvider) and
         function_exported?(ExBooking, :civil_occurrences, 3) do
      assert {:ok, provider} = CivilTimezone.provider(zone)
      assert provider.module == CivilTimezone and provider.context == encoded
    else
      assert {:error, :routine_timezone_unavailable} = CivilTimezone.provider(zone)
    end

    for bad <- [
          nil,
          "",
          binary_part(encoded, 0, 10),
          encoded <> "trailing",
          context(name, <<0::352>>)
        ] do
      assert {:error, :invalid_timezone_projection} =
               CivilTimezone.resolve_civil(~N[2026-07-13 12:00:00], name, bad)

      assert {:error, :invalid_timezone_projection} =
               CivilTimezone.localize(~U[2026-07-13 12:00:00Z], name, bad)
    end

    assert {:error, :timezone_basis_mismatch} =
             CivilTimezone.resolve_civil(~N[2026-07-13 12:00:00], "Other/Zone", encoded)

    for bad <- [
          nil,
          Map.put(~N[2026-07-13 12:00:00], :extra, nil),
          %{~N[2026-07-13 12:00:00] | month: 13}
        ] do
      assert {:error, :invalid_timezone_projection} =
               CivilTimezone.resolve_civil(bad, name, encoded)
    end

    for bad <- [~N[1969-12-31 12:00:00], ~N[2026-07-13 12:00:00.000000]] do
      assert {:error, :unsupported_timezone_coordinate} =
               CivilTimezone.resolve_civil(bad, name, encoded)
    end

    for bad <- [
          nil,
          Map.put(~U[2026-07-13 12:00:00Z], :extra, nil),
          %{~U[2026-07-13 12:00:00Z] | utc_offset: 93_600},
          %{~U[2026-07-13 12:00:00Z] | utc_offset: -90_000},
          %{~U[2026-07-13 12:00:00Z] | zone_abbr: <<255>>},
          %{~U[2026-07-13 12:00:00Z] | month: 13}
        ] do
      assert {:error, :invalid_timezone_projection} = CivilTimezone.localize(bad, name, encoded)
    end
  end

  defp timezone(offsets, transitions, designation \\ "UTC", footer \\ "") do
    legacy = header(0, 1, 4) <> <<0::signed-big-32, 0, 0, "UTC", 0>>
    current = header(length(transitions), length(offsets), byte_size(designation) + 1)
    times = Enum.map_join(transitions, fn {time, _} -> <<time::signed-big-64>> end)
    indexes = Enum.map_join(transitions, fn {_, index} -> <<index>> end)
    types = Enum.map_join(offsets, &<<&1::signed-big-32, 0, 0>>)
    legacy <> current <> times <> indexes <> types <> designation <> <<0, 10>> <> footer <> <<10>>
  end

  defp header(times, types, chars),
    do: <<"TZif2", 0::120, 0::32, 0::32, 0::32, times::32, types::32, chars::32>>

  defp context(name, bytes),
    do:
      <<"wotex-home.civil-tzif-provider.v1", 0, byte_size(name)::16, name::binary, bytes::binary>>

  defp locals(:gap), do: []
  defp locals({:ok, local}), do: [local]
  defp locals({:ambiguous, values}), do: values
  defp instants(result), do: Enum.map(locals(result), &DateTime.to_unix(&1, :millisecond))
end
