defmodule ExMaude.IoTTest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.IoT

  doctest ExMaude.IoT

  describe "validate_rule/1" do
    test "accepts valid rule" do
      rule = %{
        id: "test-rule",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: [{:set_prop, "device-1", "power", "on"}]
      }

      assert :ok = IoT.validate_rule(rule)
    end

    test "accepts rule with priority" do
      rule = %{
        id: "test-rule",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: [{:set_prop, "device-1", "power", "on"}],
        priority: 5
      }

      assert :ok = IoT.validate_rule(rule)
    end

    test "returns error for missing id" do
      rule = %{
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: []
      }

      assert {:error, errors} = IoT.validate_rule(rule)
      assert "missing required field: id" in errors
    end

    test "returns error for missing thing_id" do
      rule = %{
        id: "test",
        trigger: {:prop_eq, "state", true},
        actions: []
      }

      assert {:error, errors} = IoT.validate_rule(rule)
      assert "missing required field: thing_id" in errors
    end

    test "returns error for missing trigger" do
      rule = %{
        id: "test",
        thing_id: "device-1",
        actions: []
      }

      assert {:error, errors} = IoT.validate_rule(rule)
      assert "missing required field: trigger" in errors
    end

    test "returns error for missing actions" do
      rule = %{
        id: "test",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true}
      }

      assert {:error, errors} = IoT.validate_rule(rule)
      assert "missing required field: actions" in errors
    end

    test "returns error for non-map input" do
      assert {:error, ["rule must be a map"]} = IoT.validate_rule("not a map")
      assert {:error, ["rule must be a map"]} = IoT.validate_rule(nil)
    end

    test "validates all trigger types" do
      base = %{id: "t", thing_id: "d", actions: []}

      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:prop_eq, "x", true}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:prop_gt, "x", 10}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:prop_lt, "x", 10}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:prop_gte, "x", 10}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:prop_lte, "x", 10}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:env_eq, "temp", 25}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:env_gt, "temp", 25}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:env_lt, "temp", 25}))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, {:always}))
    end

    test "validates compound triggers" do
      base = %{id: "t", thing_id: "d", actions: []}

      and_trigger = {:and, {:prop_eq, "a", true}, {:prop_eq, "b", false}}
      or_trigger = {:or, {:prop_gt, "x", 10}, {:prop_lt, "x", 5}}
      not_trigger = {:not, {:prop_eq, "state", "off"}}

      assert :ok = IoT.validate_rule(Map.put(base, :trigger, and_trigger))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, or_trigger))
      assert :ok = IoT.validate_rule(Map.put(base, :trigger, not_trigger))
    end

    test "validates all action types" do
      base = %{id: "t", thing_id: "d", trigger: {:always}}

      assert :ok = IoT.validate_rule(Map.put(base, :actions, [{:set_prop, "d", "state", "on"}]))
      assert :ok = IoT.validate_rule(Map.put(base, :actions, [{:set_env, "temperature", 22}]))
      assert :ok = IoT.validate_rule(Map.put(base, :actions, [{:invoke, "d", "toggle"}]))
    end
  end

  describe "validate_rules/1" do
    test "accepts list of valid rules" do
      rules = [
        %{id: "r1", thing_id: "d1", trigger: {:always}, actions: []},
        %{id: "r2", thing_id: "d2", trigger: {:always}, actions: []}
      ]

      assert :ok = IoT.validate_rules(rules)
    end

    test "returns errors for invalid rules" do
      rules = [
        %{id: "valid", thing_id: "d1", trigger: {:always}, actions: []},
        %{thing_id: "d2", trigger: {:always}, actions: []}
      ]

      assert {:error, errors} = IoT.validate_rules(rules)
      assert Map.has_key?(errors, "rule_1")
    end

    test "returns empty ok for empty list" do
      assert :ok = IoT.validate_rules([])
    end
  end

  # Integration tests require Maude
  @moduletag :integration

  describe "detect_conflicts/2 integration" do
    test "detects state conflict when two rules target same property", %{maude_available: true} do
      rules = [
        %{
          id: "motion-light",
          thing_id: "light-1",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        },
        %{
          id: "night-mode",
          thing_id: "light-1",
          trigger: {:prop_gt, "time", 2300},
          actions: [{:set_prop, "light-1", "state", "off"}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_conflicts(rules)

      assert conflicts != []

      state_conflicts = Enum.filter(conflicts, &(&1.type == :state_conflict))
      assert state_conflicts != []

      conflict = hd(state_conflicts)
      assert conflict.rule1 in ["motion-light", "night-mode"]
      assert conflict.rule2 in ["motion-light", "night-mode"]
    end

    test "survives property values containing quotes", %{maude_available: true} do
      # Unescaped quotes used to produce invalid Maude terms (parse errors).
      rules = [
        %{
          id: "announce",
          thing_id: "speaker-1",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "speaker-1", "message", ~s(say "welcome home")}],
          priority: 1
        }
      ]

      assert {:ok, conflicts} = IoT.detect_conflicts(rules)
      assert is_list(conflicts)
    end

    test "detects environment conflict with opposing env effects", %{maude_available: true} do
      rules = [
        %{
          id: "cool-room",
          thing_id: "window-1",
          trigger: {:env_gt, "temperature", 25},
          actions: [{:set_env, "window_state", "open"}],
          priority: 1
        },
        %{
          id: "quiet-mode",
          thing_id: "window-1",
          trigger: {:env_gt, "noise", 60},
          actions: [{:set_env, "window_state", "closed"}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_conflicts(rules)

      env_conflicts = Enum.filter(conflicts, &(&1.type == :env_conflict))
      assert env_conflicts != []
    end

    test "detects state cascade when rule output triggers another", %{maude_available: true} do
      rules = [
        %{
          id: "door-light",
          thing_id: "light-1",
          trigger: {:prop_eq, "door", "open"},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        },
        %{
          id: "light-sound",
          thing_id: "light-1",
          trigger: {:prop_eq, "state", "on"},
          actions: [{:set_prop, "speaker-1", "playing", true}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_conflicts(rules)

      cascade_conflicts = Enum.filter(conflicts, &(&1.type == :state_cascade))
      assert cascade_conflicts != []
    end

    test "detects conflicts by action target rather than rule target", %{maude_available: true} do
      rules = [
        %{
          id: "sensor-a",
          thing_id: "sensor-a",
          trigger: {:always},
          actions: [{:set_prop, "shared-light", "state", "on"}]
        },
        %{
          id: "sensor-b",
          thing_id: "sensor-b",
          trigger: {:always},
          actions: [{:set_prop, "shared-light", "state", "off"}]
        }
      ]

      assert {:ok, conflicts} = IoT.detect_conflicts(rules)
      assert Enum.any?(conflicts, &(&1.type == :state_conflict))
    end

    test "detects a numeric cascade in either rule order", %{maude_available: true} do
      source = %{
        id: "source",
        thing_id: "sensor",
        trigger: {:always},
        actions: [{:set_prop, "actuator", "level", 10}]
      }

      sink = %{
        id: "sink",
        thing_id: "actuator",
        trigger: {:prop_gt, "level", 5},
        actions: [{:invoke, "actuator", "notify"}]
      }

      for rules <- [[source, sink], [sink, source]] do
        assert {:ok, conflicts} = IoT.detect_conflicts(rules)
        assert Enum.any?(conflicts, &(&1.type == :state_cascade))
      end
    end

    test "does not cascade between different action and trigger devices", %{
      maude_available: true
    } do
      rules = [
        %{
          id: "source",
          thing_id: "sensor",
          trigger: {:always},
          actions: [{:set_prop, "light-a", "state", "on"}]
        },
        %{
          id: "sink",
          thing_id: "light-b",
          trigger: {:prop_eq, "state", "on"},
          actions: [{:invoke, "light-b", "notify"}]
        }
      ]

      assert {:ok, conflicts} = IoT.detect_conflicts(rules)
      refute Enum.any?(conflicts, &(&1.type == :state_cascade))
    end

    test "validates rules before encoding" do
      assert {:error, %{"rule_0" => _}} = IoT.detect_conflicts([%{}])
      assert {:error, %{"rule_0" => ["rule must be a map"]}} = IoT.detect_conflicts([:bad])
    end

    test "applies and validates the conflict type filter", %{maude_available: true} do
      rules = [
        %{id: "a", thing_id: "d", trigger: {:always}, actions: [{:set_env, "mode", "a"}]},
        %{id: "b", thing_id: "d", trigger: {:always}, actions: [{:set_env, "mode", "b"}]}
      ]

      assert {:ok, conflicts} = IoT.detect_conflicts(rules, conflict_types: [:env_conflict])
      assert conflicts != []
      assert Enum.all?(conflicts, &(&1.type == :env_conflict))

      assert {:error, %ExMaude.Error{type: :validation}} =
               IoT.detect_conflicts(rules, conflict_types: [:invented])
    end

    test "returns empty list when no conflicts exist", %{maude_available: true} do
      rules = [
        %{
          id: "light-rule",
          thing_id: "light-1",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        },
        %{
          id: "thermostat-rule",
          thing_id: "thermostat-1",
          trigger: {:env_gt, "temperature", 25},
          actions: [{:set_prop, "thermostat-1", "mode", "cool"}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_conflicts(rules)
      assert conflicts == []
    end

    test "handles single rule (no conflicts possible)", %{maude_available: true} do
      rules = [
        %{
          id: "single-rule",
          thing_id: "device-1",
          trigger: {:prop_eq, "state", true},
          actions: [{:set_prop, "device-1", "power", "on"}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_conflicts(rules)
      assert conflicts == []
    end

    test "handles empty rule set", %{maude_available: true} do
      {:ok, conflicts} = IoT.detect_conflicts([])
      assert conflicts == []
    end
  end

  describe "detect_state_conflicts/2 integration" do
    test "only returns state conflicts", %{maude_available: true} do
      rules = [
        %{
          id: "r1",
          thing_id: "light-1",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        },
        %{
          id: "r2",
          thing_id: "light-1",
          trigger: {:always},
          actions: [{:set_prop, "light-1", "state", "off"}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_state_conflicts(rules)

      assert Enum.all?(conflicts, fn c ->
               c.type == :state_conflict
             end)
    end
  end

  describe "detect_env_conflicts/2 integration" do
    test "only returns environment conflicts", %{maude_available: true} do
      rules = [
        %{
          id: "r1",
          thing_id: "hvac-1",
          trigger: {:always},
          actions: [{:set_env, "temperature", 20}],
          priority: 1
        },
        %{
          id: "r2",
          thing_id: "hvac-2",
          trigger: {:always},
          actions: [{:set_env, "temperature", 25}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_env_conflicts(rules)

      assert Enum.all?(conflicts, fn c ->
               c.type == :env_conflict
             end)
    end
  end

  describe "detect_cascade_conflicts/2 integration" do
    test "detects rule chains", %{maude_available: true} do
      rules = [
        %{
          id: "trigger-rule",
          thing_id: "sensor-1",
          trigger: {:prop_eq, "detected", true},
          actions: [{:set_prop, "actuator-1", "active", true}],
          priority: 1
        },
        %{
          id: "chained-rule",
          thing_id: "actuator-1",
          trigger: {:prop_eq, "active", true},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        }
      ]

      {:ok, conflicts} = IoT.detect_cascade_conflicts(rules)

      cascade_types = [:state_cascade, :state_env_cascade]

      assert Enum.all?(conflicts, fn c ->
               c.type in cascade_types
             end)
    end
  end

  # Additional unit tests (no Maude required)
  describe "validate_rule/1 additional edge cases" do
    test "accepts rule with empty actions list" do
      rule = %{
        id: "no-action-rule",
        thing_id: "device-1",
        trigger: {:always},
        actions: []
      }

      assert :ok = IoT.validate_rule(rule)
    end

    test "accepts rule with multiple actions" do
      rule = %{
        id: "multi-action-rule",
        thing_id: "device-1",
        trigger: {:always},
        actions: [
          {:set_prop, "device-1", "state", "on"},
          {:set_env, "brightness", 100},
          {:invoke, "device-2", "notify"}
        ]
      }

      assert :ok = IoT.validate_rule(rule)
    end

    test "accepts deeply nested compound triggers" do
      nested_trigger =
        {:and, {:or, {:prop_eq, "a", 1}, {:prop_eq, "b", 2}},
         {:not, {:and, {:env_eq, "c", "x"}, {:prop_gt, "d", 10}}}}

      rule = %{
        id: "nested-rule",
        thing_id: "device-1",
        trigger: nested_trigger,
        actions: []
      }

      assert :ok = IoT.validate_rule(rule)
    end

    test "rejects rule with nil id" do
      rule = %{
        id: nil,
        thing_id: "device-1",
        trigger: {:always},
        actions: []
      }

      assert {:error, errors} = IoT.validate_rule(rule)
      assert "missing required field: id" in errors
    end

    test "rejects rule with nil thing_id" do
      rule = %{
        id: "test",
        thing_id: nil,
        trigger: {:always},
        actions: []
      }

      assert {:error, errors} = IoT.validate_rule(rule)
      assert "missing required field: thing_id" in errors
    end
  end

  describe "validate_rules/1 additional tests" do
    test "returns ok for single valid rule" do
      rules = [
        %{id: "single", thing_id: "d1", trigger: {:always}, actions: []}
      ]

      assert :ok = IoT.validate_rules(rules)
    end

    test "returns all errors for multiple invalid rules" do
      rules = [
        %{thing_id: "d1", trigger: {:always}, actions: []},
        %{id: "valid", thing_id: "d2", trigger: {:always}, actions: []},
        %{id: "missing-trigger", thing_id: "d3", actions: []}
      ]

      assert {:error, errors} = IoT.validate_rules(rules)
      assert Map.has_key?(errors, "rule_0")
      assert Map.has_key?(errors, "missing-trigger")
      refute Map.has_key?(errors, "valid")
    end
  end

  describe "type definitions" do
    test "trigger types are properly typed" do
      triggers = [
        {:prop_eq, "x", true},
        {:prop_gt, "x", 10},
        {:prop_lt, "x", 5},
        {:prop_gte, "x", 10},
        {:prop_lte, "x", 5},
        {:env_eq, "x", "value"},
        {:env_gt, "x", 10},
        {:env_lt, "x", 5},
        {:always},
        {:and, {:always}, {:always}},
        {:or, {:always}, {:always}},
        {:not, {:always}}
      ]

      base = %{id: "t", thing_id: "d", actions: []}

      for trigger <- triggers do
        assert :ok = IoT.validate_rule(Map.put(base, :trigger, trigger))
      end
    end

    test "action types are properly typed" do
      actions = [
        {:set_prop, "device", "prop", "value"},
        {:set_env, "env_prop", "value"},
        {:invoke, "device", "action"}
      ]

      base = %{id: "t", thing_id: "d", trigger: {:always}}

      for action <- actions do
        assert :ok = IoT.validate_rule(Map.put(base, :actions, [action]))
      end
    end
  end

  describe "verify_safety/3 integration" do
    test "reports a counterexample when a bad state is reachable", %{maude_available: true} do
      rules = [
        %{
          id: "r1",
          thing_id: "door",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "door", "state", "error"}],
          priority: 1
        }
      ]

      assert {:error, {:counterexample, [_ | _]}} =
               IoT.verify_safety(rules, {:thing_state, "door", "state", "error"},
                 initial_state: [{:thing_state, "door", "motion", true}]
               )
    end

    test "reports safe when the bad state is unreachable (oscillation)", %{
      maude_available: true
    } do
      rules = [
        %{
          id: "r1",
          thing_id: "light",
          trigger: {:prop_eq, "state", "off"},
          actions: [{:set_prop, "light", "state", "on"}],
          priority: 1
        },
        %{
          id: "r2",
          thing_id: "light",
          trigger: {:prop_eq, "state", "on"},
          actions: [{:set_prop, "light", "state", "off"}],
          priority: 1
        }
      ]

      assert {:ok, :unverified} =
               IoT.verify_safety(rules, {:thing_state, "light", "state", "error"},
                 initial_state: [{:thing_state, "light", "state", "off"}],
                 max_depth: 20
               )
    end

    test "numeric trigger fires when guard holds (battery 15 < 20)", %{maude_available: true} do
      rules = [
        %{
          id: "r1",
          thing_id: "agv",
          trigger: {:prop_lt, "battery", 20},
          actions: [{:set_prop, "agv", "alarm", "on"}],
          priority: 1
        }
      ]

      assert {:error, {:counterexample, _}} =
               IoT.verify_safety(rules, {:thing_state, "agv", "alarm", "on"},
                 initial_state: [{:thing_state, "agv", "battery", 15}]
               )
    end

    test "numeric trigger stays blocked when guard fails (battery 50 < 20)", %{
      maude_available: true
    } do
      rules = [
        %{
          id: "r1",
          thing_id: "agv",
          trigger: {:prop_lt, "battery", 20},
          actions: [{:set_prop, "agv", "alarm", "on"}],
          priority: 1
        }
      ]

      assert {:ok, :unverified} =
               IoT.verify_safety(rules, {:thing_state, "agv", "alarm", "on"},
                 initial_state: [{:thing_state, "agv", "battery", 50}]
               )
    end
  end

  describe "verify_liveness/3 integration" do
    test "reports live when every terminal state reaches the goal", %{maude_available: true} do
      rules = [
        %{
          id: "r1",
          thing_id: "d",
          trigger: {:prop_eq, "state", "off"},
          actions: [{:set_prop, "d", "state", "notified"}],
          priority: 1
        }
      ]

      assert {:ok, :unverified} =
               IoT.verify_liveness(rules, {:thing_state, "d", "state", "notified"},
                 initial_state: [{:thing_state, "d", "state", "off"}]
               )
    end

    test "does not call a depth-limited prefix safe", %{maude_available: true} do
      rules = [
        %{
          id: "step-1",
          thing_id: "d",
          trigger: {:prop_eq, "state", "initial"},
          actions: [{:set_prop, "d", "state", "middle"}]
        },
        %{
          id: "step-2",
          thing_id: "d",
          trigger: {:prop_eq, "state", "middle"},
          actions: [{:set_prop, "d", "state", "bad"}]
        }
      ]

      opts = [initial_state: [{:thing_state, "d", "state", "initial"}]]

      assert {:ok, :unverified} =
               IoT.verify_safety(
                 rules,
                 {:thing_state, "d", "state", "bad"},
                 Keyword.put(opts, :max_depth, 1)
               )

      assert {:error, {:counterexample, [_ | _]}} =
               IoT.verify_safety(
                 rules,
                 {:thing_state, "d", "state", "bad"},
                 Keyword.put(opts, :max_depth, 2)
               )
    end

    test "reports deadlock when a terminal state misses the goal", %{maude_available: true} do
      rules = [
        %{
          id: "r1",
          thing_id: "d",
          trigger: {:prop_eq, "state", "off"},
          actions: [{:set_prop, "d", "state", "stuck"}],
          priority: 1
        }
      ]

      assert {:error, :deadlock_possible} =
               IoT.verify_liveness(rules, {:thing_state, "d", "state", "notified"},
                 initial_state: [{:thing_state, "d", "state", "off"}]
               )
    end
  end

  describe "verification failure discrimination" do
    test "a rule that encodes to invalid Maude surfaces an error, not :unverified",
         %{maude_available: true} do
      # A tuple that no Encoder clause understands raises at encode time;
      # a malformed trigger that *does* encode produces a Maude-level error.
      rules = [
        %{
          id: "broken",
          thing_id: "d",
          # Unknown trigger shape encodes to an unparseable Maude term.
          trigger: {:prop_eq, "state"},
          actions: [{:set_prop, "d", "state", "x"}],
          priority: 1
        }
      ]

      result =
        try do
          IoT.verify_safety(rules, {:thing_state, "d", "state", "x"})
        rescue
          e -> {:raised, e}
        end

      refute result == {:ok, :unverified},
             "an encoding bug must not masquerade as an inconclusive verification"
    end

    test "invalid verification inputs return validation errors" do
      rules = [%{id: "r", thing_id: "d", trigger: {:always}, actions: []}]

      assert {:error, %ExMaude.Error{type: :validation}} =
               IoT.verify_safety(rules, {:thing_state, "d", "state", self()})

      assert {:error, %ExMaude.Error{type: :validation}} =
               IoT.verify_liveness(rules, {:env_state, "goal", true}, max_depth: 0)
    end
  end
end
