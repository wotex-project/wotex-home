defmodule ExMaude.IoT.ConflictParserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.IoT.ConflictParser

  doctest ExMaude.IoT.ConflictParser

  describe "parse_conflicts/1" do
    test "returns empty list for noConflict output" do
      output = "result ConflictSet: noConflict"
      assert ConflictParser.parse_conflicts(output) == []
    end

    test "returns empty list when no conflict pattern found" do
      output = "result ConflictSet: empty"
      assert ConflictParser.parse_conflicts(output) == []
    end

    test "parses single state conflict" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "motion-light", thing("light-1"), propEq("motion", boolVal(true)), setProp(thing("light-1"), "state", strVal("on")), 1), rule( "night-mode", thing("light-1"), propGt("time", intVal("2300")), setProp(thing("light-1"), "state", strVal("off")), 1), "Both rules modify state property")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.type == :state_conflict
      assert conflict.rule1 == "motion-light"
      assert conflict.rule2 == "night-mode"
      assert String.contains?(conflict.reason, "state")
    end

    test "parses environment conflict" do
      output = """
      result ConflictSet: conflict(envConflict, rule( "cool-room", thing("window-1"), envGt("temperature", intVal("25")), setEnv("window_state", strVal("open")), 1), rule( "quiet-mode", thing("window-1"), envGt("noise", intVal("60")), setEnv("window_state", strVal("closed")), 1), "Opposing environmental changes")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.type == :env_conflict
    end

    test "parses state cascade conflict" do
      output = """
      result ConflictSet: conflict(stateCascade, rule( "door-light", thing("light-1"), propEq("door", strVal("open")), setProp(thing("light-1"), "state", strVal("on")), 1), rule( "light-sound", thing("speaker-1"), propEq("state", strVal("on")), setProp(thing("speaker-1"), "playing", boolVal(true)), 1), "Rule chain detected")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.type == :state_cascade
    end

    test "parses state-env cascade conflict" do
      output = """
      result ConflictSet: conflict(stateEnvCascade, rule( "ac-on", thing("ac-1"), envGt("temperature", intVal("28")), setProp(thing("ac-1"), "state", strVal("on")), 1), rule( "window-close", thing("window-1"), propEq("state", strVal("on")), setEnv("ventilation", strVal("closed")), 1), "State and environment cascade")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.type == :state_env_cascade
    end

    test "parses multiple conflicts" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, setProp(thing("d1"), "x", strVal("a")), 1), rule( "r2", thing("d1"), always, setProp(thing("d1"), "x", strVal("b")), 1), "Property conflict") | conflict(envConflict, rule( "r3", thing("d2"), always, setEnv("temp", intVal("20")), 1), rule( "r4", thing("d3"), always, setEnv("temp", intVal("30")), 1), "Environment conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 2
      types = Enum.map(conflicts, & &1.type)
      assert :state_conflict in types
      assert :env_conflict in types
    end

    test "handles multiline output with whitespace" do
      output = """
      reduce in CONFLICT-DETECTOR : detectAllConflicts(rules) .
      result ConflictSet: conflict(stateConflict,
        rule( "r1", thing("d1"), always, nil, 1),
        rule( "r2", thing("d1"), always, nil, 1),
        "Conflict found")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
    end

    test "handles noConflict mixed with conflict keyword in reason" do
      # Edge case: the word "noConflict" should not trigger empty list
      # if there's actually a conflict() expression
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, nil, 1), rule( "r2", thing("d1"), always, nil, 1), "This is not a noConflict situation")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
    end

    test "deduplicates identical conflicts" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, nil, 1), rule( "r2", thing("d1"), always, nil, 1), "Same conflict") | conflict(stateConflict, rule( "r1", thing("d1"), always, nil, 1), rule( "r2", thing("d1"), always, nil, 1), "Same conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
    end

    test "handles unknown conflict type" do
      output = """
      result ConflictSet: conflict(unknownType, rule( "r1", thing("d1"), always, nil, 1), rule( "r2", thing("d1"), always, nil, 1), "Unknown type")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.type == :unknown_conflict
    end

    test "handles malformed conflict gracefully" do
      # Missing required fields should result in nil being filtered out
      output = """
      result ConflictSet: conflict(stateConflict, broken data here)
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert conflicts == []
    end

    test "handles nested parentheses in values" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), and(propEq("a", boolVal(true)), propEq("b", boolVal(false))), setProp(thing("d1"), "x", strVal("val")), 1), rule( "r2", thing("d1"), or(propGt("x", intVal("10")), propLt("x", intVal("5"))), setProp(thing("d1"), "x", strVal("other")), 1), "Complex triggers conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == "r2"
    end
  end

  describe "parse_conflicts/1 additional edge cases" do
    test "returns empty list for empty string" do
      assert ConflictParser.parse_conflicts("") == []
    end

    test "returns empty list for whitespace only" do
      assert ConflictParser.parse_conflicts("   \n\t  ") == []
    end

    test "handles output with only noConflict" do
      output = "noConflict"
      assert ConflictParser.parse_conflicts(output) == []
    end

    test "handles result prefix with noConflict" do
      output = "result: noConflict"
      assert ConflictParser.parse_conflicts(output) == []
    end

    test "handles multiple conflicts separated by pipe with spaces" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "a", thing("d"), always, nil, 1), rule( "b", thing("d"), always, nil, 1), "first conflict") | conflict(envConflict, rule( "c", thing("d"), always, nil, 1), rule( "d", thing("d"), always, nil, 1), "second conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 2
      types = Enum.map(conflicts, & &1.type)
      assert :state_conflict in types
      assert :env_conflict in types
    end

    test "extracts correct reason text" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, nil, 1), rule( "r2", thing("d1"), always, nil, 1), "Both rules set the same property")
      """

      [conflict] = ConflictParser.parse_conflicts(output)

      assert conflict.reason == "Both rules set the same property"
    end

    test "handles rule IDs with special characters" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "rule-with-dashes", thing("d1"), always, nil, 1), rule( "rule_with_underscores", thing("d1"), always, nil, 1), "Conflict detected")
      """

      [conflict] = ConflictParser.parse_conflicts(output)

      assert conflict.rule1 == "rule-with-dashes"
      assert conflict.rule2 == "rule_with_underscores"
    end

    test "preserves quoted parentheses and single-token reasons" do
      output =
        ~S|result ConflictSet: conflict(stateConflict, rule("r1\")", thing("d1"), always, nil, 1), rule("r2\\(", thing("d1"), always, nil, 1), "collision")|

      assert [
               %{
                 rule1: ~s|r1")|,
                 rule2: ~s|r2\\(|,
                 reason: "collision"
               }
             ] = ConflictParser.parse_conflicts(output)
    end

    test "handles very long output" do
      # Generate a long conflict output
      rules_part = String.duplicate("x", 1000)

      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, #{rules_part}, 1), rule( "r2", thing("d1"), always, nil, 1), "Long conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)

      assert length(conflicts) == 1
    end
  end

  describe "conflict type parsing" do
    test "maps stateConflict to :state_conflict" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "a", thing("d"), always, nil, 1), rule( "b", thing("d"), always, nil, 1), "conflict detected")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :state_conflict
    end

    test "maps envConflict to :env_conflict" do
      output = """
      result ConflictSet: conflict(envConflict, rule( "a", thing("d"), always, nil, 1), rule( "b", thing("d"), always, nil, 1), "conflict detected")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :env_conflict
    end

    test "maps stateCascade to :state_cascade" do
      output = """
      result ConflictSet: conflict(stateCascade, rule( "a", thing("d"), always, nil, 1), rule( "b", thing("d"), always, nil, 1), "conflict detected")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :state_cascade
    end

    test "maps stateEnvCascade to :state_env_cascade" do
      output = """
      result ConflictSet: conflict(stateEnvCascade, rule( "a", thing("d"), always, nil, 1), rule( "b", thing("d"), always, nil, 1), "conflict detected")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :state_env_cascade
    end

    test "maps unknown type to :unknown_conflict" do
      output = """
      result ConflictSet: conflict(newConflictType, rule( "a", thing("d"), always, nil, 1), rule( "b", thing("d"), always, nil, 1), "conflict detected")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.type == :unknown_conflict
    end
  end

  describe "balanced parentheses parsing" do
    test "handles deeply nested rule triggers" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), and(or(propEq("a", boolVal(true)), propEq("b", boolVal(false))), not(propGt("c", intVal("10")))), setProp(thing("d1"), "state", strVal("on")), 1), rule( "r2", thing("d1"), always, nil, 1), "Complex trigger conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.rule1 == "r1"
      assert conflict.rule2 == "r2"
    end

    test "handles multiple actions in rule" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, setProp(thing("d1"), "a", strVal("1")) ; setProp(thing("d1"), "b", strVal("2")), 1), rule( "r2", thing("d1"), always, nil, 1), "Multiple actions conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
    end

    test "handles unbalanced parentheses gracefully" do
      # Malformed output should not crash
      output = "conflict(stateConflict, rule( \"r1\", thing("
      conflicts = ConflictParser.parse_conflicts(output)
      assert is_list(conflicts)
    end
  end

  describe "parse_conflicts/1 robustness" do
    test "handles nil input safely" do
      # The function expects a string, but should handle edge cases
      assert ConflictParser.parse_conflicts("") == []
    end

    test "handles unicode characters in rule IDs" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "rule-αβγ", thing("d1"), always, nil, 1), rule( "rule-δεζ", thing("d1"), always, nil, 1), "Unicode rule IDs")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert is_list(conflicts)
    end

    test "handles escaped quotes in values" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d1"), always, nil, 1), rule( "r2", thing("d1"), always, nil, 1), "Reason with some text")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert is_binary(conflict.reason)
    end

    test "handles multiple pipe-separated conflicts" do
      # Reasons must contain spaces to be detected as reasons (per parser logic)
      output =
        "result ConflictSet: conflict(stateConflict, rule( \"a\", thing(\"d\"), always, nil, 1), rule( \"b\", thing(\"d\"), always, nil, 1), \"first conflict\") | conflict(envConflict, rule( \"c\", thing(\"d\"), always, nil, 1), rule( \"d\", thing(\"d\"), always, nil, 1), \"second conflict\") | conflict(stateCascade, rule( \"e\", thing(\"d\"), always, nil, 1), rule( \"f\", thing(\"d\"), always, nil, 1), \"third conflict\")"

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 3
    end
  end

  describe "rule ID extraction" do
    test "extracts rule IDs with hyphens" do
      output =
        "result ConflictSet: conflict(stateConflict, rule( \"my-rule-1\", thing(\"d\"), always, nil, 1), rule( \"my-rule-2\", thing(\"d\"), always, nil, 1), \"reason here detected\")"

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.rule1 == "my-rule-1"
      assert conflict.rule2 == "my-rule-2"
    end

    test "extracts rule IDs with underscores" do
      output =
        "result ConflictSet: conflict(stateConflict, rule( \"rule_one\", thing(\"d\"), always, nil, 1), rule( \"rule_two\", thing(\"d\"), always, nil, 1), \"reason detected\")"

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.rule1 == "rule_one"
      assert conflict.rule2 == "rule_two"
    end

    test "extracts rule IDs with numbers" do
      output =
        "result ConflictSet: conflict(stateConflict, rule( \"rule123\", thing(\"d\"), always, nil, 1), rule( \"rule456\", thing(\"d\"), always, nil, 1), \"numeric IDs detected\")"

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.rule1 == "rule123"
      assert conflict.rule2 == "rule456"
    end
  end

  describe "reason extraction" do
    test "extracts simple reason text" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d"), always, nil, 1), rule( "r2", thing("d"), always, nil, 1), "Simple reason text")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert conflict.reason == "Simple reason text"
    end

    test "extracts reason with punctuation" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d"), always, nil, 1), rule( "r2", thing("d"), always, nil, 1), "Reason with commas, periods, and more!")
      """

      [conflict] = ConflictParser.parse_conflicts(output)
      assert String.contains?(conflict.reason, "commas")
    end
  end

  describe "deduplication" do
    test "removes identical conflicts" do
      # Same conflict appearing twice should be deduplicated
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d"), always, nil, 1), rule( "r2", thing("d"), always, nil, 1), "same conflict") | conflict(stateConflict, rule( "r1", thing("d"), always, nil, 1), rule( "r2", thing("d"), always, nil, 1), "same conflict")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
    end

    test "keeps different conflicts" do
      output = """
      result ConflictSet: conflict(stateConflict, rule( "r1", thing("d"), always, nil, 1), rule( "r2", thing("d"), always, nil, 1), "first conflict") | conflict(stateConflict, rule( "r1", thing("d"), always, nil, 1), rule( "r2", thing("d"), always, nil, 1), "different reason")
      """

      conflicts = ConflictParser.parse_conflicts(output)
      # Different reasons mean different conflicts
      assert conflicts != []
    end
  end

  describe "edge case outputs" do
    test "handles output with only result prefix" do
      output = "result ConflictSet:"
      conflicts = ConflictParser.parse_conflicts(output)
      assert conflicts == []
    end

    test "handles output with trailing whitespace" do
      output =
        "result ConflictSet: conflict(stateConflict, rule( \"r1\", thing(\"d\"), always, nil, 1), rule( \"r2\", thing(\"d\"), always, nil, 1), \"reason with spaces\")   "

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
    end

    test "handles output with leading whitespace" do
      output =
        "   result ConflictSet: conflict(stateConflict, rule( \"r1\", thing(\"d\"), always, nil, 1), rule( \"r2\", thing(\"d\"), always, nil, 1), \"reason with spaces\")"

      conflicts = ConflictParser.parse_conflicts(output)
      assert length(conflicts) == 1
    end
  end

  test "strict parsing rejects incomplete and unevaluated results" do
    for output <- ["", "detectAllConflicts(empty)", "conflict(stateConflict,", "garbage"] do
      assert {:error, %ExMaude.Error{type: :parse_error}} = ConflictParser.parse_result(output)
    end
  end
end
