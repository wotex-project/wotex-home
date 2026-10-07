defmodule WotexHome.PortableProfileReviewTest do
  use ExUnit.Case, async: true

  alias WotexHome.Discovery.{Candidate, Interview}
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Profiles.{Artifact, Review}

  setup do
    {:ok, artifact} =
      Artifact.parse(File.read!(Path.expand("../support/profiles/lifx-power.json", __DIR__)))

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
      interview: interview
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

  test "the proposal binds exact bytes, pins, runtime and unqualified declaration", c do
    assert {:ok, review} = review(c)
    assert review.enrollment.operator_id == c.basis["principal_id"]
    assert review.enrollment.method == "legacy_tofu"
    assert review.thing.profile_ref == c.artifact.profile_ref
    assert review.digest == Artifact.digest(review.document)

    assert ["wotex-home.profile-selection-review.v1", _, pins, runtime, identity, document] =
             JSON.decode!(review.document)

    assert length(pins) == map_size(c.basis) and runtime == c.runtime
    assert identity == review.enrollment.identity_digest
    assert {:ok, review.thing} == Registry.decode_thing(document)
    assert review.summary.status == :pending_authenticated_selection
    assert review.summary.qualification_status == :pending_physical_evidence
    refute review.summary.new_control_grants
    assert {:ok, ^review} = review(c)
  end

  test "every caller CAS pin remains exact and cannot be silently refreshed", c do
    for key <-
          ~w(authority_epoch expected_revision expected_trust_revision expected_resource_revision expected_binding_revision expected_selection_generation expected_policy_generation expected_rule_generation) do
      assert {:error, :stale_profile_review_basis} =
               review(%{c | input: Map.update!(c.input, key, &(&1 + 1))})
    end

    assert {:error, :invalid_profile_review_basis} =
             review(%{c | basis: Map.put(c.basis, "caller_permission", "control:ordinary")})
  end

  test "another raw serialization, registry or projection cannot replace the approved digest",
       c do
    {:ok, changed} = Artifact.parse(c.artifact.bytes <> " ")
    assert changed.projection_digest == c.artifact.projection_digest
    assert {:error, :profile_review_mismatch} = review(%{c | artifact: changed})

    for key <- ~w(projection_digest registry_digest) do
      assert {:error, :profile_review_mismatch} =
               review(%{c | basis: Map.put(c.basis, key, String.duplicate("0", 64))})
    end
  end

  test "capture identity, firmware, selected reference and session cannot change", c do
    for key <- [:stable_id, :manufacturer, :model, :firmware, :candidate_ref] do
      evidence =
        Map.put(c.evidence, :interview, Map.put(c.evidence.interview, key, "changed:fixture"))

      assert {:error, :profile_capture_mismatch} = review(%{c | evidence: evidence})
    end

    assert {:error, :profile_capture_mismatch} =
             review(%{c | evidence: %{c.evidence | ref: "session:other"}})
  end

  test "a matching second candidate's conflicting stable identity stays unresolved", c do
    candidate = %{
      hd(c.evidence.candidates)
      | raw_ref: "capture:other",
        source_endpoint: "192.0.2.11:56700"
    }

    assert {:error, :claimed_identity_collision} =
             review(%{
               c
               | evidence: %{c.evidence | candidates: [hd(c.evidence.candidates), candidate]}
             })
  end

  test "a read-only or tighter previous declaration cannot inherit write or wider freshness", c do
    for power <- [
          %{c.current.capabilities["power"] | operations: ["read"]},
          %{c.current.capabilities["power"] | freshness_ms: 1_000}
        ] do
      current = %{c.current | capabilities: %{"power" => power}}
      {:ok, document} = Registry.encode_thing(current)

      assert {:error, :declaration_widening} =
               review(%{c | basis: Map.put(c.basis, "current_thing_document", document)})
    end
  end

  test "profile changes can only retain or remove already executable semantics", c do
    {:ok, next} = Artifact.declaration(c.artifact, c.current.id)
    assert :ok = Review.no_widening(c.current, next)
    power = %{next.capabilities["power"] | operations: ["read"], freshness_ms: 1_000}
    narrower = %{next | capabilities: %{"power" => power}}
    assert :ok = Review.no_widening(c.current, narrower)
    assert {:error, :declaration_widening} = Review.no_widening(narrower, next)

    assert {:error, :declaration_widening} =
             Review.no_widening(%{c.current | id: "light:other"}, next)
  end

  defp review(c), do: Review.new(c.basis, c.artifact, c.evidence, c.input, c.runtime)
end
