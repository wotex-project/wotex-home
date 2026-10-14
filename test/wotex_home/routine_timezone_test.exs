defmodule WotexHome.RoutineTimezoneTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Schedules.{CalendarReference, RoutineTimezone, Tzif}

  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  test "all independent local labels retain exact original instants through the explicit context" do
    corpus = JSON.decode!(File.read!(@fixture))

    count =
      Enum.reduce(corpus["zones"], 0, fn record, count ->
        bytes = Base.decode64!(record["data_base64"])
        {:ok, reference} = CalendarReference.decode(record["name"], bytes)
        context = context(record["name"], bytes)

        for vector <- record["vectors"] do
          nominal = NaiveDateTime.from_iso8601!(vector["local"])
          expected = vector["utc_ms"]
          assert CalendarReference.resolve(reference, nominal) == {:ok, expected}
          assert instants(RoutineTimezone.resolve(nominal, record["name"], context)) == expected

          for due <- expected do
            utc = DateTime.from_unix!(due, :millisecond) |> DateTime.truncate(:second)
            assert {:ok, local} = RoutineTimezone.localize(utc, record["name"], context)
            assert DateTime.to_naive(local) == nominal
            assert DateTime.to_unix(local, :millisecond) == due
          end
        end

        count + length(record["vectors"])
      end)

    assert count == 230
  end

  test "fractional endpoints and two supplied zones preserve instant and independent context" do
    records = JSON.decode!(File.read!(@fixture))["zones"] |> Enum.take(2)

    for record <- records do
      bytes = Base.decode64!(record["data_base64"])
      utc = ~U[2026-07-13 06:00:00.123456Z]

      assert {:ok, local} =
               RoutineTimezone.localize(utc, record["name"], context(record["name"], bytes))

      assert local.microsecond == utc.microsecond
      assert DateTime.compare(local, utc) == :eq
      assert local.time_zone == record["name"]
      assert local.std_offset == 0
    end
  end

  test "closed framing, foreign zone, native forgery and unsupported precision refuse" do
    record = hd(JSON.decode!(File.read!(@fixture))["zones"])
    bytes = Base.decode64!(record["data_base64"])
    {:ok, zone} = Tzif.decode(record["name"], bytes)
    encoded = context(record["name"], bytes)
    assert {:error, :invalid_timezone_data} = RoutineTimezone.provider(%{zone | offsets: [0]})
    assert {:error, :invalid_timezone_data} = RoutineTimezone.provider(nil)

    if not Code.ensure_loaded?(ExBooking.TimeZoneProvider),
      do: assert(RoutineTimezone.provider(zone) == {:error, :routine_timezone_unavailable})

    assert {:error, :timezone_basis_mismatch} =
             RoutineTimezone.resolve(~N[2026-07-13 06:00:00], "Other/Zone", encoded)

    for malformed <- [
          nil,
          "",
          binary_part(encoded, 0, 10),
          encoded <> "trailing",
          <<"wotex-home.tzif-provider.v1", 0, 65535::16, "short">>
        ] do
      assert {:error, _} =
               RoutineTimezone.resolve(~N[2026-07-13 06:00:00], record["name"], malformed)

      assert {:error, _} =
               RoutineTimezone.localize(~U[2026-07-13 06:00:00Z], record["name"], malformed)
    end

    for nominal <- [
          ~N[2026-07-13 06:00:00.000000],
          ~N[2026-07-13 06:00:00.123456],
          ~N[1969-12-31 23:59:59]
        ] do
      assert {:error, :unsupported_timezone_coordinate} =
               RoutineTimezone.resolve(nominal, record["name"], encoded)
    end

    for nominal <- [nil, %{~N[2026-07-13 06:00:00] | month: 13}] do
      assert {:error, :invalid_timezone_projection} =
               RoutineTimezone.resolve(nominal, record["name"], encoded)
    end

    for datetime <- [
          nil,
          %{~U[2026-07-13 06:00:00Z] | month: 13},
          %{~U[2026-07-13 06:00:00Z] | utc_offset: "invalid"},
          %{~U[2026-07-13 06:00:00Z] | time_zone: nil},
          %{~U[2026-07-13 06:00:00Z] | zone_abbr: 1},
          Map.put(~U[2026-07-13 06:00:00Z], :extra, true)
        ] do
      assert {:error, :invalid_timezone_projection} =
               RoutineTimezone.localize(datetime, record["name"], encoded)
    end
  end

  test "wider TZif offsets and more than two fold instants remain explicit unsupported joins" do
    wide = timezone([86_401], [])
    {:ok, _zone} = Tzif.decode("Fixture/Wide", wide)

    assert {:error, :unsupported_timezone_offset} =
             RoutineTimezone.resolve(
               ~N[2026-07-13 12:00:00],
               "Fixture/Wide",
               context("Fixture/Wide", wide)
             )

    assert {:error, :unsupported_timezone_offset} =
             RoutineTimezone.localize(
               ~U[2026-07-13 12:00:00Z],
               "Fixture/Wide",
               context("Fixture/Wide", wide)
             )

    ten = DateTime.to_unix(~U[2026-07-13 10:00:00Z])
    multiple = timezone([7200, 3600, 0], [{ten, 1}, {ten + 3600, 2}, {ten + 7200, 2}])
    {:ok, zone} = Tzif.decode("Fixture/Multiple", multiple)
    assert {:ok, instants} = Tzif.resolve(zone, ~N[2026-07-13 11:30:00])
    assert length(instants) == 3

    assert {:error, :unsupported_timezone_multiplicity} =
             RoutineTimezone.resolve(
               ~N[2026-07-13 11:30:00],
               zone.name,
               context(zone.name, multiple)
             )
  end

  defp timezone(offsets, transitions) do
    legacy = header(0, 1, 4) <> <<0::signed-big-32, 0, 0, "UTC", 0>>
    current = header(length(transitions), length(offsets), 4)
    times = Enum.map_join(transitions, fn {time, _} -> <<time::signed-big-64>> end)
    indexes = Enum.map_join(transitions, fn {_, index} -> <<index>> end)
    types = Enum.map_join(offsets, &<<&1::signed-big-32, 0, 0>>)
    legacy <> current <> times <> indexes <> types <> <<"UTC", 0, "\n\n">>
  end

  defp header(times, types, chars),
    do:
      <<"TZif2", 0::120, 0::unsigned-big-32, 0::unsigned-big-32, 0::unsigned-big-32,
        times::unsigned-big-32, types::unsigned-big-32, chars::unsigned-big-32>>

  defp context(name, bytes),
    do:
      <<"wotex-home.tzif-provider.v1", 0, byte_size(name)::unsigned-big-16, name::binary,
        bytes::binary>>

  defp instants(:gap), do: []
  defp instants({:ok, datetime}), do: [DateTime.to_unix(datetime, :millisecond)]

  defp instants({:ambiguous, first, second}),
    do: Enum.map([first, second], &DateTime.to_unix(&1, :millisecond))
end
