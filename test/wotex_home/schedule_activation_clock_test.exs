defmodule WotexHome.ScheduleActivationClockTest do
  use ExUnit.Case, async: true
  alias WotexHome.Durable.Store.ClockContext
  alias WotexHome.Schedules.{ActivationClock, ClockSample, Codec}
  @monotonic_fixture Path.expand("../fixtures/schedules/countdown_clock_vectors.json", __DIR__)

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

  test "independent Python monotonic bytes and activation boundaries retain no UTC confidence" do
    fixture = JSON.decode!(File.read!(@monotonic_fixture))
    assert byte_size(File.read!(@monotonic_fixture)) <= 16_384

    assert Enum.sort(Map.keys(fixture)) ==
             ~w(cases clock_document clock_sha256 format now_ms sample_document scope scope_fields)

    assert fixture["format"] == "wotex-home.countdown-activation-vectors.v1"
    assert fixture["scope"] == "inert_monotonic_clock_correspondence"
    assert {:ok, sample} = ClockSample.decode(fixture["sample_document"])

    snapshot = %{
      scope: fixture["scope_fields"],
      sample: sample,
      now_ms: fixture["now_ms"],
      interval: nil,
      reason: :temporal_clock_unavailable
    }

    document = fixture["clock_document"]
    assert {:ok, ^document} = ActivationClock.encode(snapshot, 1_000)
    assert Codec.hash(document) == fixture["clock_sha256"]
    assert {:ok, ^snapshot, 1_000} = ActivationClock.decode(document)
    assert length(fixture["cases"]) == 32

    for vector <- fixture["cases"] do
      assert Enum.sort(Map.keys(vector)) == ~w(expected trigger)
      result = ActivationClock.initial(source(vector["trigger"], 100), snapshot)

      case vector["expected"] do
        ["ok", watermark] ->
          assert result == {:ok, watermark}

        ["error", reason] ->
          assert {:error, actual} = result
          assert Atom.to_string(actual) == reason
      end
    end

    for trigger <- [
          ["interval", 0, 60_000, 0, nil],
          [
            "once",
            "Europe/Stockholm",
            String.duplicate("a", 64),
            "2026-10-25",
            "02:30:00",
            1_792_886_600_000
          ],
          ["daily", "Europe/Stockholm", String.duplicate("a", 64), "08:00:00", 0, nil],
          ["weekdays", "Europe/Stockholm", String.duplicate("a", 64), "08:00:00", [1, 7], 0, nil]
        ] do
      assert {:error, :temporal_clock_unavailable} =
               ActivationClock.initial(source(trigger, 100), snapshot)
    end

    assert {:error, :clock_uncertain} = ClockSample.advance(sample, "boot:one", 1, 1_000)
  end

  test "monotonic coordinates retain signed-64 bounds independently of the UTC domain" do
    original = monotonic_snapshot()
    start = Codec.maximum() - 86_460_000
    source = source(["countdown", "boot:one", 1, start, 86_400_000], 0)

    snapshot = %{
      original
      | now_ms: start,
        sample: Map.put(original.sample, "sampled_monotonic_ms", start)
    }

    assert start > Codec.utc_maximum()
    assert {:ok, ^start} = ActivationClock.initial(source, snapshot)
    assert {:ok, document} = ActivationClock.encode(snapshot, start)
    assert {:ok, ^snapshot, ^start} = ActivationClock.decode(document)
    assert {:ok, ^start} = ClockSample.monotonic(snapshot.sample, "boot:one", 1, start)

    assert {:error, :invalid_schedule_activation_clock} =
             ActivationClock.encode(snapshot, Codec.maximum() + 1)
  end

  test "monotonic snapshot cannot alias the UTC format or acquire bounds from another record" do
    snapshot = monotonic_snapshot()
    assert {:ok, document} = ActivationClock.encode(snapshot, 1_000)
    assert {:ok, ^snapshot, 1_000} = ActivationClock.decode(document)

    utc = snapshot(100_000, 100_020)
    assert {:ok, utc_document} = ActivationClock.encode(utc, 100_020)

    for changed <- [
          document <> " ",
          String.replace(document, "monotonic-clock.v1", "clock.v1"),
          String.replace(utc_document, "activation-clock.v1", "activation-monotonic-clock.v1"),
          String.replace(document, "1000", "1000.0"),
          String.replace(document, "unqualified", "qualified"),
          String.replace(document, "null,null", "100000,100020"),
          String.replace(document, "clock:synthetic", "clock:synthetic\\u0020"),
          "[\"wotex-home.schedule-activation-monotonic-clock.v1\"]"
        ] do
      assert {:error, :invalid_schedule_activation_clock} = ActivationClock.decode(changed)
    end

    for changed <- [
          %{snapshot | interval: {0, 0}},
          %{snapshot | reason: nil},
          %{snapshot | now_ms: 999},
          %{snapshot | now_ms: 11_001},
          %{snapshot | sample: Map.put(snapshot.sample, "qualification_digest", nil)},
          %{snapshot | sample: Map.put(snapshot.sample, "monotonic_continuous", false)},
          %{snapshot | sample: Map.put(snapshot.sample, "boot_epoch", "boot:other")},
          %{snapshot | sample: Map.put(snapshot.sample, "generation", 2)},
          %{snapshot | scope: Map.put(snapshot.scope, "runtime_digest", "changed")},
          %{snapshot | scope: Map.put(snapshot.scope, "extra", nil)},
          Map.put(snapshot, :extra, nil)
        ] do
      assert {:error, :invalid_schedule_activation_clock} = ActivationClock.encode(changed, 1_000)

      assert {:error, :temporal_clock_unavailable} =
               ActivationClock.initial(
                 source(["countdown", "boot:one", 1, 1_000, 2_000], 0),
                 changed
               )
    end
  end

  test "countdown capture still requires the actual surrounding receipt samples and no timezone" do
    snapshot = monotonic_snapshot()
    source = source(["countdown", "boot:one", 1, 1_000, 2_000], 0)

    {:ok, context} =
      ClockContext.new(
        fn -> {"boot:one", 1_000} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, nil} end
      )

    assert {:ok, document, 1_000} = ActivationClock.capture(source, context)
    assert {:ok, ^snapshot, 1_000} = ActivationClock.decode(document)

    {:ok, outside} =
      ClockContext.new(
        fn -> {"boot:one", 999} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, nil} end
      )

    assert {:error, :temporal_clock_unavailable} = ActivationClock.capture(source, outside)

    assert {:error, :temporal_clock_unavailable} =
             ActivationClock.capture(source, fn -> {"boot:one", 1_000} end)

    {:ok, expanded} =
      ClockContext.new(
        fn -> {"boot:one", 1_000} end,
        fn -> {:ok, snapshot} end,
        fn _ -> {:ok, %{timezone: "invented"}} end
      )

    assert {:error, :timezone_basis_changed} = ActivationClock.capture(source, expanded)
  end

  test "monotonic sample validation preserves boot, generation, maximum age and discontinuity" do
    sample = monotonic_snapshot().sample

    for now <- [1_000, 1_001, 10_999, 11_000] do
      assert ClockSample.monotonic(sample, "boot:one", 1, now) == {:ok, now}
    end

    assert {:error, :clock_stale} = ClockSample.monotonic(sample, "boot:one", 1, 11_001)
    assert {:error, :clock_rollback} = ClockSample.monotonic(sample, "boot:one", 1, 999)
    assert {:error, :old_boot} = ClockSample.monotonic(sample, "boot:other", 1, 1_000)
    assert {:error, :clock_changed} = ClockSample.monotonic(sample, "boot:one", 2, 1_000)

    assert {:error, :clock_discontinuous} =
             ClockSample.monotonic(
               %{sample | "monotonic_continuous" => false, "qualification_digest" => nil},
               "boot:one",
               1,
               1_000
             )

    for {boot, generation, now} <- [
          {"", 1, 1_000},
          {"boot:one", 0, 1_000},
          {"boot:one", 1, 1_000.0},
          {"boot:one", 1, Codec.maximum() + 1}
        ] do
      assert {:error, :invalid_schedule_clock} =
               ClockSample.monotonic(sample, boot, generation, now)
    end

    assert {:error, :invalid_schedule_clock} =
             ClockSample.monotonic(Map.put(sample, "extra", true), "boot:one", 1, 1_000)
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

  defp monotonic_snapshot do
    original = snapshot(100_000, 100_020)

    %{
      original
      | sample: %{
          original.sample
          | "wall_confidence" => "unqualified",
            "utc_lower_ms" => nil,
            "utc_upper_ms" => nil
        },
        interval: nil,
        reason: :temporal_clock_unavailable
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
