defmodule WotexHome.CandidateReviewTest do
  use ExUnit.Case

  alias WotexHome.Rules.{CandidateReview, Rule}
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

  @rule %{
    "version" => 1,
    "id" => "rule:1",
    "source_revision" => 1,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 10_000,
    "cooldown_ms" => 1_000,
    "causal_budget" => 4
  }

  test "a no-finding structural screen remains pending and binds exact registry bytes" do
    assert {:ok, rule} = Rule.new(@rule)
    registry = registry()
    assert {:ok, review} = CandidateReview.review([rule], registry)
    assert review.decision == :pending_positive_basis
    assert review.checker_receipt.execution.findings == []
    assert byte_size(review.rule_digest) == 64
    assert byte_size(review.registry_digest) == 64

    assert {:ok, changed} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [%{@power | "evidence_ref" => "fixture:power:2"}]
             })

    assert {:ok, changed_review} =
             CandidateReview.review([rule], Map.put(registry, "light:desk", changed))

    assert changed_review.rule_digest == review.rule_digest
    assert changed_review.registry_digest != review.registry_digest
  end

  test "narrow proposal basis is attached without admitting the draft" do
    assert {:ok, rule} =
             Rule.new(%{@rule | "cooldown_ms" => 0, "causal_budget" => 1})

    assert {:ok, review} = CandidateReview.review([rule], registry())
    assert review.decision == :pending_positive_basis
    assert review.proposal_basis.result == :basis_complete
    assert review.proposal_basis.scope == :proposal_generation_only
    assert review.proposal_basis.target_id == "light:desk"
    assert byte_size(review.proposal_basis.runtime_digest) == 64
  end

  test "a known contradiction rejects even when multi-writer composition lacks positive proof" do
    assert {:ok, first} = Rule.new(@rule)

    assert {:ok, second} =
             Rule.new(%{
               @rule
               | "id" => "rule:2",
                 "effect" => %{
                   @rule["effect"]
                   | "value" => %{"type" => "boolean", "value" => false}
                 }
             })

    assert {:ok, review} = CandidateReview.review([first, second], registry())
    assert review.decision == :rejected
    assert review.reason == :state_conflict
    assert review.checker_receipt.execution.findings != []
  end

  test "unsupported model semantics and forged rule values cannot gain qualification" do
    assert {:ok, edge} =
             Rule.new(%{
               @rule
               | "trigger" => %{
                   "kind" => "rising_edge",
                   "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"}
                 }
             })

    assert {:ok, review} = CandidateReview.review([edge], registry())
    assert review.decision == :pending_positive_basis
    assert review.reason == :legacy_model_unsupported
    assert review.checker_receipt == nil

    assert {:error, :invalid_rule_set} =
             CandidateReview.review([%{edge | causal_budget: 1_000}], registry())
  end

  defp registry do
    assert {:ok, desk} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    assert {:ok, hall} =
             Thing.new(%{
               "id" => "light:hall",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [%{@power | "thing_id" => "light:hall"}]
             })

    %{"light:desk" => desk, "light:hall" => hall}
  end
end
