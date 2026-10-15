defmodule WotexHome.RoutineCalendarTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Schedules.{RoutineCalendar, Tzif}

  setup do
    corpus =
      JSON.decode!(
        File.read!(Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__))
      )

    record = hd(corpus["zones"])
    {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))

    source = %{
      "id" => "schedule:one",
      "source_revision" => 1,
      "author_id" => "operator:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => String.duplicate("a", 64),
      "target_id" => "light:one",
      "resource_revision" => 1,
      "late_window_ms" => 10000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" => ["daily", zone.name, zone.digest, "12:00:00", 0, nil]
    }

    %{zone: zone, source: source}
  end

  test "closed calendar inputs refuse before optional producer lookup", c do
    assert RoutineCalendar.resolve(%{}, ~N[2026-07-13 12:00:00], c.zone) ==
             {:error, :invalid_schedule_source}

    assert RoutineCalendar.resolve(c.source, ~N[2026-07-13 13:00:00], c.zone) ==
             {:error, :schedule_coordinate_mismatch}

    assert RoutineCalendar.resolve(
             c.source,
             Map.put(~N[2026-07-13 12:00:00], :extra, nil),
             c.zone
           ) == {:error, :invalid_timezone_projection}

    assert RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00.000000], c.zone) ==
             {:error, :unsupported_timezone_coordinate}

    assert RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00], nil) ==
             {:error, :timezone_basis_required}

    assert RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00], %{c.zone | offsets: []}) ==
             {:error, :timezone_basis_mismatch}

    assert RoutineCalendar.next(c.source, -2, c.zone) == {:error, :invalid_schedule_cursor}

    assert RoutineCalendar.coordinate(c.source, -1, c.zone) ==
             {:error, :schedule_coordinate_mismatch}
  end

  test "malformed native fields and alternate calendars are distinct from unsupported coordinates",
       c do
    for bad <- [
          nil,
          %{~N[2026-07-13 12:00:00] | month: 13},
          %{~N[2026-07-13 12:00:00] | calendar: Calendar.UTCOnlyTimeZoneDatabase},
          Map.put(~N[2026-07-13 12:00:00], :extra, nil)
        ] do
      result = RoutineCalendar.resolve(c.source, bad, c.zone)

      assert result == {:error, :invalid_timezone_projection},
             "native fields #{inspect(if is_map(bad), do: Map.take(bad, [:calendar, :month]), else: bad)} returned #{inspect(result)}"
    end

    assert RoutineCalendar.resolve(c.source, ~N[1969-07-13 12:00:00], c.zone) ==
             {:error, :unsupported_timezone_coordinate}
  end

  test "nonselected weekdays and exhausted bounds remain explicit finite results", c do
    source = %{
      c.source
      | "trigger" => ["weekdays", c.zone.name, c.zone.digest, "12:00:00", [2], 0, nil]
    }

    assert RoutineCalendar.resolve(source, ~N[2026-07-13 12:00:00], c.zone) == {:ok, []}
    source = %{c.source | "trigger" => ["daily", c.zone.name, c.zone.digest, "12:00:00", 0, 1000]}
    assert RoutineCalendar.next(source, 1000, c.zone) == {:ok, nil}
    noncalendar = %{c.source | "trigger" => ["interval", 0, 60000, 0, nil]}

    assert RoutineCalendar.resolve(noncalendar, ~N[2026-07-13 12:00:00], nil) ==
             {:error, :invalid_schedule_source}
  end

  test "an unavailable selected producer refuses instead of using the old calculator", c do
    result = RoutineCalendar.resolve(c.source, ~N[2026-07-13 12:00:00], c.zone)

    if Code.ensure_loaded?(Wotex.Routines.Civil) and
         function_exported?(ExBooking, :civil_occurrences, 3) do
      assert {:ok, [_]} = result
    else
      assert result == {:error, :routine_calendar_unavailable}
    end
  end
end
