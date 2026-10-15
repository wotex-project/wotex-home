defmodule WotexHome.CalendarProducerAbsenceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Schedules.{Recurrence, Tzif}

  test "production calendar calculation refuses absent producers while interval arithmetic remains available" do
    refute Code.ensure_loaded?(Wotex.Routines.Civil)

    record =
      JSON.decode!(File.read!("test/fixtures/schedules/timezone_vectors.json"))["zones"] |> hd()

    {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
    {:ok, [due]} = Tzif.resolve(zone, ~N[2026-07-13 12:00:00])

    source = %{
      "id" => "schedule:absence",
      "source_revision" => 1,
      "author_id" => "operator:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => String.duplicate("a", 64),
      "target_id" => "light:one",
      "resource_revision" => 1,
      "late_window_ms" => 10000,
      "uncertainty_tolerance_ms" => 100,
      "trigger" => ["once", zone.name, zone.digest, "2026-07-13", "12:00:00", due]
    }

    assert Recurrence.next(source, due - 1, zone) == {:error, :routine_calendar_unavailable}
    assert Recurrence.validate_source(source, zone) == {:error, :routine_calendar_unavailable}
    assert Recurrence.coordinate(source, due, zone) == {:error, :routine_calendar_unavailable}
    interval = %{source | "trigger" => ["interval", 100_000, 60000, 0, nil]}
    assert Recurrence.next(interval, 99999) == {:ok, 100_000}
    assert Recurrence.coordinate(interval, 100_000) == :ok
  end
end
