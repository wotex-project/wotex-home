defmodule WotexHome.SchedulePlannerTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{Codec, Planner, Tzif}

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
    "trigger" => ["interval", 100_000, 60_000, 100_000, 500_000]
  }
  @fixture Path.expand("../fixtures/schedules/timezone_vectors.json", __DIR__)

  test "independent enumerated intervals cover cursor, width and half-open boundaries" do
    occurrences = [100_000, 160_000, 220_000, 280_000, 340_000, 400_000, 460_000]

    for watermark <- [-1, 99_999, 100_000, 159_999, 160_000, 170_000, 300_000],
        lower <- [99_999, 100_000, 159_999, 160_000, 160_001, 169_999, 170_000, 220_000, 499_999],
        width <- [0, 1, 199, 200, 201, 10_000] do
      upper = lower + width

      due =
        Enum.find(occurrences, fn instant ->
          instant > watermark and instant <= lower and instant + 10_000 > lower
        end)

      expected =
        cond do
          due == nil -> :idle
          width <= 200 and upper < due + 10_000 -> :eligible
          true -> :uncertain
        end

      assert {:ok, plan} = plan(@source, watermark, lower, upper)
      assert plan.decision == expected
      assert plan.coordinate == if(due == nil, do: nil, else: ["utc", due])
      assert plan.watermark == max(watermark, lower)

      if plan.missed_range do
        assert [^watermark, through] = plan.missed_range
        assert through > watermark && through + 10_000 <= lower
        assert Enum.all?(occurrences, &(&1 > through or &1 + 10_000 <= lower))
      end
    end
  end

  test "duplicate, backward and forward polling never reconsider consumed or uncertain work" do
    assert {:ok, first} = plan(@source, 99_999, 160_000, 160_000)
    assert first.coordinate == ["utc", 160_000] && first.decision == :eligible

    for time <- [160_000, 159_000, 169_999, 219_999] do
      assert {:ok, next} = plan(@source, first.watermark, time, time)
      assert next.coordinate == nil
      assert next.watermark >= first.watermark
    end

    assert {:ok, uncertain} = plan(@source, first.watermark, 220_000, 220_201)
    assert uncertain.coordinate == ["utc", 220_000] && uncertain.decision == :uncertain
    assert {:ok, %{coordinate: nil}} = plan(@source, uncertain.watermark, 220_001, 220_001)

    # An interval that straddles a future deadline never emits early.
    assert {:ok, before} = plan(@source, uncertain.watermark, 279_999, 280_001)
    assert before.coordinate == nil

    assert {:ok, %{coordinate: ["utc", 280_000]}} =
             plan(@source, before.watermark, 280_000, 280_000)
  end

  test "decades of missed work produce one bounded range and at most one current occurrence" do
    source = %{@source | "trigger" => ["interval", 100_000, 60_000, 100_000, nil]}
    due = 100_000 + 16_000_000 * 60_000
    assert {:ok, plan} = plan(source, 99_999, due + 2_000, due + 2_000)
    assert plan.coordinate == ["utc", due]
    assert plan.missed_range == [99_999, due - 8_000]
    assert plan.watermark == due + 2_000
    assert {:ok, %{coordinate: nil}} = plan(source, plan.watermark, due + 3_000, due + 3_000)

    assert {:ok, completed} = plan(@source, 99_999, due, due)
    assert completed.coordinate == nil && completed.decision == :idle
    assert completed.missed_range == [99_999, due - 10_000]
  end

  test "retained cursor survives a boot change while a countdown cannot" do
    sample = clock(160_000, 160_000)

    assert {:error, :old_boot} =
             Planner.plan(@source, 159_999, sample, "boot:two", 5, 1_000)

    assert {:error, :clock_changed} =
             Planner.plan(@source, 159_999, sample, "boot:one", 6, 1_000)

    assert {:error, :clock_uncertain} =
             Planner.plan(
               @source,
               159_999,
               %{
                 sample
                 | "wall_confidence" => "unqualified",
                   "utc_lower_ms" => nil,
                   "utc_upper_ms" => nil
               },
               "boot:one",
               5,
               1_000
             )

    assert {:ok, %{coordinate: nil}} =
             Planner.plan(
               @source,
               160_000,
               %{sample | "boot_epoch" => "boot:two"},
               "boot:two",
               5,
               1_000
             )

    countdown = %{@source | "trigger" => ["countdown", "boot:one", 5, 1_000, 2_000]}

    sample = %{
      sample
      | "wall_confidence" => "unqualified",
        "utc_lower_ms" => nil,
        "utc_upper_ms" => nil
    }

    assert {:ok, %{coordinate: nil}} =
             Planner.plan(countdown, 1_000, sample, "boot:one", 5, 2_999)

    assert {:ok, %{decision: :eligible, coordinate: ["countdown", "boot:one", 5, 3_000]}} =
             Planner.plan(countdown, 2_999, sample, "boot:one", 5, 3_000)

    assert {:ok, %{coordinate: nil}} =
             Planner.plan(countdown, 3_000, sample, "boot:one", 5, 3_001)

    assert {:ok, %{decision: :expired}} =
             Planner.plan(countdown, 2_999, sample, "boot:one", 5, 13_000)

    assert {:error, :old_boot} = Planner.plan(countdown, 2_999, sample, "boot:two", 5, 3_000)
  end

  test "independent calendar recurrence vectors select only the currently valid instant" do
    %{"zones" => records, "next_cases" => vectors} = @fixture |> File.read!() |> JSON.decode!()

    zones =
      Map.new(records, fn record ->
        {:ok, zone} = Tzif.decode(record["name"], Base.decode64!(record["data_base64"]))
        {zone.name, zone}
      end)

    for vector <- vectors, vector["next_ms"] != nil do
      zone = zones[vector["zone"]]

      trigger =
        if vector["days"] == Enum.to_list(1..7),
          do: [
            "daily",
            zone.name,
            zone.digest,
            vector["time"],
            vector["start_ms"],
            vector["end_ms"]
          ],
          else: [
            "weekdays",
            zone.name,
            zone.digest,
            vector["time"],
            vector["days"],
            vector["start_ms"],
            vector["end_ms"]
          ]

      source = %{@source | "trigger" => trigger}
      assert :ok = Planner.cadence(source, zone)
      due = vector["next_ms"]

      assert {:ok, %{coordinate: ["utc", ^due], decision: :eligible}} =
               plan(source, vector["after_ms"], due, due, zone)
    end
  end

  test "invalid cursors, altered timezone bytes and unsupported cadence refuse" do
    assert {:error, :invalid_schedule_cursor} = plan(@source, -2, 160_000, 160_000)
    assert {:error, :invalid_schedule_cursor} = plan(@source, true, 160_000, 160_000)

    assert {:error, :invalid_schedule_cursor} =
             plan(@source, Codec.utc_maximum(), 160_000, 160_000)

    header = fn types, chars ->
      <<"TZif2", 0::120, 0::96, 0::32, types::unsigned-big-32, chars::unsigned-big-32>>
    end

    bytes =
      header.(1, 4) <>
        <<0::signed-big-32, 0, 0, "STD", 0>> <>
        header.(2, 8) <>
        <<-43_171::signed-big-32, 0, 0, 43_171::signed-big-32, 0, 4, "STD", 0, "ALT", 0>> <>
        "\n\n"

    assert {:ok, zone} = Tzif.decode("Fixture/Wide", bytes)
    source = %{@source | "trigger" => ["daily", zone.name, zone.digest, "08:00:00", 0, nil]}
    assert {:error, :unsupported_temporal_cadence} = Planner.cadence(source, zone)
    assert {:error, :timezone_basis_mismatch} = Planner.cadence(source, %{zone | digest: @hash})
  end

  defp plan(source, watermark, lower, upper, zone \\ nil),
    do: Planner.plan(source, watermark, clock(lower, upper), "boot:one", 5, 1_000, zone)

  defp clock(lower, upper),
    do: %{
      "source_id" => "clock:fixture",
      "qualification_digest" => @hash,
      "boot_epoch" => "boot:one",
      "generation" => 5,
      "sampled_monotonic_ms" => 1_000,
      "utc_lower_ms" => lower,
      "utc_upper_ms" => upper,
      "maximum_age_ms" => 60_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }
end
