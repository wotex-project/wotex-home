defmodule WotexHome.ScheduleActivationClockTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{ActivationClock, ClockSample, Codec}

  test "independent boundary oracle excludes every UTC instant possibly before activation" do
    for tolerance <- [0, 1, 50, 1_000],
        lower <- [0, 1, 100_000],
        width <- [0, 1, 2, 100, 2_000, 2_001] do
      snapshot = snapshot(lower, lower + width)
      source = source(["interval", 0, 60_000, 0, nil], tolerance)

      if width <= 2 * tolerance do
        assert {:ok, watermark} = ActivationClock.initial(source, snapshot)
        assert watermark == lower + width
        # This oracle uses interval membership, independently of Recurrence or Planner.
        for coordinate <- [max(0, lower - 1), lower, lower + width, lower + width + 1] do
          assert coordinate > watermark == coordinate > lower + width
        end

        assert {:ok, document} = ActivationClock.encode(snapshot, watermark)
        assert {:ok, ^snapshot, ^watermark} = ActivationClock.decode(document)
      else
        assert {:error, :clock_uncertain} = ActivationClock.initial(source, snapshot)
      end
    end
  end

  test "countdown binds original boot/generation, past start and strictly future due" do
    snapshot = snapshot(100_000, 100_020)

    for boot <- ["boot:one", "boot:other"],
        generation <- [1, 2],
        start <- [0, 999, 1_000, 1_001],
        duration <- [1_000, 2_000] do
      source = source(["countdown", boot, generation, start, duration], 100)
      result = ActivationClock.initial(source, snapshot)

      cond do
        boot != "boot:one" -> assert result == {:error, :old_boot}
        generation != 1 -> assert result == {:error, :clock_changed}
        start > 1_000 -> assert result == {:error, :schedule_basis_changed}
        start + duration <= 1_000 -> assert result == {:error, :schedule_elapsed}
        true -> assert result == {:ok, 1_000}
      end
    end
  end

  test "malformed, unqualified, widened or cross-scope retained clocks establish no correspondence" do
    original = snapshot(100_000, 100_100)
    {:ok, document} = ActivationClock.encode(original, 100_100)
    assert {:error, :invalid_schedule_activation_clock} = ActivationClock.decode(document <> " ")

    assert {:error, :invalid_schedule_activation_clock} =
             ActivationClock.decode(String.replace(document, "100000", "100000.0"))

    for changed <- [
          Map.put(original, :reason, :temporal_clock_unavailable),
          Map.put(original, :interval, {100_000, 100_101}),
          Map.put(original, :now_ms, 999),
          Map.update!(original, :scope, &Map.put(&1, "clock_generation", 2)),
          Map.update!(original, :scope, &Map.put(&1, "extra", false)),
          Map.put(original, :extra, false)
        ] do
      assert {:error, :invalid_schedule_activation_clock} =
               ActivationClock.encode(changed, 100_100)

      assert {:error, :temporal_clock_unavailable} =
               ActivationClock.initial(source(["interval", 0, 60_000, 0, nil], 100), changed)
    end

    unqualified = %{
      original.sample
      | "wall_confidence" => "unqualified",
        "utc_lower_ms" => nil,
        "utc_upper_ms" => nil,
        "qualification_digest" => nil,
        "monotonic_continuous" => false
    }

    assert {:ok, _} = ClockSample.encode(unqualified)

    assert {:error, :invalid_schedule_activation_clock} =
             ActivationClock.encode(%{original | sample: unqualified, interval: nil}, 1_000)
  end

  defp source(trigger, tolerance) do
    %{
      "id" => "schedule:one",
      "source_revision" => 1,
      "author_id" => "author:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => String.duplicate("a", 64),
      "target_id" => "light:one",
      "resource_revision" => 0,
      "late_window_ms" => 10_000,
      "uncertainty_tolerance_ms" => tolerance,
      "trigger" => trigger
    }
  end

  defp snapshot(lower, upper) do
    sample = %{
      "source_id" => "clock:synthetic",
      "qualification_digest" => String.duplicate("b", 64),
      "boot_epoch" => "boot:one",
      "generation" => 1,
      "sampled_monotonic_ms" => 1_000,
      "utc_lower_ms" => lower,
      "utc_upper_ms" => upper,
      "maximum_age_ms" => 10_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }

    scope = %{
      "deployment_id" => Codec.hash("synthetic deployment"),
      "owner_id" => Codec.hash("synthetic owner"),
      "authority_epoch" => 1,
      "store_boot_epoch" => "boot:one",
      "clock_generation" => 1,
      "runtime_digest" => Codec.hash("synthetic runtime")
    }

    %{scope: scope, sample: sample, now_ms: 1_000, interval: {lower, upper}, reason: nil}
  end
end
