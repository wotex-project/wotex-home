defmodule WotexHome.LifxColorPlanTest do
  use ExUnit.Case, async: true

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Lifx.{ColorPlan, ColorSession, Ledger, Packet, Report}
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

    refute ColorPlan.no_effect?(brightness)

    assert {:ok, matching} =
             ColorPlan.new(
               thing,
               mutation("brightness", %{"type" => "fraction", "ppm" => 500_000}),
               reports,
               "host:boot:1",
               1_100
             )

    assert ColorPlan.no_effect?(matching)

    assert brightness.baseline ==
             {"lifx:session:1", 42, "host:boot:1", 1_700_000_000_000, 1_000}

    assert :ok =
             ColorPlan.recheck(
               brightness,
               thing,
               mutation("brightness", %{"type" => "fraction", "ppm" => 750_000}),
               reports,
               "host:boot:1",
               1_200
             )

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

    refute ColorPlan.no_effect?(plan)

    assert {:ok, same_kelvin} =
             ColorPlan.new(
               thing,
               mutation("colour_temperature", %{"type" => "kelvin", "kelvin" => 3_500}),
               reports(thing),
               "host:boot:1",
               1_100
             )

    refute ColorPlan.no_effect?(same_kelvin)
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

  test "dispatch recheck binds exact baseline event and Thing declaration" do
    thing = thing()
    request = mutation("brightness", %{"type" => "fraction", "ppm" => 750_000})
    current = reports(thing)
    assert {:ok, plan} = ColorPlan.new(thing, request, current, "host:boot:1", 1_100)

    newer = Map.new(current, fn {key, report} -> {key, %{report | source_sequence: 43}} end)

    assert {:error, :color_plan_stale} =
             ColorPlan.recheck(plan, thing, request, newer, "host:boot:1", 1_200)

    changed = %{
      thing
      | capabilities: Map.update!(thing.capabilities, "brightness", &%{&1 | freshness_ms: 10_000})
    }

    assert {:error, :color_plan_stale} =
             ColorPlan.recheck(plan, changed, request, current, "host:boot:1", 1_200)

    assert {:error, :invalid_color_session} =
             ColorSession.new(candidate(), @target, changed, plan, 0)

    assert {:error, :color_plan_stale} =
             ColorPlan.recheck(plan, thing, request, current, "host:boot:1", 6_001)
  end

  test "colour ACK and independent raw HSBK readback stay separate" do
    thing = thing()

    assert {:ok, plan} =
             ColorPlan.new(
               thing,
               mutation("brightness", %{"type" => "fraction", "ppm" => 750_000}),
               reports(thing),
               "host:boot:1",
               1_100
             )

    assert {:ok, session} = ColorSession.new(candidate(), @target, thing, plan, 250)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:error, :set_not_issued} = ColorSession.issue_read(session, ledger, 1_100, 500)
    assert {:ok, bytes, session, ledger} = ColorSession.issue_set(session, ledger, 1_100, 500)
    assert {:ok, %Packet{type: 102} = set_packet} = Packet.decode(bytes)
    assert {:error, :set_already_issued} = ColorSession.issue_set(session, ledger, 1_101, 500)

    assert {:error, :endpoint_mismatch, ^ledger} =
             ColorSession.accept_ack(
               session,
               ledger,
               "192.168.1.11:56700",
               reply(set_packet, 45, <<>>),
               1_150
             )

    assert {:ok, acknowledged, ledger} =
             ColorSession.accept_ack(
               session,
               ledger,
               "192.168.1.10:56700",
               reply(set_packet, 45, <<>>),
               1_150
             )

    assert acknowledged.acknowledged?
    assert acknowledged.readback == nil

    assert {:ok, read_bytes, acknowledged, ledger} =
             ColorSession.issue_read(acknowledged, ledger, 1_200, 500)

    assert {:ok, %Packet{type: 101} = read_packet} = Packet.decode(read_bytes)

    assert {:error, :unmatched_response, ^ledger} =
             ColorSession.accept_read(
               acknowledged,
               ledger,
               "192.168.1.10:56700",
               reply(set_packet, 107, light_state(plan.raw_hsbk)),
               1_300,
               @metadata
             )

    assert {:ok, :reported_match, observations, completed, ledger} =
             ColorSession.accept_read(
               acknowledged,
               ledger,
               "192.168.1.10:56700",
               reply(read_packet, 107, light_state(plan.raw_hsbk)),
               1_300,
               @metadata
             )

    assert Enum.any?(observations, &(&1.capability_key == "brightness"))
    assert Enum.all?(observations, &(&1.trust == "unauthenticated_local"))
    assert completed.readback == :reported_match
    assert map_size(ledger.pending) == 0
  end

  test "colour readback mismatch and expired acknowledgement remain uncertain" do
    thing = thing()

    assert {:ok, plan} =
             ColorPlan.new(
               thing,
               mutation("colour_temperature", %{"type" => "kelvin", "kelvin" => 4_000}),
               reports(thing),
               "host:boot:1",
               1_100
             )

    assert {:ok, session} = ColorSession.new(candidate(), @target, thing, plan, 0)
    assert {:ok, ledger} = Ledger.new(2)
    assert {:ok, bytes, session, ledger} = ColorSession.issue_set(session, ledger, 1_100, 100)
    assert {:ok, set_packet} = Packet.decode(bytes)

    assert {:ok, read_bytes, session, ledger} =
             ColorSession.issue_read(session, ledger, 1_150, 100)

    assert {:ok, read_packet} = Packet.decode(read_bytes)

    assert {:error, :expired, ledger} =
             ColorSession.accept_ack(
               session,
               ledger,
               "192.168.1.10:56700",
               reply(set_packet, 45, <<>>),
               1_201
             )

    changed = %{plan.raw_hsbk | brightness: 1}

    assert {:ok, :reported_mismatch, _reports, completed, _ledger} =
             ColorSession.accept_read(
               session,
               ledger,
               "192.168.1.10:56700",
               reply(read_packet, 107, light_state(changed)),
               1_220,
               @metadata
             )

    refute completed.acknowledged?
    assert completed.readback == :reported_mismatch
  end

  test "invalid colour plan cannot form a write session" do
    thing = thing()

    assert {:ok, plan} =
             ColorPlan.new(
               thing,
               mutation("brightness", %{"type" => "fraction", "ppm" => 750_000}),
               reports(thing),
               "host:boot:1",
               1_100
             )

    assert {:error, :invalid_color_session} =
             ColorSession.new(candidate(), @target, thing, %{plan | raw_hsbk: %{hue: 1}}, 0)

    assert {:error, :invalid_color_session} =
             ColorSession.new(candidate(), @target, thing, plan, 60_001)
  end

  defp candidate do
    assert {:ok, candidate} =
             Candidate.new(%{
               "interface_id" => "en0",
               "transport" => "udp",
               "source_endpoint" => "192.168.1.10:56700",
               "receive_epoch" => "boot:1",
               "received_monotonic_ms" => 1_000,
               "raw_ref" => "lifx:d073d5001337:fixture",
               "claimed_identifiers" => %{"stable_id" => "lifx:d073d5001337"},
               "trust_class" => "untrusted_network"
             })

    candidate
  end

  defp light_state(%{hue: hue, saturation: saturation, brightness: brightness, kelvin: kelvin}) do
    label = "Desk" <> :binary.copy(<<0>>, 28)

    <<hue::little-16, saturation::little-16, brightness::little-16, kelvin::little-16, 0::16,
      65_535::little-16, label::binary-size(32), 0::64>>
  end

  defp reply(%Packet{source: source, target: target, sequence: sequence}, type, payload) do
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
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
