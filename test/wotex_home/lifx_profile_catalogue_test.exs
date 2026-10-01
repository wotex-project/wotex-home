defmodule WotexHome.LifxProfileCatalogueTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Discovery.{Candidate, Interview}
  alias WotexHome.Lifx.ProfileCatalogue

  test "a closed packaged profile derives the complete Thing declaration" do
    assert {:ok, package} =
             ProfileCatalogue.fetch("lifx.product-27:1.0.0", "light:bedroom")

    assert package.profile.id == "lifx.product-27"
    assert package.profile.version == "1.0.0"
    assert package.profile.manufacturer == "lifx.vendor.1"
    assert package.profile.model == "lifx.product.27"
    assert package.profile.firmware_versions == ["3.60"]
    assert package.profile.qualification_ref == "qualification:pending:lifx:1:27:3.60"

    assert package.thing.id == "light:bedroom"
    assert package.thing.profile_ref == "lifx.product-27:1.0.0"
    assert Map.keys(package.thing.capabilities) == ["power"]

    power = package.thing.capabilities["power"]
    assert power.thing_id == "light:bedroom"
    assert power.operations == ["read", "write"]
    assert power.evidence_ref == package.profile.qualification_ref
    assert byte_size(package.catalogue_digest) == 64
    assert package.catalogue_digest == ProfileCatalogue.digest()
  end

  test "callers cannot introduce profiles, declarations or invalid Home identities" do
    assert {:error, :unsupported_profile} =
             ProfileCatalogue.fetch("lifx.caller-authored:1", "light:bedroom")

    assert {:error, :invalid_profile_selection} =
             ProfileCatalogue.fetch("lifx.product-27:1.0.0", "invalid thing id")

    assert [summary, older] = ProfileCatalogue.summaries()
    assert summary.profile_ref == "lifx.product-27:1.0.0"
    assert summary.capability_keys == ["power"]
    assert summary.qualification_status == :pending_physical_evidence
    refute Map.has_key?(summary, :capabilities)
    assert older.profile_ref == "lifx.product-22:1.0.0"
    assert older.qualification_status == :pending_physical_evidence
  end

  test "an interview advertises only exact packaged matches" do
    assert {:ok, candidate} =
             Candidate.new(%{
               "interface_id" => "en0",
               "transport" => "udp",
               "source_endpoint" => "192.168.1.10:56700",
               "receive_epoch" => "boot:1",
               "received_monotonic_ms" => 1,
               "raw_ref" => "candidate:1",
               "claimed_identifiers" => %{"stable_id" => "lifx:d073d5001337"},
               "trust_class" => "untrusted_network"
             })

    input = %{
      "candidate_ref" => candidate.raw_ref,
      "transport" => "udp",
      "manufacturer" => "lifx.vendor.1",
      "model" => "lifx.product.27",
      "firmware" => "3.60",
      "stable_id" => "lifx:d073d5001337"
    }

    assert {:ok, interview} = Interview.new(input, candidate)
    assert [%{profile_ref: "lifx.product-27:1.0.0"}] = ProfileCatalogue.matching(interview)

    assert {:ok, unsupported} = Interview.new(%{input | "firmware" => "3.61"}, candidate)
    assert ProfileCatalogue.matching(unsupported) == []

    assert {:ok, older} =
             Interview.new(
               %{input | "model" => "lifx.product.22", "firmware" => "1.22"},
               candidate
             )

    assert [%{profile_ref: "lifx.product-22:1.0.0"}] = ProfileCatalogue.matching(older)
    assert {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:older")
    assert Map.keys(package.thing.capabilities) == ["power"]

    assert package.thing.capabilities["power"].evidence_ref ==
             "qualification:pending:lifx:1:22:1.22"

    assert {:ok, changed} =
             Interview.new(
               %{input | "model" => "lifx.product.22", "firmware" => "1.23"},
               candidate
             )

    assert ProfileCatalogue.matching(changed) == []
  end
end
