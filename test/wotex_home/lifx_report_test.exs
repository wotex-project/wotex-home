defmodule WotexHome.LifxReportTest do
  use ExUnit.Case, async: true

  alias WotexHome.Lifx.Report
  alias WotexHome.Semantics.Thing

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
    "extensions" => %{}
  }

  @metadata %{
    "source_epoch" => "lifx:session:1",
    "source_sequence" => 42,
    "boot_epoch" => "host:boot:1",
    "received_time_utc_ms" => 1_700_000_000_000,
    "received_monotonic_ms" => 1_234
  }

  @state %{
    kind: :light_state,
    hue: 65_535,
    saturation: 32_768,
    brightness: 65_535,
    kelvin: 3_500,
    power_on?: true,
    raw_power: 65_535,
    label: "Desk"
  }

  test "qualified light state yields exact bounded Home values" do
    thing =
      thing([
        @power,
        capability("brightness", "fraction", "ppm"),
        capability("colour_hsv", "hsv", "mdeg+ppm"),
        capability("colour_temperature", "kelvin", "K", %{"min" => 2_500, "max" => 9_000})
      ])

    assert {:ok, reports} = Report.from_response(thing, @state, @metadata)

    assert Enum.map(reports, & &1.capability_key) ==
             ["power", "brightness", "colour_hsv", "colour_temperature"]

    assert Enum.map(reports, & &1.value.data) ==
             [true, 1_000_000, {359_994, 500_008}, 3_500]

    assert Enum.all?(reports, &(&1.trust == "unauthenticated_local"))
    assert Enum.all?(reports, &(&1.source_time_utc_ms == nil))
    assert Enum.all?(reports, &(&1.source_sequence == 42))
  end

  test "undeclared fields are omitted and malformed state never becomes an observation" do
    thing = thing([@power])
    assert {:ok, [power]} = Report.from_response(thing, @state, @metadata)
    assert power.capability_key == "power"

    assert {:error, :invalid_lifx_report} =
             Report.from_response(thing, %{@state | power_on?: false}, @metadata)

    assert {:error, :invalid_lifx_report} =
             Report.from_response(thing, Map.put(@state, :unexpected, 1), @metadata)

    assert {:error, :invalid_lifx_report} =
             Report.from_response(thing, @state, %{@metadata | "source_sequence" => -1})
  end

  test "light power is a report, while declared temperature bounds fail closed" do
    thing = thing([@power])

    assert {:ok, [off]} =
             Report.from_response(
               thing,
               %{kind: :light_power, on?: false, raw_level: 0},
               @metadata
             )

    assert off.value.data == false

    qualified =
      thing([
        @power,
        capability("colour_temperature", "kelvin", "K", %{"min" => 2_500, "max" => 9_000})
      ])

    assert {:error, :invalid_lifx_report} =
             Report.from_response(qualified, %{@state | kelvin: 1_500}, @metadata)
  end

  defp thing(capabilities) do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => capabilities
             })

    thing
  end

  defp capability(key, kind, unit, constraints \\ %{}) do
    %{
      @power
      | "key" => key,
        "value_kind" => kind,
        "unit" => unit,
        "evidence_ref" => "fixture:#{key}:1",
        "constraints" => constraints
    }
  end
end
