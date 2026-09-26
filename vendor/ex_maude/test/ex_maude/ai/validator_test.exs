defmodule ExMaude.AI.ValidatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.AI.Validator

  doctest ExMaude.AI.Validator

  describe "validate_rule/1" do
    test "accepts a minimally valid rule" do
      rule = %{
        id: "r1",
        agent_id: {"acme", "ag1"},
        trigger: {:always},
        invocations: []
      }

      assert :ok = Validator.validate_rule(rule)
    end

    test "accepts a rule with all optional fields" do
      rule = %{
        id: "r1",
        agent_id: {"acme", "ag1"},
        trigger: {:prop_eq, "x", {:int, 5}},
        invocations: [{:require_approval, "class"}],
        capability_grants: [{:cap, "name", "v1"}],
        authority_required: 3,
        priority: 5
      }

      assert :ok = Validator.validate_rule(rule)
    end

    test "rejects non-map rule" do
      assert {:error, ["rule must be a map"]} = Validator.validate_rule("not a map")
    end

    test "rejects rule missing required fields" do
      assert {:error, errs} = Validator.validate_rule(%{})
      assert Enum.any?(errs, &(&1 == "missing required field: id"))
      assert Enum.any?(errs, &(&1 == "missing required field: agent_id"))
      assert Enum.any?(errs, &(&1 == "missing required field: trigger"))
      assert Enum.any?(errs, &(&1 == "missing required field: invocations"))
    end

    test "rejects empty id" do
      rule = %{id: "", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      assert {:error, errs} = Validator.validate_rule(rule)
      assert "id must be a non-empty string" in errs
    end

    test "rejects malformed agent_id" do
      rule = %{id: "r1", agent_id: "not_a_tuple", trigger: {:always}, invocations: []}
      assert {:error, errs} = Validator.validate_rule(rule)
      assert "agent_id must be a {tenant_id, agent_name} tuple of non-empty strings" in errs
    end

    test "rejects empty tenant or agent name in agent_id" do
      rule = %{id: "r1", agent_id: {"", "agent"}, trigger: {:always}, invocations: []}
      assert {:error, _} = Validator.validate_rule(rule)
    end

    test "rejects non-list invocations" do
      rule = %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: "not_a_list"}
      assert {:error, errs} = Validator.validate_rule(rule)
      assert "invocations must be a list" in errs
    end

    test "rejects negative authority_required" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        authority_required: -1
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert "authority_required must be a non-negative integer" in errs
    end

    test "rejects negative priority" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        priority: -1
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert "priority must be a non-negative integer" in errs
    end
  end

  describe "validate_predicate/1" do
    test "accepts always" do
      assert :ok = Validator.validate_predicate({:always})
    end

    test "accepts property predicates" do
      assert :ok = Validator.validate_predicate({:prop_eq, "k", {:int, 1}})
      assert :ok = Validator.validate_predicate({:prop_gt, "k", {:int, 1}})
      assert :ok = Validator.validate_predicate({:prop_lt, "k", {:int, 1}})
      assert :ok = Validator.validate_predicate({:prop_gte, "k", {:int, 1}})
      assert :ok = Validator.validate_predicate({:prop_lte, "k", {:int, 1}})
    end

    test "accepts capability predicates" do
      assert :ok = Validator.validate_predicate({:capability_required, "name"})
      assert :ok = Validator.validate_predicate({:capability_granted, "name"})
    end

    test "rejects empty capability name" do
      assert {:error, _} = Validator.validate_predicate({:capability_required, ""})
    end

    test "accepts budget_within with valid interval" do
      assert :ok =
               Validator.validate_predicate(
                 {:budget_within, "openai_monthly", {:interval, 0, 50_000}}
               )
    end

    test "rejects budget_within with inverted interval" do
      assert {:error, _} =
               Validator.validate_predicate(
                 {:budget_within, "openai_monthly", {:interval, 50, 10}}
               )
    end

    test "rejects budget_within with negative bounds" do
      assert {:error, _} =
               Validator.validate_predicate(
                 {:budget_within, "openai_monthly", {:interval, -1, 100}}
               )
    end

    test "accepts authority predicates" do
      assert :ok = Validator.validate_predicate({:authority_at_least, 0})
      assert :ok = Validator.validate_predicate({:authority_required, 5})
    end

    test "rejects negative authority" do
      assert {:error, _} = Validator.validate_predicate({:authority_at_least, -1})
    end

    test "accepts jurisdiction predicates" do
      assert :ok = Validator.validate_predicate({:jurisdiction_allowed, :eu})
      assert :ok = Validator.validate_predicate({:jurisdiction_forbidden, :us})
    end

    test "accepts latency predicate" do
      assert :ok = Validator.validate_predicate({:latency_at_most, 2_000})
    end

    test "rejects negative latency" do
      assert {:error, _} = Validator.validate_predicate({:latency_at_most, -1})
    end

    test "accepts logical operator nesting" do
      assert :ok =
               Validator.validate_predicate(
                 {:and, {:always}, {:not, {:capability_required, "x"}}}
               )
    end

    test "marks contains/matches as unsupported" do
      assert {:error, msg} = Validator.validate_predicate({:contains, "k", "needle"})
      assert msg =~ "unsupported"

      assert {:error, msg} = Validator.validate_predicate({:matches, "k", ~r/x/})
      assert msg =~ "unsupported"
    end

    test "rejects property values the encoder cannot represent" do
      assert {:error, _} = Validator.validate_predicate({:prop_eq, "k", 3.14})
      assert {:error, _} = Validator.validate_predicate({:prop_eq, "k", %{bad: true}})
    end

    test "rejects unknown predicate shapes" do
      assert {:error, _} = Validator.validate_predicate({:something_made_up, "x"})
    end
  end

  describe "validate_invocation/1" do
    test "accepts valid invoke_tool" do
      assert :ok =
               Validator.validate_invocation({:invoke_tool, "x", %{"k" => 1}, "cap", :eu})
    end

    test "accepts require_approval" do
      assert :ok = Validator.validate_invocation({:require_approval, "class"})
    end

    test "rejects empty tool name" do
      assert {:error, _} =
               Validator.validate_invocation({:invoke_tool, "", %{}, "cap", :eu})
    end

    test "rejects empty approval class" do
      assert {:error, _} = Validator.validate_invocation({:require_approval, ""})
    end

    test "rejects nil jurisdiction" do
      assert {:error, _} =
               Validator.validate_invocation({:invoke_tool, "x", %{}, "cap", nil})
    end

    test "rejects jurisdictions outside the Maude enumeration" do
      assert {:error, _} =
               Validator.validate_invocation({:invoke_tool, "x", %{}, "cap", :mars})

      assert {:error, _} = Validator.validate_predicate({:jurisdiction_allowed, :mars})
      assert {:error, _} = Validator.validate_value({:jurisdiction, :mars})
    end

    test "rejects unknown invocation shapes" do
      assert {:error, _} = Validator.validate_invocation({:made_up, "x"})
    end
  end

  describe "validate_rules/1" do
    test "returns ok for empty list" do
      assert :ok = Validator.validate_rules([])
    end

    test "returns ok when all rules valid" do
      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []},
        %{id: "r2", agent_id: {"a", "c"}, trigger: {:always}, invocations: []}
      ]

      assert :ok = Validator.validate_rules(rules)
    end

    test "returns failures map when any rule invalid" do
      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []},
        %{id: "bad", agent_id: "broken", trigger: {:always}, invocations: []}
      ]

      assert {:error, failures} = Validator.validate_rules(rules)
      assert Map.has_key?(failures, "bad")
      refute Map.has_key?(failures, "r1")
    end

    test "uses index marker when rule is nil or missing id" do
      rules = [
        %{agent_id: {"a", "b"}, trigger: {:always}, invocations: []},
        nil
      ]

      assert {:error, failures} = Validator.validate_rules(rules)
      assert Map.has_key?(failures, "<index 0>")
      assert Map.has_key?(failures, "<index 1>")
    end

    test "collects errors for multiple invalid rules" do
      rules = [
        %{id: "r1", agent_id: "no_tuple", trigger: {:always}, invocations: []},
        %{id: "r2", agent_id: {"", ""}, trigger: {:always}, invocations: []},
        %{id: "r3", agent_id: {"a", "b"}, trigger: {:made_up}, invocations: []}
      ]

      assert {:error, failures} = Validator.validate_rules(rules)
      assert map_size(failures) == 3
    end

    test "reports a non-map entry without raising" do
      assert {:error, %{"<index 0>" => ["rule must be a map"]}} =
               Validator.validate_rules([:bad])
    end

    test "rejects non-list batches" do
      assert {:error, %{"rules" => ["rules must be a list"]}} = Validator.validate_rules(%{})
    end
  end

  describe "validate_predicate/1 additional shapes" do
    test "rejects empty capability_granted" do
      assert {:error, _} = Validator.validate_predicate({:capability_granted, ""})
    end

    test "rejects nil jurisdiction in jurisdiction_allowed" do
      assert {:error, _} = Validator.validate_predicate({:jurisdiction_allowed, nil})
    end

    test "rejects nil jurisdiction in jurisdiction_forbidden" do
      assert {:error, _} = Validator.validate_predicate({:jurisdiction_forbidden, nil})
    end

    test "rejects budget_within with non-binary scope" do
      assert {:error, _} =
               Validator.validate_predicate({:budget_within, :atom_scope, {:interval, 0, 10}})
    end

    test "rejects budget_within with non-integer bounds" do
      assert {:error, _} =
               Validator.validate_predicate({:budget_within, "scope", {:interval, 0.5, 10}})
    end

    test "rejects authority_required with negative integer" do
      assert {:error, _} = Validator.validate_predicate({:authority_required, -5})
    end

    test "accepts authority levels at exactly 0 (root)" do
      assert :ok = Validator.validate_predicate({:authority_at_least, 0})
      assert :ok = Validator.validate_predicate({:authority_required, 0})
    end

    test "rejects latency_at_most that is not an integer" do
      assert {:error, _} = Validator.validate_predicate({:latency_at_most, 100.5})
    end

    test "rejects prop_eq with non-binary key" do
      assert {:error, _} = Validator.validate_predicate({:prop_eq, :atom_key, "value"})
    end

    test "rejects and predicate when one side is invalid" do
      assert {:error, _} =
               Validator.validate_predicate({:and, {:always}, {:bogus}})

      assert {:error, _} =
               Validator.validate_predicate({:and, {:bogus}, {:always}})
    end

    test "rejects or predicate when both sides are invalid" do
      assert {:error, _} =
               Validator.validate_predicate({:or, {:bogus}, {:bogus2}})
    end

    test "rejects not predicate wrapping invalid predicate" do
      assert {:error, _} = Validator.validate_predicate({:not, {:bogus}})
    end
  end

  describe "validate_invocation/1 additional shapes" do
    test "rejects invoke_tool with non-binary cap_required" do
      assert {:error, _} =
               Validator.validate_invocation({:invoke_tool, "x", %{}, :atom_cap, :eu})
    end

    test "rejects invoke_tool with non-map args" do
      assert {:error, _} =
               Validator.validate_invocation({:invoke_tool, "x", "string_args", "cap", :eu})
    end

    test "rejects invoke_tool with invalid arg map value" do
      assert {:error, msg} =
               Validator.validate_invocation(
                 {:invoke_tool, "x", %{"k" => {:unknown_type, "v"}}, "cap", :eu}
               )

      assert msg =~ "invoke_tool args"
    end

    test "rejects argument keys the encoder cannot stringify" do
      assert {:error, msg} =
               Validator.validate_invocation(
                 {:invoke_tool, "x", %{{:tuple, :key} => "value"}, "cap", :eu}
               )

      assert msg =~ "unsupported argument key"
    end

    test "rejects invalid UTF-8 before encoding" do
      invalid = <<255>>

      assert {:error, _} =
               Validator.validate_rule(%{
                 id: invalid,
                 agent_id: {"tenant", "agent"},
                 trigger: {:always},
                 invocations: []
               })

      assert {:error, _} =
               Validator.validate_invocation({:invoke_tool, "x", %{"k" => invalid}, "cap", :eu})
    end

    test "accepts invoke_tool with diverse arg map values" do
      args = %{
        "s" => {:str, "x"},
        "i" => {:int, 1},
        "b" => {:bool, true},
        "iv" => {:interval, 0, 10},
        "j" => {:jurisdiction, :eu},
        "n" => nil
      }

      assert :ok = Validator.validate_invocation({:invoke_tool, "x", args, "cap", :eu})
    end
  end

  describe "validate_capability/1" do
    test "accepts tagged cap with name and shape" do
      assert :ok = Validator.validate_capability({:cap, "web_search", "v1"})
    end

    test "accepts bare-string capability" do
      assert :ok = Validator.validate_capability("internet_access")
    end

    test "rejects empty bare-string capability" do
      assert {:error, _} = Validator.validate_capability("")
    end

    test "rejects empty name in tagged cap" do
      assert {:error, _} = Validator.validate_capability({:cap, "", "v1"})
    end

    test "rejects unsupported capability shapes" do
      assert {:error, _} = Validator.validate_capability(:atom)
      assert {:error, _} = Validator.validate_capability(%{})
      assert {:error, _} = Validator.validate_capability({:cap, "name", :atom_shape})
    end
  end

  describe "validate_value/1" do
    test "accepts all tagged scalar shapes" do
      assert :ok = Validator.validate_value({:str, "x"})
      assert :ok = Validator.validate_value({:int, 5})
      assert :ok = Validator.validate_value({:bool, true})
      assert :ok = Validator.validate_value({:interval, 0, 10})
      assert :ok = Validator.validate_value({:jurisdiction, :eu})
      assert :ok = Validator.validate_value(nil)
    end

    test "accepts bare scalars" do
      assert :ok = Validator.validate_value("plain")
      assert :ok = Validator.validate_value(42)
      assert :ok = Validator.validate_value(false)
    end

    test "rejects inverted intervals" do
      assert {:error, _} = Validator.validate_value({:interval, 10, 5})
    end

    test "rejects negative interval bounds" do
      assert {:error, _} = Validator.validate_value({:interval, -1, 5})
    end

    test "rejects atoms as bare values" do
      assert {:error, _} = Validator.validate_value(:bare_atom)
    end

    test "rejects unsupported value shapes" do
      assert {:error, _} = Validator.validate_value({:made_up_tag, "v"})
      assert {:error, _} = Validator.validate_value(%{})
      assert {:error, _} = Validator.validate_value(3.14)
    end
  end

  describe "validate_rule/1 invocations field" do
    test "reports invocation indices in errors" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [
          {:require_approval, "approve"},
          {:made_up_invocation},
          {:invoke_tool, "x", %{}, "cap", :eu}
        ]
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert Enum.any?(errs, &String.contains?(&1, "invocation[1]"))
    end

    test "validates capability_grants list with error index reporting" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        capability_grants: [
          {:cap, "ok", "v1"},
          {:made_up_capability}
        ]
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert Enum.any?(errs, &String.contains?(&1, "capability_grants[1]"))
    end

    test "rejects non-list capability_grants" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        capability_grants: "not_a_list"
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert "capability_grants must be a list" in errs
    end
  end

  describe "validate_rule/1 edge cases" do
    test "preserves error order across multiple failures" do
      rule = %{
        id: "",
        agent_id: "broken",
        trigger: {:always},
        invocations: "not_list",
        authority_required: -1,
        priority: -1
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      # All these errors should appear
      assert "id must be a non-empty string" in errs

      assert "agent_id must be a {tenant_id, agent_name} tuple of non-empty strings" in errs

      assert "invocations must be a list" in errs
      assert "authority_required must be a non-negative integer" in errs
      assert "priority must be a non-negative integer" in errs
    end

    test "non-integer authority_required is rejected" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        authority_required: "high"
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert "authority_required must be a non-negative integer" in errs
    end

    test "non-integer priority is rejected" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        priority: "high"
      }

      assert {:error, errs} = Validator.validate_rule(rule)
      assert "priority must be a non-negative integer" in errs
    end
  end

  test "rejects duplicate identities, nested nil, and control characters" do
    rule = %{id: "r", agent_id: {"t", "a"}, trigger: {:always}, invocations: []}
    assert {:error, _} = Validator.validate_rules([rule, rule])
    assert {:error, _} = Validator.validate_rule(%{rule | trigger: {:not, nil}})
    assert {:error, _} = Validator.validate_rule(%{rule | id: "bad\nname"})
    nested = Enum.reduce(1..12, {:always}, fn _, p -> {:not, p} end)
    assert {:error, _} = Validator.validate_rule(%{rule | trigger: nested})
  end

  test "rejects atom and string argument keys that encode identically" do
    assert {:error, _} =
             Validator.validate_invocation(
               {:invoke_tool, "tool", %{:x => 1, "x" => 2}, "cap", :eu}
             )
  end
end
