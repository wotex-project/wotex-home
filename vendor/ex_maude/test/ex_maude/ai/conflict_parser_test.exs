defmodule ExMaude.AI.ConflictParserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.AI.ConflictParser

  doctest ExMaude.AI.ConflictParser

  describe "parse_conflicts/1" do
    test "returns empty list for noAIConflict" do
      output = "result AIConflictSet: noAIConflict"
      assert [] = ConflictParser.parse_conflicts(output)
    end

    test "returns empty list when no marker present" do
      assert [] = ConflictParser.parse_conflicts("nonsense output")
    end

    test "parses single tool-call pairwise conflict" do
      output =
        ~s|result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1", agent(tenant("acme"), "ag1"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("acme"), "ag1"), alwaysP, nilInvocation, noCap, 0, 1), "Same agent, same tool, conflicting required arguments")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :tool_call_conflict
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == "r2"
      assert conflict.reason == "Same agent, same tool, conflicting required arguments"
    end

    test "parses single sovereignty single-rule conflict" do
      output =
        ~s|result AIConflictSet: aiConflictSingle(sovereigntyViolation, aiRule("r1", agent(tenant("acme"), "ag1"), alwaysP, nilInvocation, noCap, 0, 1), "Tool invocation routes through forbidden jurisdiction")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :sovereignty_violation
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == nil
      assert conflict.reason == "Tool invocation routes through forbidden jurisdiction"
    end

    test "parses approval-gate single-rule conflict" do
      output =
        ~s|result AIConflictSet: aiConflictSingle(approvalGateBypass, aiRule("dose", agent(tenant("acme"), "controller"), alwaysP, nilInvocation, noCap, 0, 1), "High-impact invocation reached without approval gate")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :approval_gate_bypass
      assert conflict.rule1 == "dose"
      assert conflict.rule2 == nil
    end

    test "parses multiple conflicts joined with ||c|| operator" do
      output = """
      result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "Same agent, same tool, conflicting required arguments") ||c|| aiConflictSingle(sovereigntyViolation, aiRule("r3", agent(tenant("a"), "y"), alwaysP, nilInvocation, noCap, 0, 1), "Tool invocation routes through forbidden jurisdiction")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 2

      types = Enum.map(conflicts, & &1.type)
      assert :tool_call_conflict in types
      assert :sovereignty_violation in types
    end

    test "parses authority escalation" do
      output =
        ~s|result AIConflictSet: aiConflict(authorityEscalation, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 1, 1), aiRule("r2", agent(tenant("a"), "y"), alwaysP, nilInvocation, noCap, 5, 1), "Rule grants capability requiring higher authority than caller")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :authority_escalation
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == "r2"
    end

    test "parses capability shadowing" do
      output =
        ~s|result AIConflictSet: aiConflict(capabilityShadowing, aiRule("p1", agent(tenant("a"), "x"), alwaysP, nilInvocation, cap("web_search", "v1"), 0, 1), aiRule("p2", agent(tenant("a"), "y"), alwaysP, nilInvocation, cap("web_search", "v1"), 0, 1), "Two rules grant the same capability at equal priority within tenant")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :capability_shadowing
    end

    test "parses pack-tool composition mismatch" do
      output =
        ~s|result AIConflictSet: aiConflict(packToolCompositionMismatch, aiRule("p1", agent(tenant("a"), "x"), alwaysP, nilInvocation, cap("web_search", "v1"), 0, 1), aiRule("p2", agent(tenant("a"), "y"), alwaysP, nilInvocation, cap("web_search", "v2"), 0, 1), "Same capability name with mismatched shape signatures")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :pack_tool_composition_mismatch
    end

    test "parses agent-loop cascade" do
      output =
        ~s|result AIConflictSet: aiConflict(agentLoopCascade, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, cap("c1", "v1"), 0, 1), aiRule("r2", agent(tenant("a"), "y"), capabilityRequired("c1"), nilInvocation, noCap, 0, 1), "Rule grants the capability another rule requires (cascade edge)")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :agent_loop_cascade
    end

    test "deduplicates identical conflicts" do
      conflict_str =
        String.trim("""
        aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "Same agent, same tool, conflicting required arguments")
        """)

      output = "result AIConflictSet: #{conflict_str} ||c|| #{conflict_str}"

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
    end

    test "ignores malformed conflict expressions" do
      output = "aiConflict(broken — no close paren"
      assert [] = ConflictParser.parse_conflicts(output)
    end

    test "returns empty for output with marker but no balanced parens" do
      assert [] = ConflictParser.parse_conflicts("aiConflict(garbage")
    end

    test "unknown conflict type maps to :unknown_conflict" do
      output =
        ~s|result AIConflictSet: aiConflict(notARealType, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "some reason that has spaces in it")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :unknown_conflict
    end
  end

  describe "parse_conflicts/1 edge cases" do
    test "handles empty input" do
      assert [] = ConflictParser.parse_conflicts("")
    end

    test "handles whitespace-only input" do
      assert [] = ConflictParser.parse_conflicts("   \n\t  ")
    end

    test "handles multi-line conflict output preserving structure" do
      output = """
      reduce in AI-CONFLICT-DETECTOR : detectAllConflicts(rules, noJurisdiction) .
      result AIConflictSet: aiConflict(toolCallConflict,
        aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1),
        aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1),
        "Same agent, same tool, conflicting required arguments")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :tool_call_conflict
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == "r2"
    end

    test "noAIConflict marker with empty surrounding text returns no conflicts" do
      assert [] = ConflictParser.parse_conflicts("noAIConflict")
      assert [] = ConflictParser.parse_conflicts("result: noAIConflict")
    end

    test "result prefix with no conflict body returns no conflicts" do
      assert [] = ConflictParser.parse_conflicts("result AIConflictSet:")
    end

    test "handles leading and trailing whitespace around conflict" do
      output =
        ~s|   result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason has spaces")   |

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :tool_call_conflict
    end

    test "rule IDs with hyphens and underscores" do
      output =
        ~s|result AIConflictSet: aiConflict(toolCallConflict, aiRule("rule-with-dashes", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("rule_with_underscores", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason needs spaces")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.rule1 == "rule-with-dashes"
      assert conflict.rule2 == "rule_with_underscores"
    end

    test "rule IDs with digits" do
      output =
        ~s|result AIConflictSet: aiConflict(toolCallConflict, aiRule("rule42", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("rule99", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason needs spaces")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.rule1 == "rule42"
      assert conflict.rule2 == "rule99"
    end

    test "handles nested parentheses in arg maps" do
      output =
        ~s|result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, invokeTool(tool("exec"), "k" : intVal("1"), "cap", eu), noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, invokeTool(tool("exec"), "k" : intVal("2"), "cap", eu), noCap, 0, 1), "Same agent, same tool, conflicting required arguments")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :tool_call_conflict
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == "r2"
    end

    test "handles nested logical predicates inside trigger" do
      output =
        ~s|result AIConflictSet: aiConflictSingle(approvalGateBypass, aiRule("r1", agent(tenant("a"), "x"), andP(orP(capabilityRequired("c1"), notP(capabilityRequired("c2"))), authorityAtLeast(1)), invokeTool(tool("dose"), argMap, "high_impact", eu), noCap, 0, 1), "High-impact invocation reached without approval gate")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :approval_gate_bypass
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == nil
    end

    test "mixes pairwise and single-rule conflicts in any order" do
      output = """
      result AIConflictSet: aiConflictSingle(sovereigntyViolation, aiRule("s1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason has spaces") ||c|| aiConflict(toolCallConflict, aiRule("p1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("p2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "another spaced reason")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 2

      types = Enum.map(conflicts, & &1.type)
      assert :sovereignty_violation in types
      assert :tool_call_conflict in types
    end

    test "extracts long reason text with punctuation" do
      reason =
        "Two rules grant the same capability at equal priority within tenant; please disambiguate."

      output =
        ~s|result AIConflictSet: aiConflict(capabilityShadowing, aiRule("p1", agent(tenant("a"), "x"), alwaysP, nilInvocation, cap("web_search", "v1"), 0, 1), aiRule("p2", agent(tenant("a"), "y"), alwaysP, nilInvocation, cap("web_search", "v1"), 0, 1), "#{reason}")|

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.reason == reason
    end

    test "accepts a single-token reason" do
      output =
        ~s|result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "no-spaces-here")|

      assert [%{reason: "no-spaces-here"}] = ConflictParser.parse_conflicts(output)
    end

    test "preserves escaped quotes, backslashes, and parentheses in rule IDs" do
      output =
        ~S|result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1\")", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2\\(", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason \"quoted\"")|

      assert [
               %{
                 rule1: ~s|r1")|,
                 rule2: ~s|r2\\(|,
                 reason: ~s|reason "quoted"|
               }
             ] = ConflictParser.parse_conflicts(output)
    end

    test "preserves all seven conflict types via the type mapper" do
      mappings = [
        {"toolCallConflict", :tool_call_conflict},
        {"capabilityShadowing", :capability_shadowing},
        {"packToolCompositionMismatch", :pack_tool_composition_mismatch},
        {"sovereigntyViolation", :sovereignty_violation},
        {"authorityEscalation", :authority_escalation},
        {"approvalGateBypass", :approval_gate_bypass},
        {"agentLoopCascade", :agent_loop_cascade}
      ]

      for {maude_constructor, atom} <- mappings do
        # Use pairwise for non-sovereignty/approval, single for those two
        is_single = maude_constructor in ["sovereigntyViolation", "approvalGateBypass"]

        output =
          if is_single do
            ~s|result AIConflictSet: aiConflictSingle(#{maude_constructor}, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason has spaces")|
          else
            ~s|result AIConflictSet: aiConflict(#{maude_constructor}, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "reason has spaces")|
          end

        [conflict] = ConflictParser.parse_conflicts(output)

        assert conflict.type == atom,
               "expected #{maude_constructor} → #{inspect(atom)}, got #{inspect(conflict.type)}"
      end
    end
  end

  describe "parse_conflicts/1 dedup semantics" do
    test "two conflicts with same type+rules+reason dedupe to one" do
      c =
        ~s|aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "Same agent, same tool, conflicting required arguments")|

      output = "result AIConflictSet: #{c} ||c|| #{c} ||c|| #{c}"

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
    end

    test "different reasons produce different conflicts" do
      output = """
      result AIConflictSet: aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "first reason here") ||c|| aiConflict(toolCallConflict, aiRule("r1", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("r2", agent(tenant("a"), "x"), alwaysP, nilInvocation, noCap, 0, 1), "different reason here")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 2
    end
  end

  test "strict parsing rejects incomplete and unevaluated results" do
    for output <- ["", "detectAllConflicts(empty)", "conflict(stateConflict,", "garbage"] do
      assert {:error, %ExMaude.Error{type: :parse_error}} = ConflictParser.parse_result(output)
    end
  end
end
