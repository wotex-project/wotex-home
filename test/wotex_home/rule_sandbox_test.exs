defmodule WotexHome.RuleSandboxTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.{Event, Rule, Sandbox}
  alias WotexHome.Semantics.Value

  @fact %{"thing_id" => "light:hall", "capability_key" => "power"}

  @rule %{
    "version" => 1,
    "id" => "rule:1",
    "source_revision" => 1,
    "trigger" => %{"kind" => "rising_edge", "fact" => @fact},
    "predicate" => %{
      "op" => "eq",
      "fact" => @fact,
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
    "causal_budget" => 2
  }

  @edge %{
    "kind" => "edge",
    "root_id" => "root:1",
    "depth" => 0,
    "origin" => "reported",
    "fact" => @fact,
    "before" => false,
    "after" => true
  }

  test "unknown facts and synthetic acknowledgements cannot fire an edge" do
    assert {:ok, rule} = Rule.new(@rule)
    assert {:ok, sandbox} = Sandbox.new([rule])
    assert {:ok, event} = Event.new(@edge)

    assert {:ok, %{proposals: [], suppressed: %{"rule:1" => :predicate_false_or_unknown}},
            ^sandbox} =
             Sandbox.step(sandbox, event, %{}, %{}, 100)

    assert {:ok, synthetic} = Event.new(%{@edge | "origin" => "synthetic_ack"})

    assert {:ok, %{proposals: [], suppressed: %{"rule:1" => :trigger_not_matched}}, ^sandbox} =
             Sandbox.step(sandbox, synthetic, facts(), %{}, 100)

    assert {:ok, uncertain} = Event.new(%{@edge | "before" => "unknown"})

    assert {:ok, %{proposals: []}, ^sandbox} =
             Sandbox.step(sandbox, uncertain, facts(), %{}, 100)
  end

  test "forged rules and events are refused before evaluation" do
    assert {:ok, rule} = Rule.new(@rule)
    assert {:error, :invalid_rule_set} = Sandbox.new([%{rule | ownership_ms: -1}])
    assert {:ok, sandbox} = Sandbox.new([rule])
    assert {:ok, event} = Event.new(@edge)
    refute Event.valid?(%{event | depth: -1})

    assert {:error, :invalid_step} =
             Sandbox.step(sandbox, %{event | depth: -1}, facts(), %{}, 100)

    assert {:error, :invalid_step} =
             Sandbox.step(%{sandbox | root_counts: %{"root:1" => -1}}, event, facts(), %{}, 100)
  end

  test "cooldown, desired no-op and causal budget bound proposals" do
    assert {:ok, rule} = Rule.new(@rule)
    assert {:ok, sandbox} = Sandbox.new([rule])
    assert {:ok, event} = Event.new(@edge)
    assert {:ok, %{proposals: [first]}, sandbox} = Sandbox.step(sandbox, event, facts(), %{}, 100)
    assert first.rule_id == "rule:1"
    assert first.root_id == "root:1"
    assert first.depth == 1

    assert {:ok, %{proposals: [], suppressed: %{"rule:1" => :cooldown}}, ^sandbox} =
             Sandbox.step(sandbox, event, facts(), %{}, 200)

    assert {:ok, on} = Value.new(%{"type" => "boolean", "value" => true})

    assert {:ok, %{proposals: [], suppressed: %{"rule:1" => :desired_noop}}, ^sandbox} =
             Sandbox.step(
               sandbox,
               event,
               facts(),
               %{{"light:desk", "power"} => {:known, on}},
               1_100
             )

    assert {:ok, %{proposals: [_second]}, sandbox} =
             Sandbox.step(sandbox, event, facts(), %{}, 1_100)

    assert {:ok, %{proposals: [], suppressed: %{"rule:1" => :causal_budget_exhausted}}, ^sandbox} =
             Sandbox.step(sandbox, event, facts(), %{}, 2_200)

    assert Sandbox.finish_root(sandbox, "root:1").root_counts == %{}
  end

  test "incompatible proposals conflict without arrival-order winner" do
    assert {:ok, first} = Rule.new(@rule)

    assert {:ok, second} =
             Rule.new(%{
               @rule
               | "id" => "rule:2",
                 "effect" => %{
                   @rule["effect"]
                   | "value" => %{"type" => "boolean", "value" => false}
                 }
             })

    assert {:ok, event} = Event.new(@edge)
    assert {:ok, sandbox} = Sandbox.new([second, first])

    assert {:ok,
            %{
              proposals: [],
              conflicts: [%{target_id: "light:desk", rule_ids: ["rule:1", "rule:2"]}]
            }, ^sandbox} = Sandbox.step(sandbox, event, facts(), %{}, 100)
  end

  test "equivalent effects coalesce deterministically" do
    assert {:ok, first} = Rule.new(@rule)
    assert {:ok, second} = Rule.new(%{@rule | "id" => "rule:2"})
    assert {:ok, event} = Event.new(@edge)
    assert {:ok, sandbox} = Sandbox.new([second, first])

    assert {:ok,
            %{
              proposals: [%{rule_id: "rule:1"}],
              suppressed: %{"rule:2" => :equivalent_effect}
            }, _updated} = Sandbox.step(sandbox, event, facts(), %{}, 100)
  end

  test "one causal root cannot emit more effects than the smallest candidate budget" do
    assert {:ok, first} = Rule.new(%{@rule | "causal_budget" => 1})

    assert {:ok, second} =
             Rule.new(%{
               @rule
               | "id" => "rule:2",
                 "causal_budget" => 1,
                 "effect" => %{@rule["effect"] | "target_id" => "light:kitchen"}
             })

    assert {:ok, sandbox} = Sandbox.new([first, second])
    assert {:ok, event} = Event.new(@edge)

    assert {:ok,
            %{
              proposals: [],
              suppressed: %{
                "rule:1" => :causal_budget_exhausted,
                "rule:2" => :causal_budget_exhausted
              }
            }, ^sandbox} = Sandbox.step(sandbox, event, facts(), %{}, 100)
  end

  defp facts do
    assert {:ok, on} = Value.new(%{"type" => "boolean", "value" => true})
    %{{"light:hall", "power"} => {:known, on}}
  end
end
