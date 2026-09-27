defmodule WotexHome.RulesRuntimeGateTest do
  use ExUnit.Case, async: true

  alias WotexHome.Rules.{Event, OverrideLease, Rule, RuntimeGate, Sandbox}

  @rule %{
    "version" => 1,
    "id" => "rule:power",
    "source_revision" => 1,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 1_000,
    "cooldown_ms" => 0,
    "causal_budget" => 1
  }

  @lease %{
    "target_id" => "light:desk",
    "operator_id" => "operator:1",
    "authority_epoch" => 1,
    "start_ms" => 100,
    "expires_ms" => 200,
    "basis_revision" => 7
  }

  test "operator override blocks an automation without consuming its root budget" do
    assert {:ok, rule} = Rule.new(@rule)

    assert {:ok, event} =
             Event.new(%{
               "kind" => "explicit_request",
               "rule_id" => "rule:power",
               "root_id" => "root:1",
               "depth" => 0
             })

    assert {:ok, sandbox} = Sandbox.new([rule])
    assert {:ok, lease} = OverrideLease.new(@lease)

    assert {:ok, active_gate} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :allow}, [lease], 1, 199)

    assert active_gate == %{"light:desk" => :operator_override}
    assert {:ok, blocked, unchanged} = Sandbox.step(sandbox, event, %{}, %{}, 199, active_gate)
    assert blocked.proposals == []
    assert blocked.suppressed["rule:power"] == :operator_override
    assert unchanged.root_counts == %{}
    assert unchanged.last_fired_ms == %{}

    assert {:ok, expired_gate} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :allow}, [lease], 1, 200)

    assert expired_gate == %{"light:desk" => :allow}
    assert {:ok, allowed, next} = Sandbox.step(unchanged, event, %{}, %{}, 200, expired_gate)
    assert length(allowed.proposals) == 1
    assert next.root_counts == %{"root:1" => 1}
  end

  test "safety denial precedes a live override and unknown stays blocked" do
    assert {:ok, lease} = OverrideLease.new(@lease)

    assert {:ok, denied} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :deny}, [lease], 1, 150)

    assert denied == %{"light:desk" => :safety_denied}

    assert {:ok, unknown} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :unknown}, [lease], 1, 150)

    assert unknown == %{"light:desk" => :safety_unknown}

    assert {:ok, stale_epoch} =
             RuntimeGate.decisions(["light:desk"], %{"light:desk" => :allow}, [lease], 2, 150)

    assert stale_epoch == %{"light:desk" => :allow}
  end

  test "missing decisions and forged leases fail closed" do
    assert {:ok, rule} = Rule.new(@rule)

    assert {:ok, event} =
             Event.new(%{
               "kind" => "explicit_request",
               "rule_id" => "rule:power",
               "root_id" => "root:2",
               "depth" => 0
             })

    assert {:ok, sandbox} = Sandbox.new([rule])
    assert {:error, :invalid_step} = Sandbox.step(sandbox, event, %{}, %{}, 150, %{})

    assert {:error, :invalid_runtime_gate} =
             RuntimeGate.decisions(["light:desk"], %{}, [], 1, 150)

    assert {:error, :invalid_override_lease} =
             OverrideLease.new(%{@lease | "expires_ms" => 86_400_101})

    assert {:ok, lease} = OverrideLease.new(@lease)
    refute OverrideLease.valid?(%{lease | expires_ms: 100})
    refute OverrideLease.active?(lease, 1, "now")

    assert {:error, :invalid_runtime_gate} =
             RuntimeGate.decisions(
               ["light:desk"],
               %{"light:desk" => :allow},
               [%{lease | expires_ms: 100}],
               1,
               150
             )
  end
end
