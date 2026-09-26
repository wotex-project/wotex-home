defmodule WotexHome.EnrollmentReviewTest do
  use ExUnit.Case, async: true

  alias WotexHome.Discovery.{Candidate, EnrollmentReview, Interview, Profile}
  alias WotexHome.Semantics.Thing

  @candidate %{
    "interface_id" => "en0",
    "transport" => "udp",
    "source_endpoint" => "192.0.2.10:56700",
    "receive_epoch" => "scan:1",
    "received_monotonic_ms" => 100,
    "raw_ref" => "capture:1",
    "claimed_identifiers" => %{
      "manufacturer" => "LIFX",
      "model" => "old-eu",
      "stable_id" => "d073d5000001"
    },
    "trust_class" => "untrusted_network"
  }

  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware" => "2.0",
    "stable_id" => "d073d5000001"
  }

  @profile %{
    "id" => "lifx.old-eu",
    "version" => "1.0.0",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware_versions" => ["2.0"],
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
    "stable_id" => "d073d5000001",
    "profile_ref" => "lifx.old-eu:1.0.0",
    "qualification_ref" => "cohort:old-eu:1",
    "method" => "legacy_tofu",
    "review_ref" => "review:1"
  }

  test "exact reviewed evidence remains pending authenticated commit" do
    {candidate, interview, profile, thing} = fixtures()

    assert {:ok, %EnrollmentReview{} = review} =
             EnrollmentReview.new([candidate], interview, [profile], thing, @selection)

    assert review.status == :pending_authenticated_commit
    assert review.operator_id == "owner:1"
    assert review.profile_ref == thing.profile_ref
    assert byte_size(review.identity_digest) == 64
  end

  test "selection, claimed identity and profile changes block review" do
    {candidate, interview, profile, thing} = fixtures()

    assert {:error, :selection_mismatch} =
             EnrollmentReview.new(
               [candidate],
               interview,
               [profile],
               thing,
               %{@selection | "method" => "physical_button"}
             )

    assert {:error, :invalid_enrollment_evidence} =
             EnrollmentReview.new(
               [candidate],
               interview,
               [profile],
               %{thing | profile_ref: "lifx.other:1"},
               @selection
             )

    assert {:error, :identity_claim_mismatch} =
             EnrollmentReview.new(
               [%{candidate | claimed_identifiers: %{"stable_id" => "d073d5000002"}}],
               interview,
               [profile],
               thing,
               @selection
             )

    assert {:error, :invalid_selection} =
             EnrollmentReview.new(
               [candidate],
               interview,
               [profile],
               thing,
               Map.put(@selection, "admin", true)
             )
  end

  test "ambiguous candidate and profile evidence cannot be silently selected" do
    {candidate, interview, profile, thing} = fixtures()
    duplicate = %{candidate | source_endpoint: "192.0.2.11:56700"}

    assert {:error, :ambiguous_or_missing_candidate} =
             EnrollmentReview.new([candidate, duplicate], interview, [profile], thing, @selection)

    collision = %{duplicate | raw_ref: "capture:2"}

    assert {:error, :claimed_identity_collision} =
             EnrollmentReview.new([candidate, collision], interview, [profile], thing, @selection)

    second_profile = %{profile | id: "lifx.alternate"}

    assert {:error, :ambiguous_profile} =
             EnrollmentReview.new(
               [candidate],
               interview,
               [profile, second_profile],
               thing,
               @selection
             )
  end

  defp fixtures do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, interview} = Interview.new(@interview, candidate)
    assert {:ok, profile} = Profile.new(@profile)

    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old-eu:1.0.0",
               "capabilities" => [@power]
             })

    {candidate, interview, profile, thing}
  end
end
