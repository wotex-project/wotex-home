defmodule ExMaude.AITest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.AI

  doctest ExMaude.AI

  @fake_maude Path.expand("../support/fake_maude.sh", __DIR__)
  @fake_pool :ai_api_test_pool

  defp start_fake_pool do
    start_supervised!(
      ExMaude.Pool.child_spec(
        name: @fake_pool,
        worker_module: ExMaude.Backend.Port,
        maude_path: @fake_maude,
        use_pty: false,
        pool_size: 1,
        pool_max_overflow: 0
      )
    )

    @fake_pool
  end

  describe "validate_rule/1 (delegate)" do
    test "passes through to validator" do
      rule = %{
        id: "r1",
        agent_id: {"acme", "ag1"},
        trigger: {:always},
        invocations: []
      }

      assert :ok = AI.validate_rule(rule)
    end

    test "surfaces validator errors" do
      assert {:error, _} = AI.validate_rule(%{})
    end
  end

  describe "validate_rules/1 (delegate)" do
    test "returns ok for valid set" do
      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      ]

      assert :ok = AI.validate_rules(rules)
    end

    test "returns failures map for invalid set" do
      rules = [%{id: "r1"}]
      assert {:error, %{"r1" => _}} = AI.validate_rules(rules)
    end
  end

  describe "conflict detection validation" do
    test "detect_conflicts/2 emits telemetry for validation failures" do
      ref = make_ref()
      test_pid = self()
      handler_id = "ai-api-validation-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ex_maude, :ai, :detect_conflicts, :start],
          [:ex_maude, :ai, :detect_conflicts, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, %{"<index 0>" => ["rule must be a map"]}} = AI.detect_conflicts([:bad])

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start],
                      %{rule_count: 1, system_time: _}, %{template: :ai_rules}}

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :stop],
                      %{duration: duration, conflict_count: 0},
                      %{result: :error, template: :ai_rules}}

      assert is_integer(duration)
    end

    test "validates jurisdictions before loading Maude" do
      rules = [%{id: "r", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}]

      assert {:error, %ExMaude.Error{type: :validation}} =
               AI.detect_conflicts(rules, jurisdictions: [:mars])

      assert {:error, %ExMaude.Error{type: :validation}} =
               AI.detect_single_rule_conflicts(rules, jurisdictions: [:mars])
    end

    test "specialized detectors validate rules before loading Maude" do
      assert {:error, %{"<index 0>" => ["rule must be a map"]}} =
               AI.detect_pair_conflicts([:bad])

      assert {:error, %{"<index 0>" => ["rule must be a map"]}} =
               AI.detect_single_rule_conflicts([:bad])
    end

    test "detectors reject echoed commands as unverified output" do
      pool = start_fake_pool()
      rules = [%{id: "r", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}]

      assert {:error, %ExMaude.Error{type: :parse_error}} = AI.detect_conflicts(rules, pool: pool)

      assert {:error, %ExMaude.Error{type: :parse_error}} =
               AI.detect_pair_conflicts(rules, pool: pool)

      assert {:error, %ExMaude.Error{type: :parse_error}} =
               AI.detect_single_rule_conflicts(rules, pool: pool)
    end
  end

  describe "ai_rules_path/0" do
    test "returns a path under priv/" do
      path = ExMaude.ai_rules_path()
      assert is_binary(path)
      assert String.ends_with?(path, "ai-rules.maude")
    end

    test "the bundled module exists" do
      path = ExMaude.ai_rules_path()
      assert File.exists?(path), "expected ai-rules.maude at #{path}"
    end
  end

  describe "detect_conflicts/2 (integration)" do
    @describetag :integration

    test "no conflicts returns empty list", %{maude_available: true} do
      rules = [
        %{
          id: "harmless",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: []
        }
      ]

      assert {:ok, []} = AI.detect_conflicts(rules)
    end

    test "an empty jurisdiction policy disables sovereignty checking", %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [{:invoke_tool, "search", %{}, "internet_access", :us}]
        }
      ]

      assert {:ok, conflicts} = AI.detect_conflicts(rules)
      refute Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end

    test "validates rules and jurisdiction options before encoding" do
      assert {:error, %{"<index 0>" => ["rule must be a map"]}} = AI.detect_conflicts([:bad])

      rules = [%{id: "r", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}]

      assert {:error, %ExMaude.Error{type: :validation}} =
               AI.detect_conflicts(rules, jurisdictions: [:mars])
    end

    test "detects sovereignty violation when invocation jurisdiction outside allowed",
         %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "search", %{}, "internet_access", :us}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu, :ch])

      assert Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end

    test "allows an EU sub-jurisdiction when EU is allowed", %{maude_available: true} do
      rules = [
        %{
          id: "de-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [{:invoke_tool, "search", %{}, "internet_access", :de}]
        }
      ]

      assert {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu])
      refute Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end

    test "detects approval-gate bypass on high_impact invocation without prior gate",
         %{maude_available: true} do
      rules = [
        %{
          id: "auto-dose",
          agent_id: {"acme", "controller"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "dose", %{}, "high_impact", :eu}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu])

      assert Enum.any?(conflicts, &(&1.type == :approval_gate_bypass))
    end

    test "approval-gate bypass clears when require_approval precedes high_impact",
         %{maude_available: true} do
      rules = [
        %{
          id: "approve-then-dose",
          agent_id: {"acme", "controller"},
          trigger: {:always},
          invocations: [
            {:require_approval, "dosing_high_delta"},
            {:invoke_tool, "dose", %{}, "high_impact", :eu}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu])

      refute Enum.any?(conflicts, &(&1.type == :approval_gate_bypass))
    end

    test "the documented multi-rule example completes without crashing Maude", %{
      maude_available: true
    } do
      rules = [
        %{
          id: "approve-then-dose",
          agent_id: {"acme", "ph-controller"},
          trigger: {:prop_lt, "ph", {:int, 6}},
          invocations: [
            {:require_approval, "dosing_high_delta"},
            {:invoke_tool, "dose_chemical", %{"chemical" => "ph_up", "ml" => 50}, "high_impact",
             :eu}
          ],
          capability_grants: [{:cap, "ph_dosing", "v1"}],
          authority_required: 2,
          priority: 1
        },
        %{
          id: "auto-dose",
          agent_id: {"acme", "ph-controller"},
          trigger: {:prop_lt, "ph", {:int, 5}},
          invocations: [
            {:invoke_tool, "dose_chemical", %{"chemical" => "ph_up", "ml" => 100}, "high_impact",
             :eu}
          ],
          capability_grants: [],
          authority_required: 0,
          priority: 1
        }
      ]

      assert {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu])
      assert Enum.any?(conflicts, &(&1.type == :approval_gate_bypass))
    end
  end

  describe "telemetry" do
    @describetag :integration

    test "emits start and stop events", %{maude_available: true} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "ai-test-#{inspect(ref)}",
        [
          [:ex_maude, :ai, :detect_conflicts, :start],
          [:ex_maude, :ai, :detect_conflicts, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      rules = [
        %{
          id: "r1",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: []
        }
      ]

      {:ok, _} = AI.detect_conflicts(rules)

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start], _,
                      %{template: :ai_rules}},
                     2_000

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :stop], _, metadata},
                     5_000

      assert metadata.template == :ai_rules
      assert metadata.result == :ok

      :telemetry.detach("ai-test-#{inspect(ref)}")
    end

    test "start event measurements include rule_count", %{maude_available: true} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "ai-test-count-#{inspect(ref)}",
        [:ex_maude, :ai, :detect_conflicts, :start],
        fn event, measurements, _, _ ->
          send(test_pid, {ref, event, measurements})
        end,
        nil
      )

      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []},
        %{id: "r2", agent_id: {"a", "c"}, trigger: {:always}, invocations: []},
        %{id: "r3", agent_id: {"a", "d"}, trigger: {:always}, invocations: []}
      ]

      {:ok, _} = AI.detect_conflicts(rules)

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start],
                      %{rule_count: 3, system_time: _}},
                     2_000

      :telemetry.detach("ai-test-count-#{inspect(ref)}")
    end
  end

  describe "detect_pair_conflicts/2 (integration)" do
    @describetag :integration

    test "returns empty list for harmless rule set", %{maude_available: true} do
      rules = [
        %{
          id: "harmless",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: []
        }
      ]

      assert {:ok, []} = AI.detect_pair_conflicts(rules)
    end

    test "loads and executes through the selected named pool", %{
      maude_available: true,
      maude_path: maude_path
    } do
      pool = :ai_named_pool

      start_supervised!(
        ExMaude.Pool.child_spec(
          name: pool,
          maude_path: maude_path,
          pool_size: 1,
          pool_max_overflow: 0
        )
      )

      rules = [
        %{
          id: "named-pool-rule",
          agent_id: {"acme", "agent"},
          trigger: {:always},
          invocations: []
        }
      ]

      assert {:ok, []} =
               AI.detect_pair_conflicts(rules, pool: pool)
    end

    test "skips single-rule sovereignty conflict", %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "search", %{}, "internet_access", :us}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_pair_conflicts(rules)

      refute Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end

    test "detects capability cascades and authority escalation in either order", %{
      maude_available: true
    } do
      grant = %{
        id: "grant",
        agent_id: {"acme", "source"},
        trigger: {:always},
        invocations: [],
        capability_grants: [{:cap, "deploy", "v1"}],
        authority_required: 1
      }

      require = %{
        id: "require",
        agent_id: {"acme", "sink"},
        trigger: {:capability_required, "deploy"},
        invocations: [],
        authority_required: 5
      }

      for rules <- [[grant, require], [require, grant]] do
        assert {:ok, conflicts} = AI.detect_pair_conflicts(rules)
        assert Enum.any?(conflicts, &(&1.type == :agent_loop_cascade))
        assert Enum.any?(conflicts, &(&1.type == :authority_escalation))
      end
    end

    test "handles multi-capability comparisons without overflowing Maude", %{
      maude_available: true
    } do
      rules = [
        %{
          id: "pack-a",
          agent_id: {"acme", "a"},
          trigger: {:always},
          invocations: [],
          capability_grants: [{:cap, "search", "v1"}, {:cap, "read", "v1"}],
          priority: 1
        },
        %{
          id: "pack-b",
          agent_id: {"acme", "b"},
          trigger: {:always},
          invocations: [],
          capability_grants: [{:cap, "search", "v2"}, {:cap, "write", "v1"}],
          priority: 1
        }
      ]

      assert {:ok, conflicts} = AI.detect_pair_conflicts(rules)
      assert Enum.any?(conflicts, &(&1.type == :capability_shadowing))
      assert Enum.any?(conflicts, &(&1.type == :pack_tool_composition_mismatch))
    end

    test "detects conflicting required arguments for the same tool", %{maude_available: true} do
      rules = [
        %{
          id: "call-a",
          agent_id: {"acme", "agent"},
          trigger: {:always},
          invocations: [{:invoke_tool, "deploy", %{"region" => "eu"}, "deploy", :eu}]
        },
        %{
          id: "call-b",
          agent_id: {"acme", "agent"},
          trigger: {:always},
          invocations: [{:invoke_tool, "deploy", %{"region" => "us"}, "deploy", :eu}]
        }
      ]

      assert {:ok, conflicts} = AI.detect_pair_conflicts(rules)
      assert Enum.any?(conflicts, &(&1.type == :tool_call_conflict))
    end
  end

  describe "detect_single_rule_conflicts/2 (integration)" do
    @describetag :integration

    test "returns sovereignty violation when invocation jurisdiction outside allowed",
         %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "search", %{}, "internet_access", :us}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_single_rule_conflicts(rules, jurisdictions: [:eu])
      assert Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end
  end

  describe "telemetry (unit-level, no Maude required)" do
    test "start event fires before any backend call" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "ai-unit-start-#{inspect(ref)}",
        [:ex_maude, :ai, :detect_conflicts, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      # Issue a call. We don't care whether it succeeds — only that the
      # :start event arrives before any potential failure.
      AI.detect_conflicts([
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      ])

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start],
                      %{rule_count: 1, system_time: _}, %{template: :ai_rules}},
                     2_000

      :telemetry.detach("ai-unit-start-#{inspect(ref)}")
    end
  end

  @tag :integration
  test "compound capability requirements reach authority and cascade detectors" do
    for operator <- [:and, :or], granted <- ["first", "second"] do
      grant = %{
        id: "grant",
        agent_id: {"tenant", "producer"},
        trigger: {:always},
        invocations: [],
        capability_grants: [{:cap, granted, "v1"}],
        authority_required: 0
      }

      use = %{
        id: "use",
        agent_id: {"tenant", "consumer"},
        invocations: [],
        authority_required: 5,
        trigger: {operator, {:capability_required, "first"}, {:capability_required, "second"}}
      }

      assert {:ok, conflicts} = AI.detect_pair_conflicts([grant, use])
      edges = Enum.map(conflicts, &{&1.type, &1.rule1, &1.rule2})
      assert {:authority_escalation, "grant", "use"} in edges
      assert {:agent_loop_cascade, "grant", "use"} in edges

      assert {:ok, []} =
               AI.detect_pair_conflicts([grant, %{use | agent_id: {"other", "consumer"}}])
    end
  end
end
