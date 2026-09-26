defmodule ExMaude.ValidationRegressionTest do
  use ExUnit.Case, async: true

  @rules [
    {ExMaude.IoT, %{id: "r", thing_id: "device", trigger: {:always}, actions: []}},
    {ExMaude.AI, %{id: "r", agent_id: {"tenant", "agent"}, trigger: {:always}, invocations: []}}
  ]

  test "improper rule and nested lists return validation errors" do
    for {domain, rule} <- @rules do
      assert {:error, _} = domain.validate_rules([rule | :invalid])
      assert {:error, _} = domain.detect_conflicts([rule | :invalid])
      assert {:error, _} = domain.validate_rule(%URI{})
    end

    [{_, iot}, {_, ai}] = @rules

    assert {:error, _} =
             ExMaude.IoT.validate_rule(Map.put(iot, :actions, [{:invoke, "d", "a"} | nil]))

    assert {:error, _} =
             ExMaude.AI.validate_rule(Map.put(ai, :invocations, [{:require_approval, "a"} | nil]))

    assert {:error, _} =
             ExMaude.AI.validate_rule(Map.put(ai, :capability_grants, ["cap" | :bad]))

    assert {:error, _} = ExMaude.AI.Validator.validate_jurisdictions([:eu | :bad])

    assert {:error, _} =
             ExMaude.AI.Validator.validate_invocation({:invoke_tool, "t", %URI{}, "cap", :eu})
  end

  test "duplicate identifiers retain the diagnostics of every invalid rule" do
    for {domain, rule} <- @rules do
      first = Map.delete(rule, :trigger)
      second = Map.put(rule, :priority, -1)
      assert {:error, expected_first} = domain.validate_rule(first)
      assert {:error, expected_second} = domain.validate_rule(second)
      assert {:error, errors} = domain.validate_rules([first, second])

      assert errors[rule.id] ==
               List.flatten([expected_first, expected_second, "rule ids must be unique"])
    end
  end

  test "fallback diagnostic keys cannot overwrite errors for an explicit ID" do
    for {domain, rule, key} <- [
          {ExMaude.IoT, elem(hd(@rules), 1), "rule_0"},
          {ExMaude.AI, elem(List.last(@rules), 1), "<index 0>"}
        ] do
      invalid =
        rule
        |> Map.put(:id, key)
        |> Map.put(:priority, -1)

      assert {:error, errors} = domain.validate_rules([%{}, invalid])
      assert "missing required field: id" in errors[key]
      assert "priority must be a non-negative integer" in errors[key]
    end
  end

  test "both domains accept the depth limit and reject the next level" do
    for {domain, rule} <- @rules do
      at_limit = Enum.reduce(1..10, {:always}, fn _, child -> {:not, child} end)
      assert :ok = domain.validate_rule(%{rule | trigger: at_limit})
      assert {:error, _} = domain.validate_rule(%{rule | trigger: {:not, at_limit}})
    end
  end

  test "nil is rejected in either branch of compound triggers" do
    for {domain, rule} <- @rules,
        operator <- [:and, :or],
        trigger <- [
          {operator, nil, {:always}},
          {operator, {:always}, nil}
        ] do
      assert {:error, _} = domain.validate_rule(%{rule | trigger: trigger})
    end
  end

  test "omitted priority uses the default but explicit nil is invalid" do
    for {domain, rule} <- @rules do
      assert :ok = domain.validate_rule(rule)
      assert :ok = domain.validate_rule(Map.put(rule, :priority, 0))
      assert {:error, _} = domain.validate_rule(Map.put(rule, :priority, nil))
    end
  end

  test "nonadjacent duplicate IDs are rejected without rejecting distinct IDs" do
    for {domain, rule} <- @rules do
      second = %{rule | id: "second"}
      assert :ok = domain.validate_rules([rule, second])
      assert {:error, _} = domain.validate_rules([rule, second, rule])
    end
  end

  test "control bytes and malformed UTF-8 cannot become rule identifiers" do
    for {domain, rule} <- @rules, bad <- ["x\0y", "x\ty", "x\ny", "x\ry", <<127>>, <<255>>] do
      assert {:error, _} = domain.validate_rule(%{rule | id: bad})
    end

    for {domain, rule} <- @rules do
      assert :ok = domain.validate_rule(%{rule | id: "räksmörgås"})
    end
  end

  test "argument keys remain valid and distinct after conversion from atoms" do
    invocation = fn args -> {:invoke_tool, "tool", args, "capability", :eu} end
    validator = ExMaude.AI.Validator
    assert :ok = validator.validate_invocation(invocation.(%{x: 1, y: 2}))
    assert {:error, _} = validator.validate_invocation(invocation.(%{:x => 1, "x" => 2}))
    assert {:error, _} = validator.validate_invocation(invocation.(%{"bad\nkey" => 1}))
    assert {:error, _} = validator.validate_invocation(invocation.(%{"bad\nkey": 1}))
  end
end
