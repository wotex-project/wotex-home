defmodule WotexHome.SceneTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Semantics.{Scene, SceneReport, Thing}

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

  @member %{
    "target_id" => "light:desk",
    "profile_ref" => "lifx.old:1",
    "capability_key" => "power",
    "expected_revision" => 0,
    "value" => %{"type" => "boolean", "value" => false}
  }

  @scene %{
    "version" => 1,
    "id" => "scene:all-off",
    "revision" => 1,
    "members" => [@member, %{@member | "target_id" => "light:hall"}]
  }

  test "scene binds exact per-member Thing profiles and values" do
    things = things()
    assert {:ok, %Scene{} = scene} = Scene.new(@scene, things)
    assert Scene.target_ids(scene) == ["light:desk", "light:hall"]

    changed_profile = put_in(@scene, ["members", Access.at(1), "profile_ref"], "lifx.old:2")
    assert {:error, :unsupported_member} = Scene.new(changed_profile, things)

    unknown = put_in(@scene, ["members", Access.at(1), "target_id"], "light:unknown")
    assert {:error, :target_unavailable} = Scene.new(unknown, things)

    mismatched =
      put_in(@scene, ["members", Access.at(0), "value"], %{"type" => "fraction", "ppm" => 0})

    assert {:error, :unsupported_member} = Scene.new(mismatched, things)
  end

  test "coupled writes to one Thing and unknown fields are refused" do
    things = things()
    duplicate = put_in(@scene, ["members", Access.at(1), "target_id"], "light:desk")
    assert {:error, :invalid_scene} = Scene.new(duplicate, things)

    assert {:error, :invalid_fields} =
             Scene.new(Map.put(@scene, "atomic", true), things)
  end

  test "missing and partial members never claim an atomic all-off result" do
    assert {:ok, scene} = Scene.new(@scene, things())
    assert {:ok, empty} = SceneReport.new(scene, %{})
    assert empty.summary == :not_started
    assert empty.members["light:hall"] == :not_started

    assert {:ok, partial} = SceneReport.new(scene, %{"light:desk" => :reported_match})
    assert partial.summary == :partial_or_unknown
    assert partial.members["light:hall"] == :not_started

    assert {:ok, accepted} =
             SceneReport.new(scene, %{
               "light:desk" => :reported_match,
               "light:hall" => :protocol_accepted
             })

    assert accepted.summary == :partial_or_unknown

    assert {:ok, complete} =
             SceneReport.new(scene, %{
               "light:desk" => :reported_match,
               "light:hall" => :reported_match
             })

    assert complete.summary == :all_reported_match

    assert {:error, :invalid_member_outcome} =
             SceneReport.new(scene, %{"light:unknown" => :reported_match})
  end

  defp things do
    assert {:ok, desk} = thing("light:desk")
    assert {:ok, hall} = thing("light:hall")
    %{"light:desk" => desk, "light:hall" => hall}
  end

  defp thing(id) do
    Thing.new(%{
      "id" => id,
      "role" => "Light",
      "profile_ref" => "lifx.old:1",
      "capabilities" => [%{@power | "thing_id" => id}]
    })
  end
end
