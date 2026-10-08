defmodule WotexHome.ScheduleConsiderationTest do
  use ExUnit.Case, async: true
  alias WotexHome.Schedules.{ActivationClock, Codec, Consideration, Occurrence}

  test "independent interval oracle retains one candidate or one actually nonempty missed range" do
    activation = activation()
    artifact = %{source: source(), timezone: nil}

    for lower <- [99_999, 100_000, 100_001, 109_999, 110_000, 159_999, 160_000, 100_000_000],
        width <- [0, 1, 1_000, 2_001],
        previous <- [90_000, 100_000, 160_000] do
      cutoff = max(previous, lower - 10_000)
      due = next_tick(cutoff)
      coordinate = if due <= lower, do: ["utc", due]
      missed = next_tick(previous) <= cutoff

      assert {:ok, result} =
               Consideration.build(activation, artifact, snapshot(lower, width), previous)

      if coordinate || missed do
        assert result.previous_watermark == previous
        assert result.watermark == max(previous, lower)
        assert result.activation_revision == 6
        assert Consideration.valid?(result, activation, artifact)

        if coordinate do
          expected =
            if width <= 2_000 and lower + width < due + 10_000, do: "eligible", else: "uncertain"

          assert result.decision == expected
          assert {:ok, occurrence} = Occurrence.build(artifact.source, 1, 1, coordinate)
          assert {:ok, identity} = Occurrence.identity(occurrence)

          assert {result.occurrence_document, result.occurrence_id, result.causal_id} ==
                   {identity.document, identity.id, identity.root_id}

          assert result.reason ==
                   if(expected == "eligible",
                     do: "temporal_execution_unavailable",
                     else: "clock_uncertain"
                   )
        else
          assert result.decision == "idle"
          assert result.reason == "missed_range"
          assert result.occurrence_id == nil && result.causal_id == nil
        end
      else
        assert result == :idle
      end
    end
  end

  test "empty early polling retains no history and long downtime has a bounded single range" do
    activation = activation()
    artifact = %{source: source(), timezone: nil}

    for lower <- 90_001..99_999//251 do
      assert {:ok, :idle} = Consideration.build(activation, artifact, snapshot(lower, 0), 90_000)
    end

    assert {:ok, record} =
             Consideration.build(activation, artifact, snapshot(99_999_999, 0), 90_000)

    assert record.decision == "idle"
    assert [record.missed_lower, record.missed_upper] == [90_000, 99_989_999]
    assert record.occurrence_document == nil

    assert {:ok, :idle} =
             Consideration.build(activation, artifact, snapshot(99_999_999, 0), record.watermark)
  end

  test "UTC identity survives clock correction and fresh boot while owner/runtime scope cannot change" do
    activation = activation()
    artifact = %{source: source(), timezone: nil}
    original = snapshot(100_000, 0)
    assert {:ok, record} = Consideration.build(activation, artifact, original, 90_000)

    for {boot, generation} <- [{"boot:one", 2}, {"boot:other", 1}] do
      changed = %{
        original
        | scope:
            Map.merge(original.scope, %{
              "store_boot_epoch" => boot,
              "clock_generation" => generation
            }),
          sample: Map.merge(original.sample, %{"boot_epoch" => boot, "generation" => generation})
      }

      assert {:ok, same_occurrence} = Consideration.build(activation, artifact, changed, 90_000)
      assert same_occurrence.occurrence_id == record.occurrence_id
      assert {:ok, :idle} = Consideration.build(activation, artifact, changed, record.watermark)
    end

    for key <- ~w(deployment_id owner_id runtime_digest authority_epoch) do
      value = if key == "authority_epoch", do: 2, else: Codec.hash("changed")

      assert {:error, :schedule_basis_changed} =
               Consideration.build(
                 activation,
                 artifact,
                 %{original | scope: Map.put(original.scope, key, value)},
                 90_000
               )
    end
  end

  test "closed records require exact clock, source, decision, cursor, identity and missed range" do
    activation = activation()
    artifact = %{source: source(), timezone: nil}
    assert {:ok, record} = Consideration.build(activation, artifact, snapshot(100_001, 0), 90_000)

    for damaged <- [
          Map.put(record, :extra, nil),
          %{record | watermark: 100_002},
          %{record | previous_watermark: 99_999},
          %{record | decision: "idle"},
          %{record | reason: "clock_uncertain"},
          %{record | occurrence_id: "occ:" <> Codec.hash("other")},
          %{record | missed_upper: nil},
          %{record | clock_document: record.clock_document <> " "}
        ] do
      refute Consideration.valid?(damaged, activation, artifact)
    end
  end

  defp next_tick(after_ms) when after_ms < 100_000, do: 100_000
  defp next_tick(after_ms), do: 100_000 + (div(after_ms - 100_000, 60_000) + 1) * 60_000

  defp activation do
    {:ok, document} = ActivationClock.encode(snapshot(90_000, 0), 90_000)
    %{revision: 6, watermark: 90_000, clock_document: document, epoch: 1, generation: 1}
  end

  defp source,
    do: %{
      "id" => "schedule:one",
      "source_revision" => 1,
      "author_id" => "manager:one",
      "rule_id" => "rule:one",
      "rule_source_digest" => Codec.hash("rule"),
      "target_id" => "light:one",
      "resource_revision" => 0,
      "late_window_ms" => 10_000,
      "uncertainty_tolerance_ms" => 1_000,
      "trigger" => ["interval", 100_000, 60_000, 0, nil]
    }

  defp snapshot(lower, width) do
    scope = %{
      "deployment_id" => Codec.hash("deployment"),
      "owner_id" => Codec.hash("owner"),
      "authority_epoch" => 1,
      "store_boot_epoch" => "boot:one",
      "clock_generation" => 1,
      "runtime_digest" => Codec.hash("runtime")
    }

    sample = %{
      "source_id" => "clock:software-fixture",
      "qualification_digest" => Codec.hash("software-only"),
      "boot_epoch" => "boot:one",
      "generation" => 1,
      "sampled_monotonic_ms" => 1_000,
      "utc_lower_ms" => lower,
      "utc_upper_ms" => lower + width,
      "maximum_age_ms" => 10_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }

    %{scope: scope, sample: sample, now_ms: 1_000, interval: {lower, lower + width}, reason: nil}
  end
end
