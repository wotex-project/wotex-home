defmodule WotexHome.ScheduleRecurrenceTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, Occurrence, Recurrence, Tzif, Window}
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)
  @hash String.duplicate("a", 64)
  @source %{
    "id" => "schedule:one",
    "source_revision" => 2,
    "author_id" => "operator:one",
    "rule_id" => "rule:one",
    "rule_source_digest" => @hash,
    "target_id" => "light:one",
    "resource_revision" => 4,
    "late_window_ms" => 10_000,
    "uncertainty_tolerance_ms" => 100,
    "trigger" => ["interval", 100_000, 60_000, 100_000, nil]
  }

  test "independent Python recurrence vectors skip gaps and use only the first folded instant" do
    corpus = JSON.decode!(File.read!(@fixture))

    zones =
      Map.new(corpus["zones"], fn record ->
        {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
        {zone.name, zone}
      end)

    assert length(corpus["next_cases"]) == 112

    for vector <- corpus["next_cases"] do
      zone = zones[vector["zone"]]

      source =
        calendar_source(
          zone,
          vector["time"],
          vector["days"],
          vector["start_ms"],
          vector["end_ms"]
        )

      assert {:ok, result} = Recurrence.next(source, vector["after_ms"], zone)
      assert result == vector["next_ms"], inspect(vector)
      if result != nil, do: assert(Recurrence.coordinate(source, result, zone) == :ok)
    end
  end

  test "one-shot ambiguity requires the selected valid UTC instant and exact local label" do
    zone = zone("Fixture/Stockholm")
    assert {:ok, [first, second]} = Tzif.resolve(zone, ~N[2026-10-25 02:30:00])

    for chosen <- [first, second] do
      source = %{
        @source
        | "trigger" => ["once", zone.name, zone.digest, "2026-10-25", "02:30:00", chosen]
      }

      assert :ok = Recurrence.validate_source(source, zone)
      assert {:ok, ^chosen} = Recurrence.next(source, chosen - 1, zone)
      assert {:ok, nil} = Recurrence.next(source, chosen, zone)
      assert {:ok, occurrence} = Occurrence.build(source, 7, 3, ["utc", chosen])

      assert {:ok, :eligible} =
               Window.check(source, occurrence, sample(chosen), "boot:one", 5, 1_000, zone)

      assert {:error, :timezone_basis_required} =
               Window.check(source, occurrence, sample(chosen), "boot:one", 5, 1_000)
    end

    source = %{
      @source
      | "trigger" => ["once", zone.name, zone.digest, "2026-10-25", "02:30:00", first + 1]
    }

    assert {:error, :invalid_resolved_schedule_time} = Recurrence.validate_source(source, zone)

    gap = %{
      @source
      | "trigger" => ["once", zone.name, zone.digest, "2026-03-29", "02:30:00", first]
    }

    assert {:error, :invalid_resolved_schedule_time} = Recurrence.validate_source(gap, zone)
  end

  test "daily folded second never becomes eligible even after first is considered or before start" do
    zone = zone("Fixture/Stockholm")
    assert {:ok, [first, second]} = Tzif.resolve(zone, ~N[2026-10-25 02:30:00])
    source = calendar_source(zone, "02:30:00", Enum.to_list(1..7), first - 1, nil)
    assert :ok = Recurrence.coordinate(source, first, zone)
    assert {:error, :schedule_coordinate_mismatch} = Recurrence.coordinate(source, second, zone)
    assert {:ok, next} = Recurrence.next(source, first, zone)
    assert next > second
    later_start = calendar_source(zone, "02:30:00", Enum.to_list(1..7), first + 1, nil)
    assert {:ok, ^next} = Recurrence.next(later_start, first, zone)
    assert {:ok, occurrence} = Occurrence.build(source, 7, 3, ["utc", second])

    assert {:error, :schedule_coordinate_mismatch} =
             Window.check(source, occurrence, sample(second), "boot:one", 5, 1_000, zone)
  end

  test "timezone replacement, forged parsed fields and changed source refuse existing calculations" do
    zone = zone("Fixture/Stockholm")
    source = calendar_source(zone, "02:30:00", [1, 3, 7], 0, nil)
    assert {:error, :timezone_basis_required} = Recurrence.next(source, 1_700_000_000_000)

    assert {:error, :timezone_basis_mismatch} =
             Recurrence.next(source, 1_700_000_000_000, zone("Fixture/New_York"))

    assert {:error, :timezone_basis_mismatch} =
             Recurrence.next(source, 1_700_000_000_000, %{zone | offsets: [0]})

    assert {:ok, due} = Recurrence.next(source, 1_700_000_000_000, zone)
    assert {:error, :schedule_coordinate_mismatch} = Recurrence.coordinate(source, due + 1, zone)
    assert {:error, :invalid_schedule_cursor} = Recurrence.next(source, -2, zone)
    assert {:error, :invalid_schedule_cursor} = Recurrence.next(source, true, zone)
  end

  test "fixed intervals stay anchored across enormous downtime without iteration or catch-up" do
    assert {:ok, 100_000} = Recurrence.next(@source, -1)
    assert {:ok, 100_000} = Recurrence.next(@source, 99_999)
    assert {:ok, 160_000} = Recurrence.next(@source, 100_000)
    assert {:ok, 160_000} = Recurrence.next(@source, 159_999)
    assert {:ok, 1_900_000_060_000} = Recurrence.next(@source, 1_900_000_000_000)
    bounded = %{@source | "trigger" => ["interval", 100_000, 60_000, 160_001, 220_001]}
    assert {:ok, 220_000} = Recurrence.next(bounded, 0)
    assert {:ok, nil} = Recurrence.next(bounded, 220_000)

    near_end = %{
      @source
      | "trigger" => ["interval", Codec.utc_maximum() - 60_000, 60_000, 0, nil]
    }

    assert {:ok, nil} = Recurrence.next(near_end, Codec.utc_maximum() - 60_000)
    countdown = %{@source | "trigger" => ["countdown", "boot:one", 5, 0, 1_000]}
    assert {:error, :monotonic_schedule} = Recurrence.next(countdown, 0)
  end

  test "the final UTC cursor and a local label beyond the final year are exhausted calendars" do
    maximum = Codec.utc_maximum() - 60_000

    for name <- ["Fixture/UTC", "Fixture/Stockholm"],
        days <- [Enum.to_list(1..7), [1, 3, 7]],
        after_ms <- [maximum - 1, maximum] do
      zone = zone(name)
      source = calendar_source(zone, "12:00:00", days, 0, nil)
      assert {:ok, nil} = Recurrence.next(source, after_ms, zone)
    end
  end

  defp zone(name) do
    record = JSON.decode!(File.read!(@fixture))["zones"] |> Enum.find(&(&1["name"] == name))
    {:ok, zone} = Tzif.decode(name, Base.decode64!(record["data_base64"]))
    zone
  end

  defp calendar_source(zone, time, days, start, finish) do
    trigger =
      if days == Enum.to_list(1..7),
        do: ["daily", zone.name, zone.digest, time, start, finish],
        else: ["weekdays", zone.name, zone.digest, time, days, start, finish]

    %{@source | "trigger" => trigger}
  end

  defp sample(due),
    do: %{
      "source_id" => "clock:fixture",
      "qualification_digest" => @hash,
      "boot_epoch" => "boot:one",
      "generation" => 5,
      "sampled_monotonic_ms" => 1_000,
      "utc_lower_ms" => due,
      "utc_upper_ms" => due,
      "maximum_age_ms" => 60_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }
end
