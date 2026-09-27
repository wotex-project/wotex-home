defmodule WotexHome.LifxProfileBasisTest do
  use ExUnit.Case, async: true

  alias WotexHome.Discovery.{Candidate, Interview, Profile}
  alias WotexHome.Lifx.{DirectPowerSafety, ProductRegistry, ProfileBasis}
  alias WotexHome.Semantics.Thing

  @serial "lifx:d073d5000001"
  @candidate %{
    "interface_id" => "en0",
    "transport" => "udp",
    "source_endpoint" => "192.0.2.10:56700",
    "receive_epoch" => "scan:1",
    "received_monotonic_ms" => 100,
    "raw_ref" => "capture:1",
    "claimed_identifiers" => %{"stable_id" => @serial},
    "trust_class" => "untrusted_network"
  }
  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "lifx.vendor.1",
    "model" => "lifx.product.27",
    "firmware" => "2.80",
    "stable_id" => @serial
  }
  @profile %{
    "id" => "lifx.old-eu",
    "version" => "1.0.0",
    "transport" => "udp",
    "manufacturer" => "lifx.vendor.1",
    "model" => "lifx.product.27",
    "firmware_versions" => ["2.80"],
    "rank" => 10,
    "qualification_ref" => "cohort:old-eu:1"
  }
  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old-eu:1.0.0",
    "evidence_ref" => "cohort:old-eu:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }
  @selection %{
    "operator_id" => "owner:1",
    "candidate_ref" => "capture:1",
    "stable_id" => @serial,
    "profile_ref" => "lifx.old-eu:1.0.0",
    "qualification_ref" => "cohort:old-eu:1",
    "method" => "legacy_tofu",
    "review_ref" => "review:1"
  }

  test "exact LIFX identity, product and power declaration yield only pending mapping evidence" do
    {candidate, interview, profile, thing, registry} = fixtures()

    assert {:ok, basis} =
             ProfileBasis.assess(
               [candidate],
               interview,
               [profile],
               thing,
               @selection,
               registry
             )

    assert basis.status == :pending_physical_qualification
    assert basis.scope == :profile_mapping_only
    assert basis.product == {1, 27}
    assert basis.firmware == {2, 80}
    assert basis.registry_digest == registry.digest
    assert byte_size(basis.basis_digest) == 64
    assert DirectPowerSafety.decision(thing) == :allow

    assert {:ok, same} =
             ProfileBasis.assess(
               [candidate],
               interview,
               [profile],
               thing,
               @selection,
               registry
             )

    assert same == basis
  end

  test "unknown product and changed declaration cannot reuse the mapping basis" do
    {candidate, interview, profile, thing, registry} = fixtures()
    changed_interview = %{interview | model: "lifx.product.999"}
    changed_profile = %{profile | model: "lifx.product.999"}

    assert {:error, :unknown_product} =
             ProfileBasis.assess(
               [candidate],
               changed_interview,
               [changed_profile],
               thing,
               @selection,
               registry
             )

    changed_power = %{thing.capabilities["power"] | evidence_ref: "cohort:other"}
    changed_thing = %{thing | capabilities: %{"power" => changed_power}}

    assert {:error, :unsupported_lifx_declaration} =
             ProfileBasis.assess(
               [candidate],
               interview,
               [profile],
               changed_thing,
               @selection,
               registry
             )
  end

  test "static direct-power safety scope rejects extra declarations and extensions" do
    {candidate, interview, profile, thing, registry} = fixtures()
    power = thing.capabilities["power"]

    for changed_power <- [
          %{power | operations: ["read"]},
          %{power | extensions: %{"vendor:opaque" => "dynamic-policy"}}
        ] do
      changed_thing = %{thing | capabilities: %{"power" => changed_power}}
      assert DirectPowerSafety.decision(changed_thing) == :unknown

      assert {:error, :unsupported_lifx_declaration} =
               ProfileBasis.assess(
                 [candidate],
                 interview,
                 [profile],
                 changed_thing,
                 @selection,
                 registry
               )
    end
  end

  defp fixtures do
    {:ok, candidate} = Candidate.new(@candidate)
    {:ok, interview} = Interview.new(@interview, candidate)
    {:ok, profile} = Profile.new(@profile)

    {:ok, thing} =
      Thing.new(%{
        "id" => "light:desk",
        "role" => "Light",
        "profile_ref" => "lifx.old-eu:1.0.0",
        "capabilities" => [@power]
      })

    defaults = %{
      "hev" => false,
      "color" => false,
      "chain" => false,
      "matrix" => false,
      "relays" => false,
      "buttons" => false,
      "infrared" => false,
      "multizone" => false,
      "temperature_range" => nil,
      "extended_multizone" => false
    }

    bytes =
      JSON.encode!([
        %{
          "vid" => 1,
          "name" => "LIFX",
          "defaults" => defaults,
          "products" => [%{"pid" => 27, "name" => "Example", "features" => %{}, "upgrades" => []}]
        }
      ])

    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    {:ok, registry} = ProductRegistry.new(bytes, digest)
    {candidate, interview, profile, thing, registry}
  end
end
