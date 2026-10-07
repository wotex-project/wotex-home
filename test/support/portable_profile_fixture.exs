defmodule WotexHome.Test.PortableProfileFixture do
  @moduledoc false
  alias WotexHome.Discovery.{Candidate, Interview}
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Profiles.Artifact

  def context do
    {:ok, artifact} =
      Artifact.parse(File.read!(Path.expand("profiles/lifx-power.json", __DIR__)))

    {:ok, package} = ProfileCatalogue.fetch("lifx.product-22:1.0.0", "light:fixture")

    {:ok, candidate} =
      Candidate.new(%{
        "interface_id" => "en0",
        "transport" => "udp",
        "source_endpoint" => "192.0.2.10:56700",
        "receive_epoch" => "scan:fixture",
        "received_monotonic_ms" => 10,
        "raw_ref" => "capture:fixture",
        "claimed_identifiers" => %{"stable_id" => "lifx:d073d5000001"},
        "trust_class" => "untrusted_network"
      })

    {:ok, interview} =
      Interview.new(
        %{
          "candidate_ref" => candidate.raw_ref,
          "transport" => "udp",
          "manufacturer" => "lifx.vendor.1",
          "model" => "lifx.product.22",
          "firmware" => "1.22",
          "stable_id" => "lifx:d073d5000001"
        },
        candidate
      )

    {:ok, current} = Registry.encode_thing(package.thing)

    basis = %{
      "principal_id" => "operator:fixture",
      "authority_epoch" => 1,
      "store_revision" => 9,
      "profile_policy_generation" => 1,
      "rule_generation" => 1,
      "maintenance_revision" => 5,
      "target_id" => package.thing.id,
      "resource_revision" => 0,
      "binding_revision" => 2,
      "selection_revision" => 0,
      "selection_generation" => 0,
      "trust_revision" => 9,
      "trust_generation" => 1,
      "artifact_digest" => artifact.digest,
      "projection_digest" => artifact.projection_digest,
      "registry_digest" => hd(artifact.data["dependencies"])["sha256"],
      "profile_ref" => artifact.profile_ref,
      "stable_id" => interview.stable_id,
      "manufacturer" => interview.manufacturer,
      "model" => interview.model,
      "firmware" => interview.firmware,
      "current_thing_document" => current
    }

    input = %{
      "action" => "select",
      "authority_epoch" => 1,
      "operation_id" => "profile:selection:fixture",
      "expected_revision" => 9,
      "artifact_digest" => artifact.digest,
      "expected_trust_revision" => 9,
      "target_id" => package.thing.id,
      "expected_resource_revision" => 0,
      "expected_binding_revision" => 2,
      "expected_selection_generation" => 0,
      "expected_policy_generation" => 1,
      "expected_rule_generation" => 1,
      "session_ref" => "session:fixture",
      "candidate_ref" => candidate.raw_ref,
      "review_ref" => "review:fixture"
    }

    evidence = %{
      ref: input["session_ref"],
      candidates: [candidate],
      selected_candidate_ref: candidate.raw_ref,
      interview: interview,
      expires_at: System.monotonic_time(:millisecond) + 60_000
    }

    %{
      artifact: artifact,
      basis: basis,
      input: input,
      evidence: evidence,
      current: package.thing,
      runtime: String.duplicate("a", 64)
    }
  end

  # Synthetic signatures exercise the guarded ledger; they never qualify hardware.
  def qualification(review, resource, case_private, decision_private) do
    alias WotexHome.Lifx.{ProductRegistry, ProfileBasis}
    alias WotexHome.Qualification.{Attestation, Decision, Evidence, Programme}
    {:ok, registry} = ProductRegistry.load_pinned()

    selection =
      Map.new(
        ~w(operator_id candidate_ref stable_id profile_ref qualification_ref method review_ref),
        fn key ->
          {key, Map.fetch!(review.enrollment, String.to_existing_atom(key))}
        end
      )

    {:ok, basis} =
      ProfileBasis.assess(
        review.candidates,
        review.interview,
        [review.artifact.profile],
        review.thing,
        selection,
        registry
      )

    cohort = %{
      "source_identity_ref" => String.duplicate("a", 64),
      "hardware_sku" => "lifx.fixture",
      "hardware_revision" => "fixture.1",
      "firmware" => review.interview.firmware,
      "adapter_profile" => review.thing.profile_ref,
      "native_stack" => "wotex-udp:test",
      "host_os" => "macos:test",
      "runtime" => "otp:test",
      "network_topology" => "fixture:local",
      "application" => "home:test",
      "model" => "none"
    }

    {:ok, cases, programme} = Programme.lifx_power_cases()
    {:ok, cohort_digest} = Evidence.cohort_digest(cohort)

    attestations =
      Enum.map(cases, fn definition ->
        receipt =
          Map.merge(definition, %{
            "receipt_id" => "receipt:#{definition["case_id"]}",
            "status" => "passed",
            "cohort" => cohort,
            "source_identity_ref" => cohort["source_identity_ref"],
            "command_sequence" => ["fixture:request", "fixture:report"],
            "assertions" => [%{"id" => "fixture.matches", "expected" => true, "actual" => true}],
            "artifact_digests" => [String.duplicate("d", 64)],
            "exclusions" => [],
            "blockers" => [],
            "reviewer_ref" => "reviewer:cases"
          })

        {:ok, payload} = Attestation.signing_payload("reviewer:cases", programme, receipt)

        %{
          "receipt" => receipt,
          "reviewer_key_id" => "reviewer:cases",
          "programme_digest" => programme,
          "signature" =>
            :crypto.sign(:eddsa, :none, payload, [case_private, :ed25519])
            |> Base.url_encode64(padding: false)
        }
      end)

    decision = %{
      "schema" => "wotex-home.lifx-power-decision.v1",
      "scope" => "lifx_direct_power_v1",
      "outcome" => "allow_direct_power",
      "thing_id" => review.thing.id,
      "profile_ref" => review.thing.profile_ref,
      "resource_revision" => resource,
      "identity_digest" => basis.identity_digest,
      "basis_digest" => basis.basis_digest,
      "registry_digest" => basis.registry_digest,
      "runtime_digest" => basis.runtime_digest,
      "programme_digest" => programme,
      "cohort_digest" => cohort_digest,
      "evidence_set_digest" => Decision.evidence_set_digest(attestations),
      "reviewer_key_id" => "reviewer:physical"
    }

    {:ok, payload} = Decision.signing_payload(decision)

    signed = %{
      "decision" => decision,
      "signature" =>
        :crypto.sign(:eddsa, :none, payload, [decision_private, :ed25519])
        |> Base.url_encode64(padding: false)
    }

    {signed, basis, cohort, attestations}
  end
end
