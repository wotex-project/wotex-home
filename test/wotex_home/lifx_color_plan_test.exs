defmodule WotexHome.LifxColorPlanTest do
  use ExUnit.Case, async: true

  alias WotexHome.Lifx.{ColorPlan, Packet, Report}
  alias WotexHome.Mutation
  alias WotexHome.Semantics.Thing

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>
  @metadata %{
    "source_epoch" => "lifx:session:1",
    "source_sequence" => 42,
    "boot_epoch" => "host:boot:1",
    "received_time_utc_ms" => 1_700_000_000_000,
    "received_monotonic_ms" => 1_000
  }

  test "brightness and hue changes preserve fresh values from one LightState" do
    thing = thing()
    reports = reports(thing)

    assert {:ok, brightness} =
             ColorPlan.new(
               thing,
               mutation("brightness", %{"type" => "fraction", "ppm" => 750_000}),
               reports,
               "host:boot:1",
               1_100
             )

    assert brightness.raw_hsbk == %{
             hue: 21_845,
             saturation: 32_768,
             brightness: 49_151,
             kelvin: 3_500
           }

    assert brightness.baseline ==
             {"lifx:session:1", 42, "host:boot:1", 1_700_000_000_000, 1_000}

    assert {:ok, packet} = Packet.set_color(2, @target, 7, brightness.raw_hsbk, 250)
    assert {:ok, %Packet{type: 102}} = Packet.decode(packet)

    assert {:ok, colour} =
             ColorPlan.new(
               thing,
               mutation("colour_hsv", %{
                 "type" => "hsv",
                 "hue_mdeg" => 0,
                 "saturation_ppm" => 1_000_000
               }),
               reports,
               "host:boot:1",
               1_100
             )

    assert colour.raw_hsbk == %{
             hue: 0,
             saturation: 65_535,
             brightness: 32_768,
             kelvin: 3_500
           }
  end

  test "colour temperature selects white mode and keeps current brightness" do
    thing = thing()

    assert {:ok, plan} =
             ColorPlan.new(
               thing,
               mutation("colour_temperature", %{"type" => "kelvin", "kelvin" => 4_000}),
               reports(thing),
               "host:boot:1",
               1_100
             )

    assert plan.raw_hsbk == %{
             hue: 21_845,
             saturation: 0,
             brightness: 32_768,
             kelvin: 4_000
           }
  end

  test "stale, mixed, synthetic and out-of-range inputs cannot form a plan" do
    thing = thing()
    current = reports(thing)
    request = mutation("brightness", %{"type" => "fraction", "ppm" => 750_000})

    assert {:error, :color_plan_unavailable} =
             ColorPlan.new(thing, request, current, "host:boot:1", 6_001)

    assert {:error, :color_plan_unavailable} =
             ColorPlan.new(thing, request, current, "host:other", 1_100)

    mixed = Map.update!(current, "brightness", &%{&1 | source_sequence: 43})

    assert {:error, :color_plan_unavailable} =
             ColorPlan.new(thing, request, mixed, "host:boot:1", 1_100)

    synthetic = Map.update!(current, "brightness", &%{&1 | trust: "synthetic_lab"})

    assert {:error, :color_plan_unavailable} =
             ColorPlan.new(thing, request, synthetic, "host:boot:1", 1_100)

    assert {:error, :color_plan_unavailable} =
             ColorPlan.new(
               thing,
               mutation("colour_temperature", %{"type" => "kelvin", "kelvin" => 10_000}),
               current,
               "host:boot:1",
               1_100
             )
  end

  defp thing do
    common = %{
      "thing_id" => "light:desk",
      "role" => "Light",
      "operations" => ["read", "write"],
      "risk_class" => "ordinary",
      "profile_ref" => "lifx.old:1",
      "freshness_ms" => 5_000,
      "extensions" => %{}
    }

    capabilities = [
      Map.merge(common, %{
        "key" => "power",
        "value_kind" => "boolean",
        "unit" => "none",
        "evidence_ref" => "fixture:power:1",
        "constraints" => %{}
      }),
      Map.merge(common, %{
        "key" => "brightness",
        "value_kind" => "fraction",
        "unit" => "ppm",
        "evidence_ref" => "fixture:brightness:1",
        "constraints" => %{}
      }),
      Map.merge(common, %{
        "key" => "colour_hsv",
        "value_kind" => "hsv",
        "unit" => "mdeg+ppm",
        "evidence_ref" => "fixture:colour:1",
        "constraints" => %{}
      }),
      Map.merge(common, %{
        "key" => "colour_temperature",
        "value_kind" => "kelvin",
        "unit" => "K",
        "evidence_ref" => "fixture:kelvin:1",
        "constraints" => %{"min" => 2_500, "max" => 9_000}
      })
    ]

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => capabilities
             })

    thing
  end

  defp reports(thing) do
    response = %{
      kind: :light_state,
      hue: 21_845,
      saturation: 32_768,
      brightness: 32_768,
      kelvin: 3_500,
      power_on?: true,
      raw_power: 65_535,
      label: "Desk"
    }

    assert {:ok, observations} = Report.from_response(thing, response, @metadata)

    observations
    |> Map.new(&{&1.capability_key, &1})
    |> Map.take(~w(colour_hsv brightness colour_temperature))
  end

  defp mutation(key, value) do
    assert {:ok, mutation} =
             Mutation.new(%{
               "api_version" => 1,
               "operation_id" => "op:colour:1",
               "authority_epoch" => 1,
               "expected_revision" => 0,
               "target_id" => "light:desk",
               "capability_key" => key,
               "value" => value
             })

    mutation
  end
end
