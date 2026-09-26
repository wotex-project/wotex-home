defmodule ExMaude.AI.EncoderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.AI.Encoder

  doctest ExMaude.AI.Encoder

  describe "encode_string/1" do
    test "wraps a simple string in quotes" do
      assert Encoder.encode_string("hello") == ~s("hello")
    end

    test "escapes embedded double quotes" do
      assert Encoder.encode_string(~s(hello "world")) == ~s("hello \\"world\\"")
    end

    test "escapes backslashes" do
      assert Encoder.encode_string("a\\b") == ~s("a\\\\b")
    end
  end

  describe "encode_agent_id/1" do
    test "encodes a tenant + agent pair" do
      assert Encoder.encode_agent_id({"acme", "ph-controller"}) ==
               ~s|agent(tenant("acme"), "ph-controller")|
    end
  end

  describe "encode_value/1" do
    test "wraps tagged values per type" do
      assert Encoder.encode_value({:str, "x"}) == ~s|strVal("x")|
      assert Encoder.encode_value({:int, 42}) == ~s|intVal("42")|
      assert Encoder.encode_value({:bool, true}) == "boolVal(true)"
      assert Encoder.encode_value({:bool, false}) == "boolVal(false)"
      assert Encoder.encode_value({:interval, 0, 100}) == "intervalVal(0, 100)"
      assert Encoder.encode_value({:jurisdiction, :eu}) == "jurisdictionVal(eu)"
      assert Encoder.encode_value(nil) == "null"
    end

    test "convenience-encodes bare scalars" do
      assert Encoder.encode_value("plain") == ~s|strVal("plain")|
      assert Encoder.encode_value(7) == ~s|intVal("7")|
      assert Encoder.encode_value(true) == "boolVal(true)"
    end
  end

  describe "encode_predicate/1" do
    test "encodes carry-over property predicates" do
      assert Encoder.encode_predicate({:prop_eq, "ph", {:int, 7}}) ==
               ~s|propEq("ph", intVal("7"))|

      assert Encoder.encode_predicate({:prop_gt, "tds", {:int, 500}}) ==
               ~s|propGt("tds", intVal("500"))|
    end

    test "encodes capability predicates" do
      assert Encoder.encode_predicate({:capability_required, "web_search"}) ==
               ~s|capabilityRequired("web_search")|

      assert Encoder.encode_predicate({:capability_granted, "ph_dosing"}) ==
               ~s|capabilityGranted("ph_dosing")|
    end

    test "encodes budget predicates with intervals" do
      assert Encoder.encode_predicate({:budget_within, "openai_monthly", {:interval, 0, 50_000}}) ==
               ~s|budgetWithin("openai_monthly", intervalVal(0, 50000))|
    end

    test "encodes authority predicates" do
      assert Encoder.encode_predicate({:authority_at_least, 3}) == "authorityAtLeast(3)"
      assert Encoder.encode_predicate({:authority_required, 5}) == "authorityRequired(5)"
    end

    test "encodes jurisdiction predicates" do
      assert Encoder.encode_predicate({:jurisdiction_allowed, :eu}) == "jurisdictionAllowed(eu)"

      assert Encoder.encode_predicate({:jurisdiction_forbidden, :us}) ==
               "jurisdictionForbidden(us)"
    end

    test "encodes latency predicates" do
      assert Encoder.encode_predicate({:latency_at_most, 2_000}) == "latencyAtMost(2000)"
    end

    test "encodes always" do
      assert Encoder.encode_predicate({:always}) == "alwaysP"
    end

    test "encodes logical operators" do
      assert Encoder.encode_predicate({:and, {:always}, {:authority_at_least, 1}}) ==
               "andP(alwaysP, authorityAtLeast(1))"

      assert Encoder.encode_predicate({:or, {:always}, {:always}}) ==
               "orP(alwaysP, alwaysP)"

      assert Encoder.encode_predicate({:not, {:authority_at_least, 1}}) ==
               "notP(authorityAtLeast(1))"
    end
  end

  describe "encode_invocation/1" do
    test "encodes invoke_tool with empty args" do
      result =
        Encoder.encode_invocation({:invoke_tool, "web_search", %{}, "internet_access", :eu})

      assert result == ~s|invokeTool(tool("web_search"), argMap, "internet_access", eu)|
    end

    test "encodes invoke_tool with structured args" do
      result =
        Encoder.encode_invocation(
          {:invoke_tool, "web_search", %{"query" => "x", "limit" => 10}, "internet_access", :eu}
        )

      # Args sorted alphabetically by key for deterministic encoding
      assert result =~ ~s|invokeTool(tool("web_search")|
      assert result =~ ~s|"limit" : intVal("10")|
      assert result =~ ~s|"query" : strVal("x")|
      assert result =~ ~s|, "internet_access", eu)|
    end

    test "encodes require_approval" do
      assert Encoder.encode_invocation({:require_approval, "dosing_high_delta"}) ==
               ~s|requireApproval("dosing_high_delta")|
    end
  end

  describe "encode_invocations/1" do
    test "empty list encodes to nilInvocation" do
      assert Encoder.encode_invocations([]) == "nilInvocation"
    end

    test "single invocation encodes without separator" do
      assert Encoder.encode_invocations([{:require_approval, "x"}]) ==
               ~s|requireApproval("x")|
    end

    test "multiple invocations join with >>" do
      result =
        Encoder.encode_invocations([
          {:require_approval, "approval_class"},
          {:invoke_tool, "tool_x", %{}, "cap", :eu}
        ])

      assert result =~ ~s|requireApproval("approval_class")|
      assert result =~ " >> "
      assert result =~ ~s|invokeTool(tool("tool_x")|
    end
  end

  describe "encode_capability_set/1" do
    test "empty list encodes to noCap" do
      assert Encoder.encode_capability_set([]) == "noCap"
    end

    test "tagged capability encodes with shape hash" do
      assert Encoder.encode_capability_set([{:cap, "web_search", "v1"}]) ==
               ~s|cap("web_search", "v1")|
    end

    test "bare-string capability gets default shape" do
      assert Encoder.encode_capability_set(["web_search"]) ==
               ~s|cap("web_search", "default")|
    end

    test "multiple capabilities join with ||" do
      result =
        Encoder.encode_capability_set([
          {:cap, "a", "v1"},
          {:cap, "b", "v1"}
        ])

      assert result =~ ~s|cap("a", "v1")|
      assert result =~ " || "
      assert result =~ ~s|cap("b", "v1")|
    end
  end

  describe "encode_jurisdiction_set/1" do
    test "empty list encodes to noJurisdiction" do
      assert Encoder.encode_jurisdiction_set([]) == "noJurisdiction"
    end

    test "single jurisdiction encodes as bare atom" do
      assert Encoder.encode_jurisdiction_set([:eu]) == "eu"
    end

    test "multiple jurisdictions join with ;;" do
      assert Encoder.encode_jurisdiction_set([:eu, :ch]) == "eu ;; ch"
    end
  end

  describe "encode_rule/1" do
    test "encodes a minimal rule" do
      rule = %{
        id: "r1",
        agent_id: {"acme", "ag1"},
        trigger: {:always},
        invocations: []
      }

      assert Encoder.encode_rule(rule) ==
               ~s|aiRule("r1", agent(tenant("acme"), "ag1"), alwaysP, nilInvocation, noCap, 0, 1)|
    end

    test "encodes a rule with all optional fields" do
      rule = %{
        id: "approve-then-dose",
        agent_id: {"acme", "ph-controller"},
        trigger: {:prop_lt, "ph", {:int, 6}},
        invocations: [
          {:require_approval, "dosing_high_delta"},
          {:invoke_tool, "dose", %{"ml" => 50}, "high_impact", :eu}
        ],
        capability_grants: [{:cap, "ph_dosing", "v1"}],
        authority_required: 2,
        priority: 10
      }

      result = Encoder.encode_rule(rule)

      assert result =~ ~s|aiRule("approve-then-dose"|
      assert result =~ ~s|agent(tenant("acme"), "ph-controller")|
      assert result =~ ~s|propLt("ph", intVal("6"))|
      assert result =~ ~s|requireApproval("dosing_high_delta")|
      assert result =~ ~s|cap("ph_dosing", "v1")|
      assert String.ends_with?(result, ", 2, 10)")
    end
  end

  describe "encode_rules/1" do
    test "empty list encodes to emptyRules" do
      assert Encoder.encode_rules([]) == {:ok, "emptyRules"}
    end

    test "joins rules with ;" do
      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []},
        %{id: "r2", agent_id: {"a", "c"}, trigger: {:always}, invocations: []}
      ]

      {:ok, encoded} = Encoder.encode_rules(rules)
      assert encoded =~ ~s|aiRule("r1"|
      assert encoded =~ " ; "
      assert encoded =~ ~s|aiRule("r2"|
    end

    test "encodes a large rule set" do
      rules =
        for i <- 1..10 do
          %{
            id: "rule-#{i}",
            agent_id: {"acme", "agent-#{i}"},
            trigger: {:always},
            invocations: [],
            priority: i
          }
        end

      {:ok, encoded} = Encoder.encode_rules(rules)

      for i <- 1..10 do
        assert encoded =~ ~s|"rule-#{i}"|
      end
    end
  end

  describe "encode_string/1 edge cases" do
    test "encodes empty string" do
      assert Encoder.encode_string("") == ~s("")
    end

    test "escapes a single backslash before a quote correctly" do
      assert Encoder.encode_string(~s(a\\"b)) == ~s("a\\\\\\"b")
    end

    test "escapes consecutive backslashes" do
      assert Encoder.encode_string("a\\\\b") == ~s("a\\\\\\\\b")
    end

    test "leaves a string of plain characters unchanged in content" do
      assert Encoder.encode_string("acme-tenant_42") == ~s("acme-tenant_42")
    end
  end

  describe "encode_value/1 edge cases" do
    test "rejects bare floats by raising FunctionClauseError" do
      unsupported = :erlang.binary_to_term(:erlang.term_to_binary(3.14))
      assert_raise FunctionClauseError, fn -> Encoder.encode_value(unsupported) end
    end

    test "encodes intVal for zero" do
      assert Encoder.encode_value({:int, 0}) == ~s|intVal("0")|
    end

    test "encodes intVal for a large negative integer" do
      assert Encoder.encode_value({:int, -1_000_000}) == ~s|intVal("-1000000")|
    end

    test "encodes intervalVal with lo == hi" do
      assert Encoder.encode_value({:interval, 5, 5}) == "intervalVal(5, 5)"
    end

    test "encodes intervalVal at zero" do
      assert Encoder.encode_value({:interval, 0, 0}) == "intervalVal(0, 0)"
    end

    test "rejects inverted intervals via guard" do
      assert_raise FunctionClauseError, fn -> Encoder.encode_value({:interval, 10, 5}) end
    end

    test "rejects negative bounds in intervals via guard" do
      assert_raise FunctionClauseError, fn -> Encoder.encode_value({:interval, -1, 5}) end
    end

    test "encodes strVal for a binary with embedded quote" do
      assert Encoder.encode_value({:str, ~s(say "hi")}) == ~s|strVal("say \\"hi\\"")|
    end

    test "encodes jurisdictionVal for multi-letter atoms" do
      assert Encoder.encode_value({:jurisdiction, :ch}) == "jurisdictionVal(ch)"
    end
  end

  describe "encode_predicate/1 nesting" do
    test "encodes deeply nested logical predicate" do
      pred =
        {:and, {:or, {:not, {:capability_required, "c1"}}, {:authority_at_least, 2}},
         {:and, {:jurisdiction_allowed, :eu}, {:latency_at_most, 1_000}}}

      encoded = Encoder.encode_predicate(pred)

      assert encoded =~ "andP("
      assert encoded =~ "orP("
      assert encoded =~ "notP("
      assert encoded =~ ~s|capabilityRequired("c1")|
      assert encoded =~ "authorityAtLeast(2)"
      assert encoded =~ "jurisdictionAllowed(eu)"
      assert encoded =~ "latencyAtMost(1000)"
    end

    test "encodes prop_eq with bool value" do
      assert Encoder.encode_predicate({:prop_eq, "active", {:bool, true}}) ==
               ~s|propEq("active", boolVal(true))|
    end

    test "encodes prop_gte and prop_lte" do
      assert Encoder.encode_predicate({:prop_gte, "x", {:int, 5}}) ==
               ~s|propGte("x", intVal("5"))|

      assert Encoder.encode_predicate({:prop_lte, "y", {:int, 9}}) ==
               ~s|propLte("y", intVal("9"))|
    end

    test "encodes authority_at_least 0 (root authority)" do
      assert Encoder.encode_predicate({:authority_at_least, 0}) == "authorityAtLeast(0)"
    end

    test "encodes budget_within with non-zero lo" do
      assert Encoder.encode_predicate({:budget_within, "scope", {:interval, 100, 500}}) ==
               ~s|budgetWithin("scope", intervalVal(100, 500))|
    end

    test "encodes double negation" do
      encoded = Encoder.encode_predicate({:not, {:not, {:always}}})
      assert encoded == "notP(notP(alwaysP))"
    end
  end

  describe "encode_arg_map/1" do
    test "empty map encodes to argMap" do
      assert Encoder.encode_arg_map(%{}) == "argMap"
    end

    test "single-key map omits separator" do
      assert Encoder.encode_arg_map(%{"k" => {:int, 1}}) == ~s|("k" : intVal("1"))|
    end

    test "multi-key map sorts keys deterministically" do
      assert Encoder.encode_arg_map(%{"b" => {:int, 2}, "a" => {:int, 1}}) ==
               ~s|("a" : intVal("1")) andArg ("b" : intVal("2"))|
    end

    test "stringifies non-binary keys via to_string/1" do
      assert Encoder.encode_arg_map(%{:atom_key => {:str, "v"}}) ==
               ~s|("atom_key" : strVal("v"))|
    end

    test "accepts bare scalars and wraps via encode_value" do
      assert Encoder.encode_arg_map(%{"k" => "plain"}) == ~s|("k" : strVal("plain"))|
      assert Encoder.encode_arg_map(%{"k" => 7}) == ~s|("k" : intVal("7"))|
      assert Encoder.encode_arg_map(%{"k" => true}) == ~s|("k" : boolVal(true))|
    end
  end

  describe "encode_invocation/1 edge cases" do
    test "invoke_tool with nested intVal arg" do
      encoded =
        Encoder.encode_invocation(
          {:invoke_tool, "exec", %{"timeout_ms" => {:int, 30_000}}, "exec", :eu}
        )

      assert encoded =~ ~s|"timeout_ms" : intVal("30000")|
    end

    test "invoke_tool jurisdiction encoded as bare atom" do
      encoded =
        Encoder.encode_invocation({:invoke_tool, "x", %{}, "cap", :ch})

      assert String.ends_with?(encoded, ~s|, "cap", ch)|)
    end

    test "require_approval preserves underscores in class name" do
      assert Encoder.encode_invocation({:require_approval, "dosing_high_delta_v2"}) ==
               ~s|requireApproval("dosing_high_delta_v2")|
    end
  end

  describe "encode_invocations/1 ordering" do
    test "preserves input order for chained invocations" do
      invocations = [
        {:require_approval, "approval_1"},
        {:invoke_tool, "tool_a", %{}, "cap", :eu},
        {:invoke_tool, "tool_b", %{}, "cap", :eu}
      ]

      encoded = Encoder.encode_invocations(invocations)

      idx_approval = :binary.match(encoded, "approval_1") |> elem(0)
      idx_a = :binary.match(encoded, "tool_a") |> elem(0)
      idx_b = :binary.match(encoded, "tool_b") |> elem(0)

      assert idx_approval < idx_a
      assert idx_a < idx_b
    end
  end

  describe "encode_capability_set/1 edge cases" do
    test "preserves explicit shape over default" do
      assert Encoder.encode_capability_set([{:cap, "x", "explicit_shape"}]) ==
               ~s|cap("x", "explicit_shape")|
    end

    test "mixes tagged caps and bare strings" do
      encoded =
        Encoder.encode_capability_set([
          {:cap, "named", "v1"},
          "bare_string"
        ])

      assert encoded =~ ~s|cap("named", "v1")|
      assert encoded =~ " || "
      assert encoded =~ ~s|cap("bare_string", "default")|
    end
  end

  describe "encode_jurisdiction_set/1 edge cases" do
    test "encodes three jurisdictions with proper separator" do
      assert Encoder.encode_jurisdiction_set([:eu, :ch, :uk]) == "eu ;; ch ;; uk"
    end
  end

  describe "encode_agent_id/1 edge cases" do
    test "preserves embedded hyphens" do
      assert Encoder.encode_agent_id({"acme-corp", "agent-12-final"}) ==
               ~s|agent(tenant("acme-corp"), "agent-12-final")|
    end

    test "preserves embedded underscores" do
      assert Encoder.encode_agent_id({"acme_corp", "ph_controller_v2"}) ==
               ~s|agent(tenant("acme_corp"), "ph_controller_v2")|
    end
  end

  describe "encode_rule/1 defaults" do
    test "defaults capability_grants to noCap" do
      rule = %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      assert Encoder.encode_rule(rule) =~ ", noCap, 0, 1)"
    end

    test "defaults priority to 1 and authority_required to 0" do
      rule = %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      assert String.ends_with?(Encoder.encode_rule(rule), ", 0, 1)")
    end

    test "honors authority_required override with default priority" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        authority_required: 3
      }

      assert String.ends_with?(Encoder.encode_rule(rule), ", 3, 1)")
    end

    test "honors priority override with default authority_required" do
      rule = %{
        id: "r1",
        agent_id: {"a", "b"},
        trigger: {:always},
        invocations: [],
        priority: 99
      }

      assert String.ends_with?(Encoder.encode_rule(rule), ", 0, 99)")
    end
  end
end
