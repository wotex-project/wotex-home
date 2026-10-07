defmodule WotexHome.ScheduleRecordsTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{ClockSample, Codec, Occurrence, Window}

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
  @literal ~s(["wotex-home.schedule-source.v1","schedule:one",2,"operator:one","rule:one","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","light:one",4,10000,100,["interval",100000,60000,100000,null]])
  @digest "ec92e482425571ba79507e664c2cc69f76de0447783d3b0f48e91580a55f89b4"
  @occurrence_literal ~s(["wotex-home.schedule-occurrence.v1",7,"schedule:one",2,"ec92e482425571ba79507e664c2cc69f76de0447783d3b0f48e91580a55f89b4",3,["utc",160000]])
  @occurrence_digest "6ddfcc6cd340b1c266d3e7773ded229287c2b7f16778e7dfa826d35d260ad3cd"
  @sample %{
    "source_id" => "clock:fixture",
    "qualification_digest" => @hash,
    "boot_epoch" => "boot:one",
    "generation" => 5,
    "sampled_monotonic_ms" => 1_000,
    "utc_lower_ms" => 160_000,
    "utc_upper_ms" => 160_000,
    "maximum_age_ms" => 60_000,
    "drift_ppm" => 0,
    "wall_confidence" => "qualified",
    "monotonic_continuous" => true
  }

  test "independent Python literals bind complete source and deterministic root" do
    assert {:ok, @literal} = Codec.encode(@source)
    assert {:ok, @source} = Codec.decode(@literal)
    assert {:ok, @digest} = Codec.digest(@source)
    assert {:ok, occurrence} = Occurrence.build(@source, 7, 3, ["utc", 160_000])
    assert {:ok, @occurrence_literal} = Occurrence.encode(occurrence)
    assert {:ok, ^occurrence} = Occurrence.decode(@occurrence_literal)
    assert {:ok, identity} = Occurrence.identity(occurrence)
    assert identity.id == "occ:" <> @occurrence_digest
    assert identity.root_id == "cause:schedule:" <> @occurrence_digest
    assert identity.document == @occurrence_literal
    assert Occurrence.current?(occurrence, @source)
    refute Occurrence.current?(occurrence, %{@source | "author_id" => "operator:two"})
    refute Occurrence.current?(occurrence, %{@source | "source_revision" => 3})

    for field <- ~w(authority_epoch rule_generation) do
      assert {:ok, different} = Occurrence.identity(Map.update!(occurrence, field, &(&1 + 1)))
      refute different.id == identity.id
    end
  end

  test "every supported trigger has a closed distinct inert encoding" do
    triggers = [
      ["once", "Europe/Stockholm", @hash, "2026-10-25", "02:30:00", 1_792_886_600_000],
      ["daily", "Europe/Stockholm", @hash, "02:30:00", 0, nil],
      ["weekdays", "America/New_York", @hash, "08:00:00", [1, 3, 7], 0, 1_900_000_000_000],
      ["interval", 0, 2_678_400_000, 0, nil],
      ["countdown", "boot:one", 5, 0, 86_400_000]
    ]

    for trigger <- triggers do
      source = %{@source | "trigger" => trigger}
      assert {:ok, bytes} = Codec.encode(source)
      assert {:ok, ^source} = Codec.decode(bytes)
    end
  end

  test "bounds, units, selectors and author identities cannot be broadened" do
    bad_triggers = [
      ["interval", 0, 59_999, 0, nil],
      ["interval", 0, 2_678_400_001, 0, nil],
      ["interval", 0, 60_000, 1, 1],
      ["interval", 0, 60_000.0, 0, nil],
      ["countdown", "boot:one", 0, 0, 1_000],
      ["countdown", "boot:one", 1, 0, 999],
      ["countdown", "boot:one", 1, 0, 86_400_001],
      ["countdown", "boot:one", 1, Codec.maximum(), 1_000],
      ["daily", "../UTC", @hash, "08:00:00", 0, nil],
      ["daily", "/UTC", @hash, "08:00:00", 0, nil],
      ["daily", "Europe/Stockholm", @hash, "8:00:00", 0, nil],
      ["daily", "UTC", @hash, "23:59:60", 0, nil],
      ["daily", "UTC", @hash, "08:00:00.000", 0, nil],
      ["weekdays", "UTC", @hash, "08:00:00", [7, 1], 0, nil],
      ["weekdays", "UTC", @hash, "08:00:00", [1, 1], 0, nil],
      ["weekdays", "UTC", @hash, "08:00:00", [], 0, nil],
      ["weekdays", "UTC", @hash, "08:00:00", [0], 0, nil],
      ["once", "UTC", @hash, "2026-02-30", "08:00:00", 0],
      ["once", "UTC", @hash, "1969-12-31", "08:00:00", 0],
      ["once", "UTC", @hash, "2026-01-01", "08:00:00", true],
      ["cron", "* * * * *"],
      ["interval", 0, 60_000, 0, nil, "catch_up"]
    ]

    for trigger <- bad_triggers do
      assert {:error, :invalid_schedule_source} = Codec.encode(%{@source | "trigger" => trigger})
    end

    for {field, value} <- [
          {"author_id", "operator/one"},
          {"source_revision", true},
          {"resource_revision", -1},
          {"rule_source_digest", String.upcase(@hash)},
          {"late_window_ms", 999},
          {"late_window_ms", 60_001},
          {"uncertainty_tolerance_ms", 1_001},
          {"missed_policy", "catch_up"}
        ] do
      assert {:error, :invalid_schedule_source} = Codec.encode(Map.put(@source, field, value))
    end
  end

  test "allocation bounds and canonical bytes reject alternate interpretations" do
    for bytes <- [
          " " <> @literal,
          @literal <> "\n",
          @literal <> "[]",
          String.replace(@literal, ",2,", ",2.0,"),
          String.replace(@literal, ",2,", ",true,"),
          String.replace(@literal, ",2,", ",9223372036854775808,"),
          String.replace(@literal, "schedule:one", "schedule\\u003aone"),
          String.replace(@literal, "schedule:one", String.duplicate("a", 129)),
          String.replace(@literal, ",null]", ",{}]"),
          String.duplicate("[", 100) <> String.duplicate("]", 100),
          String.duplicate(" ", 4_097),
          "{}",
          "[]",
          <<255>>
        ] do
      assert {:error, :invalid_schedule_source} = Codec.decode(bytes)
    end

    assert {:error, :invalid_schedule_occurrence} = Occurrence.decode(@occurrence_literal <> "\n")
    assert {:error, :invalid_schedule_clock} = ClockSample.decode("[]")
    assert {:ok, bytes} = ClockSample.encode(@sample)
    assert {:ok, @sample} = ClockSample.decode(bytes)
    assert {:error, :invalid_schedule_clock} = ClockSample.decode(bytes <> "\n")

    assert {:error, :invalid_schedule_clock} =
             ClockSample.encode(Map.put(@sample, "client_time", 0))
  end

  test "clock age, drift and scope only widen uncertainty conservatively" do
    sample = %{@sample | "utc_lower_ms" => 159_990, "utc_upper_ms" => 160_010, "drift_ppm" => 1}
    assert {:ok, {159_990, 160_010}} = ClockSample.advance(sample, "boot:one", 5, 1_000)
    assert {:ok, {159_990, 160_012}} = ClockSample.advance(sample, "boot:one", 5, 1_001)
    assert {:ok, {219_989, 220_011}} = ClockSample.advance(sample, "boot:one", 5, 61_000)
    assert {:error, :clock_stale} = ClockSample.advance(sample, "boot:one", 5, 61_001)
    assert {:error, :clock_rollback} = ClockSample.advance(sample, "boot:one", 5, 999)
    assert {:error, :old_boot} = ClockSample.advance(sample, "boot:two", 5, 1_000)
    assert {:error, :clock_changed} = ClockSample.advance(sample, "boot:one", 6, 1_000)

    assert {:error, :clock_discontinuous} =
             ClockSample.advance(
               %{sample | "monotonic_continuous" => false},
               "boot:one",
               5,
               1_000
             )

    assert {:error, :invalid_schedule_clock} =
             ClockSample.encode(%{sample | "qualification_digest" => nil})

    assert {:error, :invalid_schedule_clock} = ClockSample.encode(%{sample | "utc_upper_ms" => 0})
  end

  test "independent half-open interval oracle exhausts boundary and tolerance cases" do
    assert {:ok, occurrence} = Occurrence.build(@source, 7, 3, ["utc", 160_000])

    for lower <- [159_999, 160_000, 160_001, 169_998, 169_999, 170_000, 170_001],
        width <- [0, 1, 199, 200, 201] do
      upper = lower + width

      expected =
        cond do
          width > 200 -> :uncertain
          upper < 160_000 -> :early
          lower >= 170_000 -> :expired
          lower >= 160_000 and upper <= 169_999 -> :eligible
          true -> :uncertain
        end

      sample = %{@sample | "utc_lower_ms" => lower, "utc_upper_ms" => upper}
      assert {:ok, ^expected} = Window.check(@source, occurrence, sample, "boot:one", 5, 1_000)
    end

    assert {:ok, :eligible} = Window.check(@source, occurrence, @sample, "boot:one", 5, 10_999)
    assert {:ok, :expired} = Window.check(@source, occurrence, @sample, "boot:one", 5, 11_000)

    assert {:error, :clock_changed} =
             Window.check(@source, occurrence, @sample, "boot:one", 6, 1_000)

    assert {:error, :schedule_occurrence_mismatch} =
             Window.check(
               %{@source | "source_revision" => 3},
               occurrence,
               @sample,
               "boot:one",
               5,
               1_000
             )
  end

  test "UTC coordinates must actually belong to their interval or resolved one-shot" do
    for due <- [99_999, 100_001, 159_999, 160_001] do
      assert {:ok, occurrence} = Occurrence.build(@source, 7, 3, ["utc", due])

      assert {:error, :schedule_coordinate_mismatch} =
               Window.check(@source, occurrence, @sample, "boot:one", 5, 1_000)
    end

    finished = %{@source | "trigger" => ["interval", 100_000, 60_000, 100_000, 160_000]}
    assert {:ok, occurrence} = Occurrence.build(finished, 7, 3, ["utc", 160_000])

    assert {:error, :schedule_coordinate_mismatch} =
             Window.check(finished, occurrence, @sample, "boot:one", 5, 1_000)

    once = %{@source | "trigger" => ["once", "UTC", @hash, "1970-01-01", "00:02:40", 160_000]}
    assert {:ok, occurrence} = Occurrence.build(once, 7, 3, ["utc", 160_000])
    assert {:ok, :eligible} = Window.check(once, occurrence, @sample, "boot:one", 5, 1_000)
    daily = %{@source | "trigger" => ["daily", "UTC", @hash, "00:02:40", 0, nil]}
    assert {:ok, occurrence} = Occurrence.build(daily, 7, 3, ["utc", 160_000])

    assert {:error, :timezone_basis_required} =
             Window.check(daily, occurrence, @sample, "boot:one", 5, 1_000)
  end

  test "countdown uses only its original qualified continuous boot and expires on generation change" do
    source = %{@source | "trigger" => ["countdown", "boot:one", 5, 1_000, 2_000]}
    assert {:ok, occurrence} = Occurrence.build(source, 7, 3, ["countdown", "boot:one", 5, 3_000])

    sample = %{
      @sample
      | "wall_confidence" => "unqualified",
        "utc_lower_ms" => nil,
        "utc_upper_ms" => nil
    }

    assert {:ok, _} = ClockSample.encode(sample)
    assert {:error, :clock_uncertain} = ClockSample.advance(sample, "boot:one", 5, 3_000)
    assert {:ok, :early} = Window.check(source, occurrence, sample, "boot:one", 5, 2_999)
    assert {:ok, :eligible} = Window.check(source, occurrence, sample, "boot:one", 5, 3_000)
    assert {:ok, :eligible} = Window.check(source, occurrence, sample, "boot:one", 5, 12_999)
    assert {:ok, :expired} = Window.check(source, occurrence, sample, "boot:one", 5, 13_000)
    assert {:error, :old_boot} = Window.check(source, occurrence, sample, "boot:two", 5, 3_000)

    assert {:error, :clock_changed} =
             Window.check(source, occurrence, sample, "boot:one", 6, 3_000)

    assert {:error, :clock_discontinuous} =
             Window.check(
               source,
               occurrence,
               %{sample | "monotonic_continuous" => false, "qualification_digest" => nil},
               "boot:one",
               5,
               3_000
             )

    assert {:ok, wrong} = Occurrence.build(source, 7, 3, ["countdown", "boot:one", 5, 3_001])

    assert {:error, :schedule_coordinate_mismatch} =
             Window.check(source, wrong, sample, "boot:one", 5, 3_000)
  end
end
