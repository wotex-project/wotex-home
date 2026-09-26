defmodule WotexHome.RulesTest do
  use ExUnit.Case, async: true

  alias WotexHome.Rules.{Analyzer, Predicate, Rule}
  alias WotexHome.Semantics.{Thing, Value}

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
    "trigger" => %{
      "kind" => "rising_edge",
      "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"}
    },
    "predicate" => %{
      "op" => "eq",
      "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"},
      "value" => %{"type" => "boolean", "value" => true}
    },
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

  test "negating an unknown fact remains unknown" do
    raw = %{
      "op" => "not",
      "predicate" => %{
        "op" => "eq",
        "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"},
        "value" => %{"type" => "boolean", "value" => false}
      }
    }

    assert {:ok, predicate} = Predicate.new(raw)
    assert :unknown = Predicate.evaluate(predicate, %{})
    assert :unknown = Predicate.evaluate(predicate, %{{"light:hall", "power"} => :unknown})
    assert {:ok, power_on} = Value.new(%{"type" => "boolean", "value" => true})
    assert true = Predicate.evaluate(predicate, %{{"light:hall", "power"} => {:known, power_on}})
    assert {:ok, wrong_kind} = Value.new(%{"type" => "fraction", "ppm" => 0})

    assert :unknown =
             Predicate.evaluate(predicate, %{{"light:hall", "power"} => {:known, wrong_kind}})
  end

  test "three-valued all and any obey unknown rather than absence-to-false" do
    unknown = %{
      "op" => "eq",
      "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"},
      "value" => %{"type" => "boolean", "value" => true}
    }

    false_predicate = %{"op" => "not", "predicate" => %{"op" => "literal_true"}}

    assert {:ok, all} =
             Predicate.new(%{"op" => "all", "predicates" => [unknown, false_predicate]})

    assert Predicate.evaluate(all, %{}) == false

    assert {:ok, any} =
             Predicate.new(%{"op" => "any", "predicates" => [unknown, false_predicate]})

    assert :unknown = Predicate.evaluate(any, %{})
  end

  test "thresholds use exact typed integers and reject unsupported operators" do
    fact = %{"thing_id" => "light:hall", "capability_key" => "brightness"}
    raw = %{"op" => "gt", "fact" => fact, "value" => %{"type" => "fraction", "ppm" => 500_000}}
    assert {:ok, predicate} = Predicate.new(raw)
    assert {:ok, equal} = Value.new(%{"type" => "fraction", "ppm" => 500_000})
    assert {:ok, greater} = Value.new(%{"type" => "fraction", "ppm" => 500_001})

    assert Predicate.evaluate(predicate, %{{"light:hall", "brightness"} => {:known, equal}}) ==
             false

    assert true =
             Predicate.evaluate(predicate, %{{"light:hall", "brightness"} => {:known, greater}})

    assert {:error, :invalid_value} =
             Predicate.new(%{raw | "value" => %{"type" => "fraction", "ppm" => 0.5}})

    assert {:error, :unsupported_comparison} =
             Predicate.new(%{raw | "value" => %{"type" => "boolean", "value" => true}})

    assert {:error, :unsupported_predicate} =
             Predicate.new(%{"op" => "run_elixir", "source" => "IO.puts(1)"})
  end

  test "rule data rejects unknown fields and unsupported temporal semantics" do
    assert {:ok, %Rule{} = rule} = Rule.new(@rule)
    assert MapSet.member?(Rule.input_facts(rule), {"light:hall", "power"})
    assert {:error, :invalid_fields} = Rule.new(Map.put(@rule, "script", "send_packet()"))

    assert {:error, :unsupported_trigger} =
             Rule.new(%{@rule | "trigger" => %{"kind" => "deadline", "at" => 123}})

    assert {:error, :invalid_rule_metadata} = Rule.new(%{@rule | "causal_budget" => 10_000})
    assert {:error, :invalid_rule_metadata} = Rule.new(%{@rule | "unknown_policy" => "false"})
  end

  test "restricted structure requires qualified ordinary capabilities and one writer" do
    things = light_registry()
    assert {:ok, rule} = Rule.new(@rule)
    assert {:ok, :structurally_restricted} = Analyzer.restricted([rule], things)

    second = %{rule | id: "rule:2"}
    assert {:error, :multiple_writers} = Analyzer.restricted([rule, second], things)

    self_feedback = %{rule | trigger: {:rising_edge, {"light:desk", "power"}}}
    assert {:error, :feedback_not_supported} = Analyzer.restricted([self_feedback], things)
  end

  test "safety-sensitive input and mismatched value need separate qualification" do
    things = light_registry()
    assert {:ok, rule} = Rule.new(@rule)

    wrong_value = %{
      rule
      | predicate:
          elem(
            Predicate.new(%{
              "op" => "eq",
              "fact" => %{"thing_id" => "light:hall", "capability_key" => "power"},
              "value" => %{"type" => "fraction", "ppm" => 1}
            }),
            1
          )
    }

    assert {:error, :incompatible_predicate} = Analyzer.restricted([wrong_value], things)

    smoke_capability = %{
      @power
      | "thing_id" => "smoke:hall",
        "role" => "SmokeDetector",
        "key" => "smoke_state",
        "value_kind" => "smoke_state",
        "operations" => ["read"],
        "risk_class" => "sensitive",
        "profile_ref" => "aqara.detector:1"
    }

    assert {:ok, smoke} =
             Thing.new(%{
               "id" => "smoke:hall",
               "role" => "SmokeDetector",
               "profile_ref" => "aqara.detector:1",
               "capabilities" => [smoke_capability]
             })

    smoke_rule = %{rule | trigger: {:rising_edge, {"smoke:hall", "smoke_state"}}}

    assert {:error, :proof_required_or_unsupported_input} =
             Analyzer.restricted([smoke_rule], Map.put(things, "smoke:hall", smoke))
  end

  defp light_registry do
    assert {:ok, desk} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    hall_capability = %{@power | "thing_id" => "light:hall"}

    assert {:ok, hall} =
             Thing.new(%{
               "id" => "light:hall",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [hall_capability]
             })

    %{"light:desk" => desk, "light:hall" => hall}
  end
end
