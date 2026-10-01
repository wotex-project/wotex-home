defmodule WotexHome.QualificationDecisionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Lifx.{ProductRegistry, ProfileBasis}
  alias WotexHome.Qualification.{Attestation, Decision, Evidence, Programme}

  @cohort %{
    "source_identity_ref" => String.duplicate("a", 64),
    "hardware_sku" => "lifx.old-eu",
    "hardware_revision" => "rev.1",
    "firmware" => "2.80",
    "adapter_profile" => "lifx.old-eu:1.0.0",
    "native_stack" => "wotex-udp:test",
    "host_os" => "macos:test",
    "runtime" => "otp:test",
    "network_topology" => "isolated-lan:1",
    "application" => "home:test",
    "model" => "none"
  }

  test "distinct pinned physical reviewer binds all signed power cases and current basis" do
    {signed, basis, attestations, case_keys, decision_keys} = fixture()

    assert {:ok, verified} =
             Decision.verify(signed, basis, @cohort, attestations, case_keys, decision_keys)

    assert verified.evidence_ref ==
             "qualification:" <>
               (:crypto.hash(:sha256, verified.package_bytes) |> Base.encode16(case: :lower))

    assert verified.basis_digest == basis.basis_digest
    assert verified.thing_id == "light:desk"

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(signed, basis, @cohort, tl(attestations), case_keys, decision_keys)

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(signed, basis, @cohort, attestations, %{}, decision_keys)

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(
               signed,
               basis,
               %{@cohort | "firmware" => "2.81"},
               attestations,
               case_keys,
               decision_keys
             )

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(signed, basis, @cohort, attestations, case_keys, %{})

    changed_basis = %{basis | product: {1, 28}}

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(
               signed,
               changed_basis,
               @cohort,
               attestations,
               case_keys,
               decision_keys
             )

    tampered = put_in(signed, ["decision", "resource_revision"], 1)

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(tampered, basis, @cohort, attestations, case_keys, decision_keys)
  end

  test "a valid newly signed decision cannot authorize the old codec-only runtime scope" do
    legacy_modules = [
      WotexHome.Lifx.Packet,
      WotexHome.Lifx.PowerSession,
      WotexHome.Lifx.ReadSession,
      WotexHome.Lifx.Report,
      ProductRegistry,
      WotexHome.Lifx.DirectPowerSafety,
      ProfileBasis
    ]

    hashes =
      Enum.map(legacy_modules, fn module ->
        {^module, bytes, _} = :code.get_object_code(module)
        {module, digest(bytes)}
      end)

    {signed, basis, attestations, case_keys, decision_keys} = fixture(digest(hashes))
    assert ProfileBasis.valid?(basis)

    assert {:error, :invalid_qualification_decision} =
             Decision.verify(signed, basis, @cohort, attestations, case_keys, decision_keys)
  end

  defp fixture(runtime_override \\ nil) do
    assert {:ok, cases, programme_digest} = Programme.lifx_power_cases()
    assert {:ok, cohort_digest} = Evidence.cohort_digest(@cohort)
    assert {:ok, runtime_digest} = ProfileBasis.runtime_digest()
    {case_public, case_private} = :crypto.generate_key(:eddsa, :ed25519)
    {decision_public, decision_private} = :crypto.generate_key(:eddsa, :ed25519)
    case_key_id = "reviewer:cases"
    decision_key_id = "reviewer:physical"

    basis = %{
      profile: "lifx-direct-power-v1",
      thing_id: "light:desk",
      profile_ref: "lifx.old-eu:1.0.0",
      qualification_ref: "cohort:old-eu:1",
      identity_digest: String.duplicate("b", 64),
      product: {1, 27},
      firmware: {2, 80},
      registry_digest: ProductRegistry.pinned_digest(),
      declaration_digest: String.duplicate("c", 64),
      runtime_digest: runtime_override || runtime_digest,
      scope: :profile_mapping_only,
      status: :pending_physical_qualification
    }

    basis_digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(basis, [:deterministic]))
      |> Base.encode16(case: :lower)

    basis = Map.put(basis, :basis_digest, basis_digest)
    assert ProfileBasis.valid?(basis)

    attestations =
      Enum.map(cases, fn case_definition ->
        receipt =
          Map.merge(case_definition, %{
            "receipt_id" => "receipt:#{case_definition["case_id"]}",
            "status" => "passed",
            "cohort" => @cohort,
            "source_identity_ref" => @cohort["source_identity_ref"],
            "command_sequence" => ["step:request", "step:report"],
            "assertions" => [%{"id" => "matches", "expected" => true, "actual" => true}],
            "artifact_digests" => [String.duplicate("d", 64)],
            "exclusions" => [],
            "blockers" => [],
            "reviewer_ref" => case_key_id
          })

        assert {:ok, payload} =
                 Attestation.signing_payload(case_key_id, programme_digest, receipt)

        %{
          "receipt" => receipt,
          "reviewer_key_id" => case_key_id,
          "programme_digest" => programme_digest,
          "signature" =>
            :crypto.sign(:eddsa, :none, payload, [case_private, :ed25519])
            |> Base.url_encode64(padding: false)
        }
      end)

    decision = %{
      "schema" => "wotex-home.lifx-power-decision.v1",
      "scope" => "lifx_direct_power_v1",
      "outcome" => "allow_direct_power",
      "thing_id" => basis.thing_id,
      "profile_ref" => basis.profile_ref,
      "resource_revision" => 0,
      "identity_digest" => basis.identity_digest,
      "basis_digest" => basis.basis_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => basis.runtime_digest,
      "programme_digest" => programme_digest,
      "cohort_digest" => cohort_digest,
      "evidence_set_digest" => Decision.evidence_set_digest(attestations),
      "reviewer_key_id" => decision_key_id
    }

    assert {:ok, payload} = Decision.signing_payload(decision)

    signed = %{
      "decision" => decision,
      "signature" =>
        :crypto.sign(:eddsa, :none, payload, [decision_private, :ed25519])
        |> Base.url_encode64(padding: false)
    }

    {signed, basis, attestations, %{case_key_id => case_public},
     %{decision_key_id => decision_public}}
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
