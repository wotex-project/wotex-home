defmodule WotexHome.MatterExportShapeTest do
  use ExUnit.Case, async: true

  alias WotexHome.Matter.ExportShape
  alias WotexHome.Semantics.{Observation, Thing}

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

  test "only an exact ordinary Boolean Light power shape receives a pending proposal" do
    {:ok, thing} = Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [@power]
    })

    assert {:ok, proposal} = ExportShape.proposal(thing)
    assert proposal.scope == :shape_only
    assert proposal.device_type_id == 0x0100
    assert proposal.device_type_revision == 3
    assert proposal.required_server_clusters == [0x0003, 0x0004, 0x0006, 0x0062]
    assert proposal.omitted_home_capabilities == []

    {:ok, read_only} = Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [%{@power | "operations" => ["read"]}]
    })

    assert {:error, :unsupported_export_shape} = ExportShape.proposal(read_only)

    {:ok, extended} = Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [%{@power | "extensions" => %{"lifx:mode" => "legacy"}}]
    })

    assert {:error, :unsupported_export_shape} = ExportShape.proposal(extended)
  end

  test "additional Home capabilities are disclosed as omitted, not mapped implicitly" do
    brightness = %{
      @power
      | "key" => "brightness",
        "value_kind" => "fraction",
        "unit" => "ppm",
        "evidence_ref" => "fixture:brightness:1"
    }

    {:ok, thing} = Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [@power, brightness]
    })

    assert {:ok, %{omitted_home_capabilities: ["brightness"]}} =
             ExportShape.proposal(thing)
  end

  test "smoke detector and malformed declarations cannot be relabelled as a light" do
    smoke = %{
      @power
      | "thing_id" => "smoke:hall",
        "role" => "SmokeDetector",
        "key" => "smoke_state",
        "value_kind" => "smoke_state",
        "operations" => ["read"],
        "risk_class" => "sensitive"
    }

    {:ok, thing} = Thing.new(%{
      "id" => "smoke:hall",
      "role" => "SmokeDetector",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [smoke]
    })

    assert {:error, :unsupported_export_shape} = ExportShape.proposal(thing)
    assert {:error, :unsupported_export_shape} = ExportShape.proposal(%{thing | role: "Light"})
  end

  test "absolute On and Off build typed unadmitted mutations; Toggle does not" do
    {:ok, thing} = Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [@power]
    })

    assert {:ok, %{scope: :unadmitted, mutation: off}} =
             ExportShape.command_proposal(thing, 0x00, "matter:op:1", 3, 7)

    assert off.target_id == "light:desk"
    assert off.capability_key == "power"
    assert off.value == %{"type" => "boolean", "value" => false}
    assert off.authority_epoch == 3
    assert off.expected_revision == 7

    assert {:ok, %{scope: :unadmitted, mutation: on}} =
             ExportShape.command_proposal(thing, 0x01, "matter:op:2", 3, 7)

    assert on.value == %{"type" => "boolean", "value" => true}
    assert {:error, :unsupported_matter_command} =
             ExportShape.command_proposal(thing, 0x02, "matter:op:3", 3, 7)

    assert {:error, :unsupported_matter_command} =
             ExportShape.command_proposal(thing, 0x40, "matter:op:4", 3, 7)

    assert {:error, :unsupported_matter_command} =
             ExportShape.command_proposal(thing, 0x01, "bad id", 3, 7)
  end

  test "only a current production report projects a Boolean attribute" do
    {:ok, thing} = Thing.new(%{
      "id" => "light:desk",
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [@power]
    })

    power = thing.capabilities["power"]
    report = %{
      "thing_id" => thing.id,
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => false},
      "quality" => "reported",
      "trust" => "unauthenticated_local",
      "source_epoch" => "device:1",
      "source_sequence" => 1,
      "boot_epoch" => "boot:1",
      "source_time_utc_ms" => nil,
      "received_time_utc_ms" => 1_000,
      "received_monotonic_ms" => 100
    }

    {:ok, observation} = Observation.new(report, power)
    assert {:ok, %{scope: :shape_only, on_off: false}} =
             ExportShape.report_proposal(thing, observation, "boot:1", 101)

    assert :unknown = ExportShape.report_proposal(thing, observation, "boot:1", 5_101)
    assert :unknown = ExportShape.report_proposal(thing, observation, "boot:2", 101)
    assert :unknown = ExportShape.report_proposal(thing, nil, "boot:1", 101)

    {:ok, synthetic} =
      Observation.new(%{report | "trust" => "synthetic_lab"}, power)

    assert :unknown = ExportShape.report_proposal(thing, synthetic, "boot:1", 101)

    {:ok, unknown} =
      Observation.new(%{report | "quality" => "unknown", "value" => nil}, power)

    assert :unknown = ExportShape.report_proposal(thing, unknown, "boot:1", 101)
  end
end
