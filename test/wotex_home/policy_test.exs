defmodule WotexHome.PolicyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.{Mutation, Policy}
  alias WotexHome.Policy.Context
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

  @request %{
    "api_version" => 1,
    "operation_id" => "request:1",
    "authority_epoch" => 4,
    "expected_revision" => 7,
    "target_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => true}
  }

  test "an ordinary light request passes only the pure checks" do
    {mutation, thing, context} = fixture()
    assert :ok = Policy.check(mutation, thing, context)
  end

  test "qualification and review permissions coexist with control but do not imply it" do
    {mutation, thing, context} = fixture()
    additional = ["read", "qualify:profile", "enroll:review", "rule:review"]

    assert :ok =
             Policy.check(mutation, thing, %{
               context
               | permissions: ["control:ordinary" | additional]
             })

    for permissions <- [["qualify:profile"], ["enroll:review"], ["rule:review"], additional] do
      assert {:error, :permission_denied} =
               Policy.check(mutation, thing, %{context | permissions: permissions})
    end

    for invalid <- [["control:ordinary", "control:ordinary"], ["read" | :invalid], ["admin"]] do
      assert {:error, :invalid_context} =
               Policy.check(mutation, thing, %{context | permissions: invalid})
    end
  end

  test "wrong ownership epoch and resource revision fail" do
    {mutation, thing, context} = fixture()

    assert {:error, :stale_authority_epoch} =
             Policy.check(%{mutation | authority_epoch: 3}, thing, context)

    assert {:error, :stale_resource_revision} =
             Policy.check(%{mutation | expected_revision: 6}, thing, context)
  end

  test "enrollment, profile and target scope are independent gates" do
    {mutation, thing, context} = fixture()

    assert {:error, :target_unavailable} =
             Policy.check(mutation, thing, %{context | enrollment_valid: false})

    assert {:error, :target_unavailable} =
             Policy.check(mutation, thing, %{context | profile_valid: false})

    assert {:error, :target_unavailable} =
             Policy.check(mutation, thing, %{context | allowed_targets: MapSet.new()})
  end

  test "missing permission and unknown safety facts deny" do
    {mutation, thing, context} = fixture()

    assert {:error, :permission_denied} =
             Policy.check(mutation, thing, %{context | permissions: []})

    assert {:error, :invariant_unresolved} =
             Policy.check(mutation, thing, %{context | invariants: :unknown})

    assert {:error, :invariant_unresolved} =
             Policy.check(mutation, thing, %{context | invariants: :deny})
  end

  test "read-only smoke cannot be written through an ordinary request" do
    {_, _, context} = fixture()

    assert {:ok, smoke_thing} =
             Thing.new(%{
               "id" => "smoke:hall",
               "role" => "SmokeDetector",
               "profile_ref" => "aqara.detector:1",
               "capabilities" => [@smoke]
             })

    assert {:ok, mutation} =
             Mutation.new(%{
               @request
               | "target_id" => "smoke:hall",
                 "capability_key" => "smoke_state",
                 "value" => %{"type" => "smoke_state", "state" => "clear"}
             })

    context = %{context | allowed_targets: MapSet.new(["smoke:hall"])}
    assert {:error, :read_only_capability} = Policy.check(mutation, smoke_thing, context)
  end

  test "a semantically wrong value cannot pass a capability" do
    {mutation, thing, context} = fixture()

    assert {:error, :invalid_value} =
             Policy.check(
               %{mutation | value: %{"type" => "fraction", "ppm" => 0}},
               thing,
               context
             )
  end

  defp fixture do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, mutation} = Mutation.new(@request)

    context = %Context{
      principal_id: "operator:1",
      permissions: ["control:ordinary"],
      allowed_targets: MapSet.new(["light:desk"]),
      authority_epoch: 4,
      resource_revision: 7,
      enrollment_valid: true,
      profile_valid: true,
      invariants: :allow
    }

    {mutation, thing, context}
  end
end
