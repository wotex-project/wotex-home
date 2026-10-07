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
end
