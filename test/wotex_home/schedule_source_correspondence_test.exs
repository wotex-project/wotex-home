defmodule WotexHome.ScheduleSourceCorrespondenceTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, SourceCorrespondence, Tzif}

  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)
  @source %{
    "id" => "schedule:actual",
    "source_revision" => 2,
    "author_id" => "operator:one",
    "rule_id" => "rule:one",
    "rule_source_digest" => String.duplicate("a", 64),
    "target_id" => "light:one",
    "resource_revision" => 4,
    "late_window_ms" => 10_000,
    "uncertainty_tolerance_ms" => 100,
    "trigger" => ["interval", 7_777, 60_001, 0, nil]
  }

  test "actual interval anchors, periods and exclusive bounds agree with independent floor arithmetic" do
    triggers = [
      ["interval", 0, 60_000, 0, nil],
      ["interval", 7_777, 60_001, 0, nil],
      ["interval", 7_777, 60_001, 67_779, 187_781],
      ["interval", 7_777, 60_001, 67_779, 127_779],
      ["interval", 7_777, 60_001, 0, 7_777],
      ["interval", 1_900_000_000_001, 2_678_400_000, 1_900_000_000_002, nil],
      ["interval", Codec.utc_maximum() - 60_000, 60_000, 0, nil],
      ["interval", 0, 2_678_400_000, Codec.utc_maximum() - 60_000, nil]
    ]

    for trigger <- triggers, {late, tolerance} <- [{1_000, 0}, {10_000, 100}, {60_000, 1_000}] do
      source = %{
        @source
        | "trigger" => trigger,
          "late_window_ms" => late,
          "uncertainty_tolerance_ms" => tolerance
      }

      assert :ok = SourceCorrespondence.check(source), inspect(trigger)
    end
  end

  test "actual countdown boot, generation, start and duration use continuous time without wall confidence" do
    triggers = [
      ["countdown", "boot:actual", 41, 7_777, 1_000],
      ["countdown", "boot:source-correspondence", 1, 0, 86_400_000],
      ["countdown", "boot:actual", Codec.maximum(), Codec.maximum() - 86_460_000, 86_400_000]
    ]

    for trigger <- triggers, late <- [1_000, 10_000, 60_000] do
      assert :ok =
               SourceCorrespondence.check(%{
                 @source
                 | "trigger" => trigger,
                   "late_window_ms" => late
               })
    end
  end

  test "calendar cursor consumption uses the pinned source's coordinates and bounds" do
    zone = zone("Fixture/Stockholm")
    assert {:ok, [first, second]} = Tzif.resolve(zone, ~N[2026-10-25 02:30:00])

    triggers = [
      ["once", zone.name, zone.digest, "2026-10-25", "02:30:00", first],
      ["once", zone.name, zone.digest, "2026-10-25", "02:30:00", second],
      ["daily", zone.name, zone.digest, "02:30:00", first - 1, nil],
      ["daily", zone.name, zone.digest, "02:30:00", first + 1, second + 1],
      ["weekdays", zone.name, zone.digest, "02:30:00", [1, 3, 7], first + 1, nil],
      ["weekdays", zone.name, zone.digest, "02:30:00", [1, 3], first - 1, second + 1]
    ]

    for trigger <- triggers do
      assert :ok = SourceCorrespondence.check(%{@source | "trigger" => trigger}, zone)
    end
  end

  test "malformed sources, unused zones and mismatched calendar custody refuse" do
    zone = zone("Fixture/Stockholm")

    assert {:error, :invalid_schedule_source} =
             SourceCorrespondence.check(Map.put(@source, "timer", true))

    assert {:error, :unexpected_timezone_basis} = SourceCorrespondence.check(@source, zone)
    calendar = %{@source | "trigger" => ["daily", zone.name, zone.digest, "02:30:00", 0, nil]}
    assert {:error, :timezone_basis_required} = SourceCorrespondence.check(calendar)

    assert {:error, :timezone_basis_mismatch} =
             SourceCorrespondence.check(calendar, %{zone | offsets: [0]})
  end

  defp zone(name) do
    record = JSON.decode!(File.read!(@fixture))["zones"] |> Enum.find(&(&1["name"] == name))
    {:ok, zone} = Tzif.decode(name, Base.decode64!(record["data_base64"]))
    zone
  end
end
