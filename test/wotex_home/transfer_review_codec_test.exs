defmodule WotexHome.TransferReviewCodecTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery.{IsolationDecision, TransferReviewCodec}

  @fields ~w(deployment_id source_owner_id destination_owner_id source_epoch retirement_revision source_maintenance_revision source_rule_generation archive_digest snapshot_digest runtime_digest owner_custody_digest challenge_id principal_id credential_hash permissions_document domain_digest domain_count counter_state counter_state_digest issued_at_utc_ms expires_at_utc_ms)

  setup do
    review = %{
      "deployment_id" => digest("1"),
      "source_owner_id" => digest("2"),
      "destination_owner_id" => digest("3"),
      "source_epoch" => 1,
      "retirement_revision" => 19,
      "source_maintenance_revision" => 10,
      "source_rule_generation" => 2,
      "archive_digest" => digest("4"),
      "snapshot_digest" => digest("5"),
      "runtime_digest" => digest("6"),
      "owner_custody_digest" => digest("7"),
      "challenge_id" => "transfer:fresh",
      "principal_id" => "operator:fresh",
      "credential_hash" => digest("8"),
      "permissions_document" =>
        "[\"read\",\"host:maintain\",\"profile:manage\",\"enroll:review\"]",
      "domain_digest" => digest("9"),
      "domain_count" => 1,
      "counter_state" => "no_radio_state",
      "counter_state_digest" => nil,
      "issued_at_utc_ms" => 1_000,
      "expires_at_utc_ms" => 601_000
    }

    %{review: review}
  end

  test "ordered review binds every commitment to an exact thirteen-field isolation scope", c do
    assert {:ok, document} = TransferReviewCodec.encode(c.review)

    assert document ==
             JSON.encode!([
               "wotex-home.controller-transfer-review.v1",
               Enum.map(@fields, &c.review[&1])
             ])

    assert {:ok, c.review} == TransferReviewCodec.decode(document)
    assert {:ok, scope} = TransferReviewCodec.isolation_scope(c.review)
    assert map_size(scope) == 13
    assert scope["review_digest"] == Artifact.digest(document)
    assert Map.drop(scope, ["review_digest"]) == Map.take(c.review, Map.keys(scope))
    assert {:error, :invalid_transfer_review} = TransferReviewCodec.decode(document <> "\n")
    assert {:error, :invalid_transfer_review} = TransferReviewCodec.decode(" " <> document)
  end

  test "fresh custody, source barrier, lifetime and snapshot changes all invalidate an old decision",
       c do
    {package, issuers} = signed(c.review)
    assert {:ok, scope} = TransferReviewCodec.isolation_scope(c.review)
    assert {:ok, _} = IsolationDecision.verify(package, scope, issuers, clock())

    for {field, changed} <- [
          {"snapshot_digest", digest("a")},
          {"owner_custody_digest", digest("b")},
          {"credential_hash", digest("c")},
          {"principal_id", "operator:other"},
          {"source_maintenance_revision", 11},
          {"source_rule_generation", 3},
          {"issued_at_utc_ms", 1_001},
          {"expires_at_utc_ms", 600_999}
        ] do
      assert {:ok, altered} =
               TransferReviewCodec.isolation_scope(Map.put(c.review, field, changed))

      refute altered["review_digest"] == scope["review_digest"]

      assert {:error, :isolation_scope_changed} =
               IsolationDecision.verify(package, altered, issuers, clock())
    end

    assert {:error, :isolation_trust_unavailable} =
             IsolationDecision.verify(package, scope, %{}, clock())
  end

  test "unknown counters remain an inert review and cannot form accepted isolation scope", c do
    unknown = %{c.review | "counter_state" => "unknown"}
    assert {:ok, document} = TransferReviewCodec.encode(unknown)
    assert {:ok, ^unknown} = TransferReviewCodec.decode(document)

    assert {:error, :counter_continuity_unavailable} =
             TransferReviewCodec.isolation_scope(unknown)

    assert {:error, :invalid_transfer_review} =
             TransferReviewCodec.encode(%{unknown | "counter_state_digest" => digest("a")})

    continuity = %{
      c.review
      | "counter_state" => "verified_continuity",
        "counter_state_digest" => digest("a")
    }

    assert {:ok, _} = TransferReviewCodec.isolation_scope(continuity)
  end

  test "recovery scope cannot acquire target, control, qualification or policy grants", c do
    for permissions <- [
          "[]",
          "[\"read\"]",
          "[\"control:ordinary\"]",
          "[\"qualify:profile\"]",
          "[\"policy:manage\"]",
          "[\"host:transfer\"]",
          "[\"host:maintain\",\"read\",\"profile:manage\",\"enroll:review\"]"
        ] do
      assert {:error, :invalid_transfer_review} =
               TransferReviewCodec.encode(%{c.review | "permissions_document" => permissions})
    end

    assert {:error, :invalid_transfer_review} =
             TransferReviewCodec.encode(Map.put(c.review, "target_ids", ["light:one"]))
  end

  test "finite epoch, revision, barrier, domain and lifetime bounds fail closed", c do
    for {field, value} <- [
          {"source_epoch", 0},
          {"source_epoch", 9_223_372_036_854_775_807},
          {"retirement_revision", 9_223_372_036_854_775_805},
          {"source_maintenance_revision", 0},
          {"source_maintenance_revision", 19},
          {"source_rule_generation", 0},
          {"source_rule_generation", 9_223_372_036_854_775_807},
          {"domain_count", -1},
          {"domain_count", 65},
          {"domain_count", 1.0},
          {"expires_at_utc_ms", 1_000},
          {"expires_at_utc_ms", 601_001},
          {"issued_at_utc_ms", -1},
          {"counter_state", "not_applicable"},
          {"source_owner_id", c.review["destination_owner_id"]},
          {"challenge_id", "../challenge"},
          {"credential_hash", String.duplicate("A", 64)}
        ] do
      assert {:error, :invalid_transfer_review} =
               TransferReviewCodec.encode(Map.put(c.review, field, value))
    end
  end

  test "closed canonical documents reject missing, oversized and cross-format records", c do
    for field <- @fields do
      assert {:error, :invalid_transfer_review} =
               TransferReviewCodec.encode(Map.delete(c.review, field))
    end

    for document <- [
          nil,
          "",
          "[]",
          "{}",
          :binary.copy(" ", 4_097),
          JSON.encode!([
            "wotex-home.controller-transfer-review.v2",
            Enum.map(@fields, &c.review[&1])
          ])
        ] do
      assert {:error, :invalid_transfer_review} = TransferReviewCodec.decode(document)
    end

    assert {:error, :invalid_transfer_review} = TransferReviewCodec.isolation_scope(nil)
  end

  defp signed(review) do
    {:ok, scope} = TransferReviewCodec.isolation_scope(review)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    decision =
      Map.merge(scope, %{
        "format" => "wotex-home.controller-isolation.v1",
        "method" => "physical_disconnection",
        "procedure_ref" => "isolation:fixture",
        "issuer_id" => "issuer:fixture",
        "issuer_generation" => 1,
        "isolation_policy_digest" => digest("a"),
        "issued_at_utc_ms" => 1_000,
        "expires_at_utc_ms" => 601_000
      })

    {:ok, payload} = IsolationDecision.signing_payload(decision)

    {:ok, bytes} =
      IsolationDecision.encode(
        decision,
        :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      )

    {bytes,
     %{
       "issuer:fixture" => %{
         public_key: public,
         generation: 1,
         method: "physical_disconnection",
         procedure_ref: "isolation:fixture",
         policy_digest: digest("a"),
         counter_state: "no_radio_state"
       }
     }}
  end

  defp clock, do: %{confidence: :trusted, now_utc_ms: 1_000}
  defp digest(value), do: String.duplicate(value, 64)
end
