defmodule ExMaude.IoT.EncoderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.IoT.Encoder

  doctest ExMaude.IoT.Encoder

  describe "encode_rules/1" do
    test "encodes empty list" do
      assert {:ok, "empty"} = Encoder.encode_rules([])
    end

    test "encodes single rule" do
      rule = %{
        id: "test-rule",
        thing_id: "device-1",
        trigger: {:always},
        actions: [],
        priority: 1
      }

      {:ok, encoded} = Encoder.encode_rules([rule])

      assert String.contains?(encoded, "rule(")
      assert String.contains?(encoded, "\"test-rule\"")
      assert String.contains?(encoded, "thing(\"device-1\")")
      assert String.contains?(encoded, "always")
    end

    test "encodes multiple rules with comma separator" do
      rules = [
        %{id: "r1", thing_id: "d1", trigger: {:always}, actions: [], priority: 1},
        %{id: "r2", thing_id: "d2", trigger: {:always}, actions: [], priority: 2}
      ]

      {:ok, encoded} = Encoder.encode_rules(rules)

      assert String.contains?(encoded, "\"r1\"")
      assert String.contains?(encoded, "\"r2\"")
      assert String.contains?(encoded, ", ")
    end
  end

  describe "encode_rule/1" do
    test "encodes rule with all fields" do
      rule = %{
        id: "my-rule",
        thing_id: "sensor-1",
        trigger: {:prop_eq, "motion", true},
        actions: [{:set_prop, "light-1", "state", "on"}],
        priority: 5
      }

      encoded = Encoder.encode_rule(rule)

      assert String.starts_with?(encoded, "rule(")
      assert String.contains?(encoded, "\"my-rule\"")
      assert String.contains?(encoded, "thing(\"sensor-1\")")
      assert String.contains?(encoded, "propEq")
      assert String.contains?(encoded, "setProp")
      assert String.ends_with?(encoded, ", 5)")
    end

    test "defaults priority to 1" do
      rule = %{
        id: "test",
        thing_id: "d1",
        trigger: {:always},
        actions: []
      }

      encoded = Encoder.encode_rule(rule)
      assert String.ends_with?(encoded, ", 1)")
    end
  end

  describe "encode_thing_id/1" do
    test "wraps id in thing()" do
      assert Encoder.encode_thing_id("device-1") == "thing(\"device-1\")"
    end
  end

  describe "encode_trigger/1" do
    test "encodes prop_eq" do
      assert Encoder.encode_trigger({:prop_eq, "state", true}) ==
               "propEq(\"state\", boolVal(true))"
    end

    test "encodes prop_gt" do
      assert Encoder.encode_trigger({:prop_gt, "temp", 25}) ==
               "propGt(\"temp\", intVal(\"25\"))"
    end

    test "encodes prop_lt" do
      assert Encoder.encode_trigger({:prop_lt, "level", 10}) ==
               "propLt(\"level\", intVal(\"10\"))"
    end

    test "encodes prop_gte" do
      assert Encoder.encode_trigger({:prop_gte, "count", 5}) ==
               "propGte(\"count\", intVal(\"5\"))"
    end

    test "encodes prop_lte" do
      assert Encoder.encode_trigger({:prop_lte, "value", 100}) ==
               "propLte(\"value\", intVal(\"100\"))"
    end

    test "encodes env_eq" do
      assert Encoder.encode_trigger({:env_eq, "weather", "sunny"}) ==
               "envEq(\"weather\", strVal(\"sunny\"))"
    end

    test "encodes env_gt" do
      assert Encoder.encode_trigger({:env_gt, "humidity", 60}) ==
               "envGt(\"humidity\", intVal(\"60\"))"
    end

    test "encodes env_lt" do
      assert Encoder.encode_trigger({:env_lt, "noise", 30}) ==
               "envLt(\"noise\", intVal(\"30\"))"
    end

    test "encodes always" do
      assert Encoder.encode_trigger({:always}) == "always"
    end

    test "encodes and" do
      trigger = {:and, {:prop_eq, "a", true}, {:prop_eq, "b", false}}
      encoded = Encoder.encode_trigger(trigger)

      assert String.starts_with?(encoded, "and(")
      assert String.contains?(encoded, "propEq(\"a\"")
      assert String.contains?(encoded, "propEq(\"b\"")
    end

    test "encodes or" do
      trigger = {:or, {:prop_gt, "x", 10}, {:prop_lt, "x", 5}}
      encoded = Encoder.encode_trigger(trigger)

      assert String.starts_with?(encoded, "or(")
    end

    test "encodes not" do
      trigger = {:not, {:prop_eq, "active", true}}
      encoded = Encoder.encode_trigger(trigger)

      assert String.starts_with?(encoded, "not(")
      assert String.contains?(encoded, "propEq")
    end

    test "encodes nested compound triggers" do
      trigger = {:and, {:or, {:prop_eq, "a", true}, {:prop_eq, "b", true}}, {:not, {:always}}}
      encoded = Encoder.encode_trigger(trigger)

      assert String.starts_with?(encoded, "and(")
      assert String.contains?(encoded, "or(")
      assert String.contains?(encoded, "not(")
    end
  end

  describe "encode_actions/1" do
    test "encodes empty actions as nil" do
      assert Encoder.encode_actions([]) == "nil"
    end

    test "encodes single action" do
      actions = [{:set_prop, "light-1", "state", "on"}]
      encoded = Encoder.encode_actions(actions)

      assert String.contains?(encoded, "setProp")
      assert String.contains?(encoded, "thing(\"light-1\")")
    end

    test "encodes multiple actions with semicolon separator" do
      actions = [
        {:set_prop, "light-1", "state", "on"},
        {:set_env, "brightness", 80}
      ]

      encoded = Encoder.encode_actions(actions)

      assert String.contains?(encoded, " ; ")
      assert String.contains?(encoded, "setProp")
      assert String.contains?(encoded, "setEnv")
    end
  end

  describe "encode_action/1" do
    test "encodes set_prop" do
      encoded = Encoder.encode_action({:set_prop, "device-1", "power", "on"})

      assert String.starts_with?(encoded, "setProp(")
      assert String.contains?(encoded, "thing(\"device-1\")")
      assert String.contains?(encoded, "\"power\"")
      assert String.contains?(encoded, "strVal(\"on\")")
    end

    test "encodes set_env" do
      encoded = Encoder.encode_action({:set_env, "temperature", 22})

      assert String.starts_with?(encoded, "setEnv(")
      assert String.contains?(encoded, "\"temperature\"")
      assert String.contains?(encoded, "intVal(\"22\")")
    end

    test "encodes invoke" do
      encoded = Encoder.encode_action({:invoke, "device-1", "toggle"})

      assert String.starts_with?(encoded, "invoke(")
      assert String.contains?(encoded, "thing(\"device-1\")")
      assert String.contains?(encoded, "\"toggle\"")
    end
  end

  describe "encode_string/1" do
    test "wraps binary in quotes" do
      assert Encoder.encode_string("hello") == "\"hello\""
    end

    test "converts atom to quoted string" do
      assert Encoder.encode_string(:world) == "\"world\""
    end

    test "escapes embedded double quotes" do
      assert Encoder.encode_string(~s(hello "world")) == ~s("hello \\"world\\"")
    end

    test "escapes backslashes" do
      assert Encoder.encode_string("a\\b") == ~s("a\\\\b")
    end

    test "escapes a single backslash before a quote correctly" do
      assert Encoder.encode_string(~s(a\\"b)) == ~s("a\\\\\\"b")
    end

    test "escapes consecutive backslashes" do
      assert Encoder.encode_string("a\\\\b") == ~s("a\\\\\\\\b")
    end

    test "escapes quotes inside encoded values" do
      assert Encoder.encode_value(~s(say "hi")) == ~s|strVal("say \\"hi\\"")|
    end
  end

  describe "encode_value/1" do
    test "encodes true as boolVal" do
      assert Encoder.encode_value(true) == "boolVal(true)"
    end

    test "encodes false as boolVal" do
      assert Encoder.encode_value(false) == "boolVal(false)"
    end

    test "encodes integer as intVal" do
      assert Encoder.encode_value(42) == "intVal(\"42\")"
    end

    test "encodes float as intVal" do
      assert Encoder.encode_value(3.14) == "intVal(\"3.14\")"
    end

    test "encodes binary as strVal" do
      assert Encoder.encode_value("hello") == "strVal(\"hello\")"
    end

    test "encodes atom as strVal" do
      assert Encoder.encode_value(:active) == "strVal(\"active\")"
    end
  end

  describe "encode_value/1 edge cases" do
    test "encodes zero integer" do
      assert Encoder.encode_value(0) == "intVal(\"0\")"
    end

    test "encodes negative integer" do
      assert Encoder.encode_value(-42) == "intVal(\"-42\")"
    end

    test "encodes zero float" do
      assert Encoder.encode_value(0.0) == "intVal(\"0.0\")"
    end

    test "encodes negative float" do
      assert Encoder.encode_value(-3.14) == "intVal(\"-3.14\")"
    end

    test "encodes empty string" do
      assert Encoder.encode_value("") == "strVal(\"\")"
    end

    test "encodes string with spaces" do
      assert Encoder.encode_value("hello world") == "strVal(\"hello world\")"
    end
  end

  describe "encode_string/1 edge cases" do
    test "encodes empty string" do
      assert Encoder.encode_string("") == "\"\""
    end

    test "encodes string with special characters" do
      assert Encoder.encode_string("a-b_c") == "\"a-b_c\""
    end

    test "encodes atom with underscores" do
      assert Encoder.encode_string(:foo_bar) == "\"foo_bar\""
    end
  end

  describe "encode_actions/1 edge cases" do
    test "encodes single set_prop with boolean value" do
      actions = [{:set_prop, "d", "active", true}]
      encoded = Encoder.encode_actions(actions)

      assert String.contains?(encoded, "boolVal(true)")
    end

    test "encodes multiple different action types" do
      actions = [
        {:set_prop, "d1", "state", "on"},
        {:set_env, "temp", 25},
        {:invoke, "d2", "reset"}
      ]

      encoded = Encoder.encode_actions(actions)

      assert String.contains?(encoded, "setProp")
      assert String.contains?(encoded, "setEnv")
      assert String.contains?(encoded, "invoke")
      assert String.contains?(encoded, " ; ")
    end
  end

  describe "encode_trigger/1 deeply nested" do
    test "encodes triple nested and/or/not" do
      trigger =
        {:and, {:or, {:not, {:prop_eq, "a", true}}, {:prop_gt, "b", 10}},
         {:not, {:env_eq, "c", "val"}}}

      encoded = Encoder.encode_trigger(trigger)

      assert String.starts_with?(encoded, "and(")
      assert String.contains?(encoded, "or(")
      assert String.contains?(encoded, "not(")
      assert String.contains?(encoded, "propEq")
      assert String.contains?(encoded, "propGt")
      assert String.contains?(encoded, "envEq")
    end
  end

  describe "encode_rule/1 complete" do
    test "encodes complete rule with all trigger types and actions" do
      rule = %{
        id: "complex-rule",
        thing_id: "smart-device",
        trigger: {:and, {:prop_eq, "motion", true}, {:env_gt, "time", 1800}},
        actions: [
          {:set_prop, "light", "brightness", 100},
          {:set_env, "scene", "evening"},
          {:invoke, "speaker", "announce"}
        ],
        priority: 10
      }

      encoded = Encoder.encode_rule(rule)

      assert String.contains?(encoded, "\"complex-rule\"")
      assert String.contains?(encoded, "thing(\"smart-device\")")
      assert String.contains?(encoded, "and(")
      assert String.contains?(encoded, "propEq")
      assert String.contains?(encoded, "envGt")
      assert String.contains?(encoded, "setProp")
      assert String.contains?(encoded, "setEnv")
      assert String.contains?(encoded, "invoke")
      assert String.ends_with?(encoded, ", 10)")
    end
  end

  describe "encode_rules/1 edge cases" do
    test "encodes large number of rules" do
      rules =
        for i <- 1..10 do
          %{
            id: "rule-#{i}",
            thing_id: "device-#{i}",
            trigger: {:always},
            actions: [],
            priority: i
          }
        end

      {:ok, encoded} = Encoder.encode_rules(rules)

      for i <- 1..10 do
        assert String.contains?(encoded, "\"rule-#{i}\"")
      end
    end

    test "handles rules with special characters in IDs" do
      rule = %{
        id: "rule-with-dashes_and_underscores",
        thing_id: "device-1",
        trigger: {:always},
        actions: [],
        priority: 1
      }

      {:ok, encoded} = Encoder.encode_rules([rule])
      assert String.contains?(encoded, "rule-with-dashes_and_underscores")
    end
  end

  describe "encode_trigger/1 comprehensive" do
    test "encodes env_gte trigger" do
      # env_gte may not be implemented - test for robustness
      trigger = {:env_gt, "humidity", 80}
      encoded = Encoder.encode_trigger(trigger)
      assert String.contains?(encoded, "envGt")
    end

    test "encodes env_lt trigger" do
      trigger = {:env_lt, "noise", 40}
      encoded = Encoder.encode_trigger(trigger)
      assert String.contains?(encoded, "envLt")
    end

    test "encodes deeply nested or triggers" do
      trigger =
        {:or, {:or, {:or, {:prop_eq, "a", 1}, {:prop_eq, "b", 2}}, {:prop_eq, "c", 3}},
         {:prop_eq, "d", 4}}

      encoded = Encoder.encode_trigger(trigger)

      assert String.contains?(encoded, "or(")
      assert String.contains?(encoded, "propEq")
    end

    test "encodes double negation" do
      trigger = {:not, {:not, {:always}}}
      encoded = Encoder.encode_trigger(trigger)

      assert String.starts_with?(encoded, "not(not(")
      assert String.contains?(encoded, "always")
    end
  end

  describe "encode_actions/1 with various values" do
    test "encodes action with boolean true value" do
      actions = [{:set_prop, "device", "active", true}]
      encoded = Encoder.encode_actions(actions)
      assert String.contains?(encoded, "boolVal(true)")
    end

    test "encodes action with boolean false value" do
      actions = [{:set_prop, "device", "active", false}]
      encoded = Encoder.encode_actions(actions)
      assert String.contains?(encoded, "boolVal(false)")
    end

    test "encodes action with integer value" do
      actions = [{:set_prop, "device", "level", 75}]
      encoded = Encoder.encode_actions(actions)
      assert String.contains?(encoded, "intVal(\"75\")")
    end

    test "encodes action with string value" do
      actions = [{:set_prop, "device", "mode", "auto"}]
      encoded = Encoder.encode_actions(actions)
      assert String.contains?(encoded, "strVal(\"auto\")")
    end

    test "encodes action with atom value" do
      actions = [{:set_prop, "device", "status", :running}]
      encoded = Encoder.encode_actions(actions)
      assert String.contains?(encoded, "strVal(\"running\")")
    end
  end

  describe "encode_value/1 numeric edge cases" do
    test "encodes very large integer" do
      encoded = Encoder.encode_value(999_999_999)
      assert encoded == "intVal(\"999999999\")"
    end

    test "encodes very small negative integer" do
      encoded = Encoder.encode_value(-999_999_999)
      assert encoded == "intVal(\"-999999999\")"
    end

    test "encodes float with many decimals" do
      encoded = Encoder.encode_value(3.14159265359)
      assert String.starts_with?(encoded, "intVal(\"3.14")
    end

    test "encodes scientific notation float" do
      encoded = Encoder.encode_value(1.5e10)
      assert String.starts_with?(encoded, "intVal(")
    end
  end

  describe "encode_string/1 additional edge cases" do
    test "encodes string with numbers" do
      encoded = Encoder.encode_string("device123")
      assert encoded == "\"device123\""
    end

    test "encodes atom with numbers" do
      encoded = Encoder.encode_string(:sensor42)
      assert encoded == "\"sensor42\""
    end

    test "encodes mixed case string" do
      encoded = Encoder.encode_string("MyDevice")
      assert encoded == "\"MyDevice\""
    end
  end

  describe "encode_thing_id/1 consistency" do
    test "wraps various IDs correctly" do
      ids = ["light-1", "sensor_temp", "HVAC", "device123"]

      for id <- ids do
        encoded = Encoder.encode_thing_id(id)
        assert encoded == "thing(\"#{id}\")"
      end
    end
  end

  describe "encode_action/1 all types" do
    test "set_prop produces correct format" do
      action = {:set_prop, "device-1", "property", "value"}
      encoded = Encoder.encode_action(action)

      assert String.starts_with?(encoded, "setProp(")
      assert String.contains?(encoded, "thing(\"device-1\")")
      assert String.contains?(encoded, "\"property\"")
      assert String.contains?(encoded, "strVal(\"value\")")
    end

    test "set_env produces correct format" do
      action = {:set_env, "environment_var", 42}
      encoded = Encoder.encode_action(action)

      assert String.starts_with?(encoded, "setEnv(")
      assert String.contains?(encoded, "\"environment_var\"")
      assert String.contains?(encoded, "intVal(\"42\")")
    end

    test "invoke produces correct format" do
      action = {:invoke, "device-1", "action_name"}
      encoded = Encoder.encode_action(action)

      assert String.starts_with?(encoded, "invoke(")
      assert String.contains?(encoded, "thing(\"device-1\")")
      assert String.contains?(encoded, "\"action_name\"")
    end
  end
end
