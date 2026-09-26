defmodule WotexHome.SemanticsTest do
  use ExUnit.Case, async: true

  alias WotexHome.Semantics.{Capability, Observation, Thing, Value}

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{"lifx:product" => "old-eu"}
  }

  @smoke %{
    "thing_id" => "smoke:hall",
    "role" => "SmokeDetector",
    "key" => "smoke_state",
    "value_kind" => "smoke_state",
    "unit" => "none",
    "operations" => ["read"],
    "risk_class" => "sensitive",
    "profile_ref" => "aqara.detector:1",
    "evidence_ref" => "fixture:smoke:1",
    "freshness_ms" => 60_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @report %{
    "thing_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => false},
    "quality" => "reported",
    "trust" => "unauthenticated_local",
    "source_epoch" => "device:1",
    "source_sequence" => 7,
    "boot_epoch" => "boot:1",
    "source_time_utc_ms" => nil,
    "received_time_utc_ms" => 1_000_000,
    "received_monotonic_ms" => 100
  }

  test "integer fractions and tagged colour have exact limits" do
    assert {:ok, %Value{data: 0}} = Value.new(%{"type" => "fraction", "ppm" => 0})
    assert {:ok, %Value{data: 1_000_000}} = Value.new(%{"type" => "fraction", "ppm" => 1_000_000})
    assert {:error, :invalid_value} = Value.new(%{"type" => "fraction", "ppm" => 1.0})
    assert {:error, :invalid_value} = Value.new(%{"type" => "fraction", "ppm" => 1_000_001})
    assert {:ok, _} = Value.new(%{"type" => "hsv", "hue_mdeg" => 359_999, "saturation_ppm" => 0})

    assert {:error, :invalid_value} =
             Value.new(%{"type" => "hsv", "hue_mdeg" => 360_000, "saturation_ppm" => 0})

    assert {:error, :invalid_value} =
             Value.new(%{"type" => "xy", "x_ppm" => 700_000, "y_ppm" => 400_000})

    assert {:error, :invalid_value} =
             Value.new(%{"type" => "boolean", "value" => false, "extra" => true})
  end

  test "capability schema does not promote an extension or an unsupported write" do
    assert {:ok, power} = Capability.new(@power)
    assert Capability.supports?(power, "write")
    assert power.extensions["lifx:product"] == "old-eu"

    assert {:error, :unsupported_capability} =
             Capability.new(%{@power | "key" => "lifx:raw_packet"})

    assert {:error, :invalid_extensions} =
             Capability.new(%{@power | "extensions" => %{"power" => "true"}})

    assert {:error, :invalid_operations} =
             Capability.new(%{@smoke | "operations" => ["read", "write"]})

    assert {:error, :unsupported_capability} =
             Capability.new(%{@smoke | "risk_class" => "ordinary"})

    assert {:ok, smoke} = Capability.new(@smoke)
    refute Capability.supports?(smoke, "write")
  end

  test "Kelvin profile bounds are checked against an exact value" do
    raw = %{
      @power
      | "key" => "colour_temperature",
        "value_kind" => "kelvin",
        "unit" => "K",
        "constraints" => %{"min" => 2_000, "max" => 6_500}
    }

    assert {:ok, capability} = Capability.new(raw)
    assert {:ok, at_limit} = Value.new(%{"type" => "kelvin", "kelvin" => 6_500})
    assert {:ok, over_limit} = Value.new(%{"type" => "kelvin", "kelvin" => 6_501})
    assert Capability.accepts?(capability, at_limit)
    refute Capability.accepts?(capability, over_limit)
  end

  test "Thing identity cannot merge mismatched or duplicate capabilities" do
    light = %{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [@power]
    }

    assert {:ok, thing} = Thing.new(light)
    assert {:ok, _} = Thing.capability(thing, "power")
    assert :error = Thing.capability(thing, "brightness")

    assert {:error, :invalid_capabilities} =
             Thing.new(%{light | "capabilities" => [@power, @power]})

    assert {:error, :invalid_capabilities} =
             Thing.new(%{light | "capabilities" => [%{@power | "thing_id" => "light:other"}]})
  end

  test "a reported false is distinct from missing, stale and wrong-boot state" do
    assert {:ok, power} = Capability.new(@power)
    assert {:ok, report} = Observation.new(@report, power)
    assert {:ok, %Value{data: false}} = Observation.current_value(report, power, "boot:1", 5_100)
    assert :unknown = Observation.current_value(report, power, "boot:1", 5_101)
    assert :unknown = Observation.current_value(report, power, "boot:2", 101)
    assert :unknown = Observation.current_value(report, power, "boot:1", 99)

    assert {:ok, unknown} =
             Observation.new(%{@report | "quality" => "unknown", "value" => nil}, power)

    assert :unknown = Observation.current_value(unknown, power, "boot:1", 101)
    assert {:error, :invalid_value} = Observation.new(%{@report | "quality" => "unknown"}, power)
  end

  test "a smoke report cannot be treated as an ordinary light or synthetic authority" do
    assert {:ok, smoke} = Capability.new(@smoke)
    assert {:error, :invalid_identity} = Observation.new(@report, smoke)

    report = %{
      @report
      | "thing_id" => "smoke:hall",
        "capability_key" => "smoke_state",
        "value" => %{"type" => "smoke_state", "state" => "alarm"},
        "trust" => "synthetic_lab"
    }

    assert {:ok, %Observation{trust: "synthetic_lab"}} = Observation.new(report, smoke)
    assert {:ok, synthetic} = Observation.new(report, smoke)
    assert :unknown = Observation.current_value(synthetic, smoke, "boot:1", 101)

    assert {:ok, %Value{data: "alarm"}} =
             Observation.current_value(synthetic, smoke, "boot:1", 101, :lab)

    assert {:error, :invalid_value} =
             Observation.new(
               %{report | "value" => %{"type" => "boolean", "value" => true}},
               smoke
             )
  end
end
