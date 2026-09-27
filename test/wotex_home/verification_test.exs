defmodule WotexHome.VerificationTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Rules.Rule
  alias WotexHome.Verification.LegacyConflict

  @base %{
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

  test "translation accepts only the explicitly modeled conflict subset" do
    assert {:ok, rule} = Rule.new(@base)
    assert {:ok, [translated]} = LegacyConflict.translate_rules([rule])
    assert translated.actions == [{:set_prop, "light:desk", "power", true}]
    assert translated.trigger == {:always}

    assert {:ok, edge} =
             Rule.new(%{
               @base
               | "trigger" => %{
                   "kind" => "rising_edge",
                   "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"}
                 }
             })

    assert {:error, :unsupported_model_semantics} = LegacyConflict.translate_rules([edge])

    assert {:error, :invalid_rule_set} =
             LegacyConflict.screen([%{rule | predicate: %{rule.predicate | op: :not}}])

    assert {:ok, conditional} =
             Rule.new(%{
               @base
               | "predicate" => %{
                   "op" => "eq",
                   "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"},
                   "value" => %{"type" => "boolean", "value" => true}
                 }
             })

    assert {:error, :unsupported_model_semantics} =
             LegacyConflict.translate_rules([conditional])
  end

  @tag :integration
  test "a real bundled-model finding rejects an isolated conflicting draft" do
    assert {:ok, first} = Rule.new(@base)

    assert {:ok, second} =
             Rule.new(%{
               @base
               | "id" => "rule:2",
                 "effect" => %{
                   @base["effect"]
                   | "value" => %{"type" => "boolean", "value" => false}
                 }
             })

    assert {:ok, result} = LegacyConflict.screen([first, second])
    assert result.decision == :rejected
    assert result.reason == :state_conflict
    assert result.checker_receipt.execution.completion == :bounded_complete
    assert result.checker_receipt.execution.findings != []
    assert byte_size(result.source_digest) == 64
  end

  @tag :integration
  test "a no-finding run remains inconclusive and never authorizes activation" do
    assert {:ok, rule} = Rule.new(@base)
    assert {:ok, result} = LegacyConflict.screen([rule])
    assert result.decision == :inconclusive
    assert result.reason == :no_matching_conflict
    assert result.checker_receipt.execution.completion == :bounded_complete
    assert result.checker_receipt.execution.findings == []
  end
end
