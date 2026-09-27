defmodule WotexHome.RestrictedBasisTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.{RestrictedBasis, Rule}
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
    "id" => "rule:power-on",
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
    "cooldown_ms" => 0,
    "causal_budget" => 1
  }

  test "one explicit Boolean Light rule receives a digest-bound proposal basis" do
    assert {:ok, rule} = Rule.new(@rule)
    things = registry()

    assert {:ok, basis} = RestrictedBasis.qualify([rule], things)
    assert basis.result == :basis_complete
    assert basis.profile == "explicit-boolean-light-v1"
    assert basis.scope == :proposal_generation_only
    assert :runtime_correspondence in basis.obligations
    assert :pure_gate_precedence in basis.obligations
    assert :blocked_root_preservation in basis.obligations
    assert byte_size(basis.rule_digest) == 64
    assert byte_size(basis.registry_digest) == 64
    assert byte_size(basis.runtime_digest) == 64
    assert {:ok, ^basis} = RestrictedBasis.qualify([rule], things)

    assert {:ok, changed} = Rule.new(%{@rule | "source_revision" => 2})
    assert {:ok, changed_basis} = RestrictedBasis.qualify([changed], things)
    refute changed_basis.rule_digest == basis.rule_digest

    assert {:ok, alternate_id} = Rule.new(%{@rule | "id" => "rule:other"})

    assert {:ok, %{result: :basis_complete}} =
             RestrictedBasis.qualify([alternate_id], things)
  end

  test "edge, predicate, extra budget and extra writer remain outside the basis" do
    things = registry()
    assert {:ok, rule} = Rule.new(@rule)

    edge =
      %{
        @rule
        | "trigger" => %{
            "kind" => "rising_edge",
            "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"}
          }
      }

    assert {:ok, edge_rule} = Rule.new(edge)

    assert {:error, _reason} = RestrictedBasis.qualify([edge_rule], things)

    assert {:ok, predicate_rule} =
             Rule.new(%{
               @rule
               | "predicate" => %{
                   "op" => "eq",
                   "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"},
                   "value" => %{"type" => "boolean", "value" => true}
                 }
             })

    assert {:error, _reason} = RestrictedBasis.qualify([predicate_rule], things)

    for field <- ["causal_budget", "cooldown_ms"] do
      assert {:ok, widened} =
               Rule.new(Map.put(@rule, field, if(field == "causal_budget", do: 2, else: 1)))

      assert {:error, :unsupported_restricted_profile} =
               RestrictedBasis.qualify([widened], things)
    end

    assert {:error, :unsupported_restricted_profile} =
             RestrictedBasis.qualify([rule, %{rule | id: "rule:other"}], things)
  end

  test "forged rule and registry cannot obtain a basis" do
    assert {:ok, rule} = Rule.new(@rule)
    things = registry()
    refute match?({:ok, _}, RestrictedBasis.qualify([%{rule | causal_budget: 100}], things))

    refute match?(
             {:ok, _},
             RestrictedBasis.qualify([rule], %{"light:other" => things["light:desk"]})
           )
  end

  defp registry do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    %{"light:desk" => thing}
  end
end
