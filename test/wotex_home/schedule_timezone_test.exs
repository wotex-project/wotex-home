defmodule WotexHome.ScheduleTimezoneTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Tzif, TzifFooter}
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  test "independent Python zoneinfo vectors cover gaps, folds, leap rules, southern and negative DST" do
    assert {:ok, %{"zones" => zones}} = @fixture |> File.read!() |> JSON.decode()
    assert length(zones) == 10

    for record <- zones do
      bytes = Base.decode64!(record["data_base64"])
      assert {:ok, zone} = Tzif.decode(record["name"], bytes)
      assert zone.digest == record["sha256"]
      assert Tzif.valid?(zone)

      for vector <- record["vectors"] do
        local = NaiveDateTime.from_iso8601!(vector["local"])
        assert {:ok, instants} = Tzif.resolve(zone, local)
        assert instants == vector["utc_ms"], "#{zone.name} #{vector["local"]}"
      end
    end
  end

  test "finite history uses type zero and exact transition boundaries, never extends an empty tail" do
    data = data([{1_000, 1}, {2_000, 0}], "")
    assert {:ok, zone} = Tzif.decode("Fixture/Finite", data)
    assert {:ok, %{offset: 0}} = Tzif.offset(zone, 999_999)
    assert {:ok, %{offset: 3_600}} = Tzif.offset(zone, 1_000_000)
    assert {:ok, %{offset: 3_600}} = Tzif.offset(zone, 1_999_999)
    assert {:error, :timezone_undefined} = Tzif.offset(zone, 2_000_000)
    assert {:error, :timezone_undefined} = Tzif.offset(zone, 2_000_001)
    assert {:ok, constant} = Tzif.decode("Fixture/Constant", data([], ""))
    assert {:ok, %{offset: 0}} = Tzif.offset(constant, 253_000_000_000_000)
  end

  test "complete original bytes prevent forged offsets, names or parsed footer fields" do
    assert {:ok, zone} = Tzif.decode("Fixture/UTC", data([], "UTC0"))
    refute Tzif.valid?(%{zone | offsets: [3_600]})
    refute Tzif.valid?(%{zone | digest: String.duplicate("a", 64)})
    refute Tzif.valid?(%{zone | name: "../../UTC"})

    assert {:error, :invalid_timezone_data} =
             Tzif.resolve(%{zone | offsets: [3_600]}, ~N[2026-01-01 12:00:00])

    assert {:error, :invalid_timezone_data} = Tzif.decode("/UTC", zone.bytes)
    assert {:error, :invalid_timezone_data} = Tzif.resolve(zone, ~N[2026-01-01 12:00:00.001])
  end

  test "count bounds, indexes, order, flags and complete framing refuse malformed TZif" do
    bytes = data([{1_000, 1}, {2_000, 0}], "")

    for broken <- [
          binary_part(bytes, 0, 43),
          bytes <> "ignored",
          binary_part(bytes, 0, byte_size(bytes) - 1),
          data([{1_000, 1}, {1_000, 0}], ""),
          data([{2_000, 1}, {1_000, 0}], ""),
          data([{1_000, 2}], ""),
          data([], "UTC0\nUTC0"),
          data([], "UTC0\0"),
          String.replace(bytes, "TZif2", "TZif1"),
          replace(bytes, 32, <<4_097::unsigned-big-32>>),
          replace(bytes, 28, <<1::unsigned-big-32>>),
          String.duplicate("x", 65_537)
        ] do
      assert {:error, :invalid_timezone_data} = Tzif.decode("Fixture/Broken", broken)
    end

    assert {:error, :invalid_timezone_data} =
             Tzif.decode("Fixture/Mismatch", data([{1_000, 1}], "UTC0"))
  end

  test "footer parsing rejects implicit platform rules, extended version-two times and unsafe offsets" do
    for footer <- [
          "EST5EDT",
          ":UTC0",
          "UTC26",
          "UTC25",
          "UTC0DST,M0.1.0,M10.5.0",
          "UTC0DST,M3.6.0,M10.5.0",
          "UTC0DST,J0,J365",
          "UTC0DST,366,300",
          "UTC0DST,M3.5.0/-2,M10.5.0",
          "UTC0DST,M3.5.0/25,M10.5.0",
          "UTC0DST,M3.5.0/2:60,M10.5.0"
        ] do
      assert {:error, :unsupported_timezone_footer} = TzifFooter.decode(footer, ?2)
    end

    assert {:error, :unsupported_timezone_footer} =
             TzifFooter.decode("UTC0DST,M3.5.0/168,M10.5.0", ?3)

    assert {:ok, nil} = TzifFooter.decode("", ?2)
    assert {:ok, _} = TzifFooter.decode("<-03>3<-02>,M3.5.0/-2,M10.5.0/-1", ?3)
  end

  test "version-four non-leap bytes share exact semantics and invalid indicator relationships refuse" do
    bytes = data([], "UTC0") |> String.replace("TZif2", "TZif4")
    assert {:ok, zone} = Tzif.decode("Fixture/UTC", bytes)
    assert {:ok, %{offset: 0}} = Tzif.offset(zone, 1_900_000_000_000)
    legacy_size = 54

    current =
      <<"TZif2", 0::120, 2::unsigned-big-32, 2::unsigned-big-32, 0::unsigned-big-32,
        0::unsigned-big-32, 2::unsigned-big-32, 8::unsigned-big-32>>

    rest =
      <<0::signed-big-32, 0, 0, 3_600::signed-big-32, 1, 4, "STD", 0, "DST", 0, 0, 0, 1, 0>> <>
        "\nUTC0\n"

    malformed = binary_part(data([], "UTC0"), 0, legacy_size) <> current <> rest
    assert {:error, :invalid_timezone_data} = Tzif.decode("Fixture/Flags", malformed)
  end

  test "unspecified designation never becomes a known offset" do
    bytes = data([], "") |> String.replace("STD", "-00")
    assert {:ok, zone} = Tzif.decode("Fixture/Undefined", bytes)
    assert {:error, :timezone_undefined} = Tzif.offset(zone, 1_900_000_000_000)
    assert {:error, :timezone_undefined} = Tzif.resolve(zone, ~N[2026-01-01 12:00:00])
  end

  defp data(transitions, footer) do
    legacy = header(0, 1, 4) <> <<0::signed-big-32, 0, 0, "STD", 0>>
    current = header(length(transitions), 2, 8)
    times = for {time, _} <- transitions, into: "", do: <<time::signed-big-64>>
    indexes = for {_, index} <- transitions, into: "", do: <<index>>

    legacy <>
      current <>
      times <>
      indexes <>
      <<0::signed-big-32, 0, 0, 3_600::signed-big-32, 1, 4, "STD", 0, "DST", 0>> <>
      "\n" <> footer <> "\n"
  end

  defp header(times, types, chars),
    do:
      <<"TZif2", 0::120, 0::unsigned-big-32, 0::unsigned-big-32, 0::unsigned-big-32,
        times::unsigned-big-32, types::unsigned-big-32, chars::unsigned-big-32>>

  defp replace(bytes, offset, value),
    do:
      binary_part(bytes, 0, offset) <>
        value <>
        binary_part(
          bytes,
          offset + byte_size(value),
          byte_size(bytes) - offset - byte_size(value)
        )
end
