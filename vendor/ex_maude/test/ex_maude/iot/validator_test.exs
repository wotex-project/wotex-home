defmodule ExMaude.IoT.ValidatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.IoT.Validator

  doctest ExMaude.IoT.Validator

  describe "validate_rule/1" do
    test "accepts valid rule" do
      rule = %{
        id: "test-rule",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: [{:set_prop, "device-1", "power", "on"}]
      }

      assert :ok = Validator.validate_rule(rule)
    end

    test "accepts rule with priority" do
      rule = %{
        id: "test-rule",
        thing_id: "device-1",
        trigger: {:always},
        actions: [],
        priority: 10
      }

      assert :ok = Validator.validate_rule(rule)
    end

    test "returns error for missing id" do
      rule = %{thing_id: "d1", trigger: {:always}, actions: []}

      assert {:error, errors} = Validator.validate_rule(rule)
      assert "missing required field: id" in errors
    end

    test "returns error for missing thing_id" do
      rule = %{id: "r1", trigger: {:always}, actions: []}

      assert {:error, errors} = Validator.validate_rule(rule)
      assert "missing required field: thing_id" in errors
    end

    test "returns error for missing trigger" do
      rule = %{id: "r1", thing_id: "d1", actions: []}

      assert {:error, errors} = Validator.validate_rule(rule)
      assert "missing required field: trigger" in errors
    end

    test "returns error for missing actions" do
      rule = %{id: "r1", thing_id: "d1", trigger: {:always}}

      assert {:error, errors} = Validator.validate_rule(rule)
      assert "missing required field: actions" in errors
    end

    test "returns error for non-map input" do
      assert {:error, ["rule must be a map"]} = Validator.validate_rule("not a map")
      assert {:error, ["rule must be a map"]} = Validator.validate_rule(nil)
      assert {:error, ["rule must be a map"]} = Validator.validate_rule([])
    end

    test "returns multiple errors for multiple missing fields" do
      rule = %{}

      assert {:error, errors} = Validator.validate_rule(rule)
      assert length(errors) == 4
    end

    test "validates rule field types and priority range" do
      rule = %{id: 1, thing_id: :device, trigger: {:always}, actions: [], priority: -1}

      assert {:error, errors} = Validator.validate_rule(rule)
      assert "id must be a non-empty string" in errors
      assert "thing_id must be a non-empty string" in errors
      assert "priority must be a non-negative integer" in errors
    end

    test "rejects values the encoder cannot represent" do
      rule = %{
        id: "r",
        thing_id: "d",
        trigger: {:prop_eq, "state", %{unsupported: true}},
        actions: [{:set_env, "payload", self()}]
      }

      assert {:error, errors} = Validator.validate_rule(rule)
      assert Enum.count(errors, &(&1 == "value must be a boolean, number, string, or atom")) == 2
    end
  end

  describe "validate_rule/1 trigger validation" do
    setup do
      {:ok, base: %{id: "r", thing_id: "d", actions: []}}
    end

    test "validates prop_eq trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_eq, "x", true}))
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_eq, "x", "value"}))
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_eq, "x", 42}))
    end

    test "validates prop_gt trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_gt, "temp", 25}))
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_gt, "temp", 25.5}))
    end

    test "validates prop_lt trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_lt, "level", 10}))
    end

    test "validates prop_gte trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_gte, "count", 5}))
    end

    test "validates prop_lte trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:prop_lte, "value", 100}))
    end

    test "validates env_eq trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:env_eq, "weather", "sunny"}))
    end

    test "validates env_gt trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:env_gt, "humidity", 60}))
    end

    test "validates env_lt trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:env_lt, "noise", 30}))
    end

    test "validates always trigger", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, {:always}))
    end

    test "validates and trigger", %{base: base} do
      trigger = {:and, {:prop_eq, "a", true}, {:prop_eq, "b", false}}
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, trigger))
    end

    test "validates or trigger", %{base: base} do
      trigger = {:or, {:prop_gt, "x", 10}, {:prop_lt, "x", 5}}
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, trigger))
    end

    test "validates not trigger", %{base: base} do
      trigger = {:not, {:prop_eq, "active", true}}
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, trigger))
    end

    test "validates nested compound triggers", %{base: base} do
      trigger = {:and, {:or, {:prop_eq, "a", 1}, {:prop_eq, "b", 2}}, {:not, {:always}}}
      assert :ok = Validator.validate_rule(Map.put(base, :trigger, trigger))
    end

    test "rejects invalid trigger format", %{base: base} do
      assert {:error, errors} =
               Validator.validate_rule(Map.put(base, :trigger, {:invalid_trigger}))

      assert "invalid trigger format" in errors
    end

    test "rejects prop_gt with non-numeric value", %{base: base} do
      assert {:error, errors} =
               Validator.validate_rule(Map.put(base, :trigger, {:prop_gt, "x", "not a number"}))

      assert "invalid trigger format" in errors
    end

    test "rejects deeply nested triggers beyond max depth", %{base: base} do
      # Build a trigger nested 12 levels deep (max is 10)
      deeply_nested =
        Enum.reduce(1..12, {:always}, fn _, acc ->
          {:not, acc}
        end)

      assert {:error, errors} = Validator.validate_rule(Map.put(base, :trigger, deeply_nested))
      assert Enum.any?(errors, &String.contains?(&1, "depth"))
    end
  end

  describe "validate_rule/1 action validation" do
    setup do
      {:ok, base: %{id: "r", thing_id: "d", trigger: {:always}}}
    end

    test "validates set_prop action", %{base: base} do
      actions = [{:set_prop, "device-1", "state", "on"}]
      assert :ok = Validator.validate_rule(Map.put(base, :actions, actions))
    end

    test "validates set_env action", %{base: base} do
      actions = [{:set_env, "temperature", 22}]
      assert :ok = Validator.validate_rule(Map.put(base, :actions, actions))
    end

    test "validates invoke action", %{base: base} do
      actions = [{:invoke, "device-1", "toggle"}]
      assert :ok = Validator.validate_rule(Map.put(base, :actions, actions))
    end

    test "validates multiple actions", %{base: base} do
      actions = [
        {:set_prop, "d1", "power", "on"},
        {:set_env, "brightness", 80},
        {:invoke, "d2", "refresh"}
      ]

      assert :ok = Validator.validate_rule(Map.put(base, :actions, actions))
    end

    test "validates empty actions list", %{base: base} do
      assert :ok = Validator.validate_rule(Map.put(base, :actions, []))
    end

    test "rejects invalid action format", %{base: base} do
      actions = [{:invalid_action, "x", "y"}]
      assert {:error, errors} = Validator.validate_rule(Map.put(base, :actions, actions))
      assert "invalid action format" in errors
    end

    test "rejects non-list actions", %{base: base} do
      assert {:error, errors} = Validator.validate_rule(Map.put(base, :actions, "not a list"))
      assert "actions must be a list" in errors
    end

    test "rejects set_prop with non-string thing_id", %{base: base} do
      actions = [{:set_prop, 123, "state", "on"}]
      assert {:error, errors} = Validator.validate_rule(Map.put(base, :actions, actions))
      assert "invalid action format" in errors
    end

    test "rejects set_env with non-string property", %{base: base} do
      actions = [{:set_env, 123, "value"}]
      assert {:error, errors} = Validator.validate_rule(Map.put(base, :actions, actions))
      assert "invalid action format" in errors
    end

    test "rejects invalid UTF-8 before encoding", %{base: base} do
      invalid = <<255>>

      assert {:error, _} = Validator.validate_rule(Map.merge(base, %{id: invalid, actions: []}))

      assert {:error, errors} =
               Validator.validate_rule(
                 Map.put(base, :actions, [{:set_prop, "device", "state", invalid}])
               )

      assert "value must be a boolean, number, string, or atom" in errors
    end
  end

  describe "validate_rules/1" do
    test "accepts empty list" do
      assert :ok = Validator.validate_rules([])
    end

    test "accepts list of valid rules" do
      rules = [
        %{id: "r1", thing_id: "d1", trigger: {:always}, actions: []},
        %{id: "r2", thing_id: "d2", trigger: {:always}, actions: []}
      ]

      assert :ok = Validator.validate_rules(rules)
    end

    test "returns errors for invalid rules" do
      rules = [
        %{id: "valid", thing_id: "d1", trigger: {:always}, actions: []},
        %{thing_id: "d2", trigger: {:always}, actions: []},
        %{id: "also-invalid", thing_id: "d3", actions: []}
      ]

      assert {:error, errors} = Validator.validate_rules(rules)

      assert Map.has_key?(errors, "rule_1")
      assert Map.has_key?(errors, "also-invalid")
      refute Map.has_key?(errors, "valid")
    end

    test "uses rule id as error key when available" do
      rules = [
        %{id: "my-rule", thing_id: "d1", actions: []}
      ]

      assert {:error, errors} = Validator.validate_rules(rules)
      assert Map.has_key?(errors, "my-rule")
    end

    test "uses index as error key when id missing" do
      rules = [
        %{thing_id: "d1", trigger: {:always}, actions: []}
      ]

      assert {:error, errors} = Validator.validate_rules(rules)
      assert Map.has_key?(errors, "rule_0")
    end

    test "reports non-map entries without raising" do
      assert {:error, %{"rule_0" => ["rule must be a map"]}} = Validator.validate_rules([:bad])
    end

    test "rejects a non-list batch" do
      assert {:error, %{"rules" => ["rules must be a list"]}} = Validator.validate_rules(%{})
    end
  end

  test "rejects duplicate identities, nested nil, and control characters" do
    rule = %{id: "r", thing_id: "t", trigger: {:always}, actions: []}
    assert {:error, _} = Validator.validate_rules([rule, rule])
    assert {:error, _} = Validator.validate_rule(%{rule | trigger: {:not, nil}})
    assert {:error, _} = Validator.validate_rule(%{rule | id: "bad\nname"})
    nested = Enum.reduce(1..12, {:always}, fn _, p -> {:not, p} end)
    assert {:error, _} = Validator.validate_rule(%{rule | trigger: nested})
  end

  test "nil priority cannot pass validation then encode as a missing argument" do
    assert {:error, _} =
             Validator.validate_rule(%{
               id: "r",
               thing_id: "t",
               trigger: {:always},
               actions: [],
               priority: nil
             })
  end
end
