defmodule WotexHome.RuleCompilerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias WotexHome.Rules.{Compiler, Event, Predicate, Rule, Sandbox}
  alias WotexHome.Semantics.Value
  alias WotexHome.Verification.LegacyConflict

  @base %{
    "version" => 1,
    "id" => "rule:compile",
    "source_revision" => 7,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 10_000,
    "cooldown_ms" => 1_000,
    "causal_budget" => 4
  }
  @fact {"light:hall", "power"}

  test "closed IR binds every source field and canonical rule ordering" do
    {:ok, rule} = Rule.new(@base)
    {:ok, program} = Compiler.compile([rule])
    assert program.profile == "home-rule-ir-v1"
    assert [entry] = program.entries

    assert entry == %{
             id: rule.id,
             source_revision: 7,
             trigger: {:explicit_request, nil},
             predicate_code: [:literal_true],
             effect: rule.effect,
             authority_class: :automation,
             unknown_policy: :block,
             ownership_ms: 10_000,
             cooldown_ms: 1_000,
             causal_budget: 4
           }

    assert Compiler.valid?(program)
    assert :ok = Compiler.current(program, [rule])

    assert {:ok, %{profile: "home-rule-ir-v1", source_digest: source, ir_digest: ir} = binding} =
             Compiler.binding(program)

    assert map_size(binding) == 3
    assert byte_size(source) == 64 and byte_size(ir) == 64
    refute source == ir
    other = %{rule | id: "rule:other"}
    assert {:ok, first} = Compiler.compile([rule, other])
    assert {:ok, ^first} = Compiler.compile([other, rule])

    for changed <- [
          %{rule | id: "rule:changed"},
          %{rule | source_revision: 8},
          %{rule | ownership_ms: 9_999},
          %{rule | cooldown_ms: 999},
          %{rule | causal_budget: 3},
          %{rule | effect: {"light:desk", "power", value(:boolean, false)}}
        ] do
      assert {:ok, different} = Compiler.compile([changed])
      refute different.source_digest == source
      refute different.ir_digest == ir
      assert {:error, :stale_rule_program} = Compiler.current(program, [changed])
    end
  end

  test "recomputed IR digests do not make forged source bindings current" do
    {:ok, rule} = Rule.new(@base)
    {:ok, program} = Compiler.compile([rule])
    [entry] = program.entries

    for altered <- [
          %{entry | effect: {"light:desk", "power", value(:boolean, false)}},
          %{entry | predicate_code: [:literal_true, :not]},
          %{entry | causal_budget: 32},
          Map.delete(entry, :ownership_ms),
          Map.put(entry, :driver_token, <<1>>)
        ] do
      forged = %{program | entries: [altered]}

      forged = %{
        forged
        | ir_digest: digest({forged.profile, forged.source_digest, forged.entries})
      }

      refute Compiler.valid?(forged)
      assert {:error, :stale_rule_program} = Compiler.current(forged, [rule])
      assert {:error, :invalid_rule_program} = Compiler.binding(forged)
      {:ok, sandbox} = Sandbox.new([rule])
      {:ok, event} = explicit(rule.id, 0)

      assert {:error, :invalid_step} =
               Sandbox.step(%{sandbox | program: forged}, event, %{}, %{}, 0)
    end

    refute Compiler.valid?(Map.put(program, :command, "send"))
  end

  test "compiler refuses forged, noncanonical and unsupported source data" do
    {:ok, rule} = Rule.new(@base)

    for forged <- [
          Map.put(rule, :script, "send"),
          Map.delete(rule, :trigger),
          %{rule | trigger: {:deadline, 42}},
          %{rule | causal_budget: 33},
          %{rule | predicate: Map.put(rule.predicate, :script, "run")},
          %{
            rule
            | effect: {"light:desk", "power", Map.put(value(:boolean, true), :hidden, "code")}
          }
        ] do
      assert {:error, _} = Compiler.compile([forged])
    end

    assert {:error, :invalid_rule_set} = Compiler.compile([rule, rule])
    assert {:error, :invalid_rule_set} = Compiler.compile([])
    assert {:error, :invalid_rule_set} = Compiler.compile([rule | :improper])

    assert {:error, :invalid_rule_set} =
             Compiler.compile(for n <- 1..65, do: %{rule | id: "rule:#{n}"})
  end

  test "predicate depth, instruction count and canonical source bytes are bounded" do
    {:ok, rule} = Rule.new(@base)
    literal = %Predicate{op: :literal_true, args: nil}
    grouped = %Predicate{op: :all, args: List.duplicate(literal, 8)}
    maximum = %Predicate{op: :all, args: List.duplicate(grouped, 7)}
    assert Predicate.valid?(maximum)
    assert {:ok, program} = Compiler.compile([%{rule | predicate: maximum}])
    assert length(hd(program.entries).predicate_code) == 64
    assert {:ok, true} = Compiler.evaluate(hd(program.entries).predicate_code, %{})
    oversized = %Predicate{maximum | args: List.duplicate(grouped, 8)}
    assert {:error, :invalid_rule_set} = Compiler.compile([%{rule | predicate: oversized}])
    deepest = Enum.reduce(1..4, literal, fn _, node -> %Predicate{op: :not, args: node} end)
    assert {:ok, _} = Compiler.compile([%{rule | predicate: deepest}])

    assert {:error, :invalid_rule_set} =
             Compiler.compile([%{rule | predicate: %Predicate{op: :not, args: deepest}}])

    many = for n <- 1..64, do: %{rule | id: "rule:#{n}", predicate: maximum}
    assert {:error, :rule_set_too_large} = Compiler.compile(many)
  end

  test "the postfix machine reproduces all three-valued truth tables" do
    literal = %Predicate{op: :literal_true, args: nil}
    unknown = %Predicate{op: :eq, args: {@fact, value(:boolean, true)}}
    false_node = %Predicate{op: :not, args: literal}
    nodes = [{true, literal}, {false, false_node}, {:unknown, unknown}]

    for {a, left} <- nodes, {b, right} <- nodes, op <- [:all, :any] do
      predicate = %Predicate{op: op, args: [left, right]}
      assert evaluate(predicate, %{}) == reference_combine(op, a, b)
      assert evaluate(predicate, %{}) == Predicate.evaluate(predicate, %{})
      negated = %Predicate{op: :not, args: predicate}
      assert evaluate(negated, %{}) == reference_not(reference_combine(op, a, b))
    end

    assert :unknown == evaluate(%Predicate{op: :not, args: unknown}, %{})
  end

  test "every typed equality preserves exact values, kinds and unknowns" do
    values = [
      value(:boolean, true),
      value(:fraction, 500_000),
      value(:kelvin, 2_700),
      value(:hsv, {359_999, 1_000_000}),
      value(:xy, {1, 999_999}),
      value(:smoke_state, "alarm")
    ]

    for expected <- values,
        actual <- values ++ [value(:boolean, false), value(:fraction, 500_001)] do
      predicate = %Predicate{op: :eq, args: {@fact, expected}}
      facts = %{@fact => {:known, actual}}
      assert evaluate(predicate, facts) == Predicate.evaluate(predicate, facts)

      assert evaluate(predicate, facts) ==
               if(actual.kind == expected.kind, do: actual == expected, else: :unknown)
    end

    for actual <- [:unknown, nil, true, {:known, %Value{kind: :fraction, data: 0.5}}] do
      assert :unknown ==
               evaluate(%Predicate{op: :eq, args: {@fact, value(:boolean, true)}}, %{
                 @fact => actual
               })
    end
  end

  test "integer comparisons keep exact boundaries without rounding or kind conversion" do
    for kind <- [:fraction, :kelvin], threshold <- [1, 500_000, 999_999] do
      predicate = %Predicate{op: :gt, args: {@fact, value(kind, threshold)}}

      for actual <- [threshold - 1, threshold, threshold + 1] do
        facts = %{@fact => {:known, value(kind, actual)}}
        expected = if kind == :kelvin and actual == 0, do: :unknown, else: actual > threshold
        assert evaluate(predicate, facts) == expected
        assert evaluate(predicate, facts) == Predicate.evaluate(predicate, facts)
      end

      assert :unknown == evaluate(predicate, %{@fact => {:known, value(:boolean, true)}})
    end
  end

  test "malformed instructions, stack shape and facts cannot produce truth" do
    for code <- [
          [],
          [:not],
          [:literal_true, :literal_true],
          [:run_elixir],
          [:literal_true, {:all, 2}],
          [:literal_true, {:all, 0}],
          [:literal_true, {:any, 9}],
          [{:gt, @fact, value(:boolean, true)}],
          [{:eq, {"bad id", "power"}, value(:boolean, true)}],
          [{:eq, @fact, Map.put(value(:boolean, true), :script, "run")}],
          List.duplicate(:literal_true, 65),
          [:literal_true | :improper]
        ] do
      assert {:error, :invalid_predicate_program} = Compiler.evaluate(code, %{})
    end

    assert {:error, :invalid_predicate_program} = Compiler.evaluate([:literal_true], :not_a_map)

    assert {:error, :invalid_predicate_program} =
             Compiler.evaluate([:literal_true], Map.new(1..129, &{&1, :unknown}))

    assert {:ok, :unknown} =
             Compiler.evaluate([{:eq, @fact, value(:boolean, true)}], %{
               @fact => {:known, Map.put(value(:boolean, true), :extra, "untrusted")}
             })
  end

  test "compiled triggers reproduce the complete Boolean edge and origin matrix" do
    {:ok, base} = Rule.new(@base)

    for edge <- [:rising_edge, :falling_edge],
        origin <- ["reported", "synthetic_ack"],
        before <- [false, true, "unknown"],
        after_value <- [false, true, "unknown"],
        fact <- [@fact, {"light:other", "power"}] do
      rule = %{base | trigger: {edge, @fact}}
      {:ok, program} = Compiler.compile([rule])
      {:ok, event} = edge(origin, before, after_value, fact, 0)

      expected =
        origin == "reported" and fact == @fact and
          ((edge == :rising_edge and before == false and after_value == true) or
             (edge == :falling_edge and before == true and after_value == false))

      assert Compiler.triggered?(hd(program.entries), event) == expected
    end

    {:ok, program} = Compiler.compile([base])
    {:ok, matched} = explicit(base.id, 0)
    {:ok, other} = explicit("rule:other", 0)
    assert Compiler.triggered?(hd(program.entries), matched)
    refute Compiler.triggered?(hd(program.entries), other)
    refute Compiler.triggered?(hd(program.entries), %{matched | origin: :synthetic_ack})
  end

  test "compiled sandbox transitions correspond to an independent AST reference" do
    {:ok, base} = Rule.new(@base)

    rule = %{
      base
      | trigger: {:rising_edge, @fact},
        predicate: %Predicate{
          op: :not,
          args: %Predicate{op: :eq, args: {@fact, value(:boolean, false)}}
        }
    }

    {:ok, initial} = Sandbox.new([rule])

    events =
      for origin <- ["reported", "synthetic_ack"],
          depth <- [0, 3, 4],
          do: elem(edge(origin, false, true, @fact, depth), 1)

    facts_cases = [
      %{},
      %{@fact => :unknown},
      %{@fact => {:known, value(:boolean, true)}},
      %{@fact => {:known, value(:boolean, false)}},
      %{@fact => {:known, value(:fraction, 1)}}
    ]

    desired_cases = [
      %{},
      %{{"light:desk", "power"} => {:known, value(:boolean, true)}},
      %{{"light:desk", "power"} => {:known, value(:boolean, false)}}
    ]

    for event <- events,
        facts <- facts_cases,
        desired <- desired_cases,
        count <- [0, 3, 4],
        last <- [nil, 100],
        now <- [100, 1_099, 1_100] do
      state = %{
        initial
        | root_counts: %{"root:1" => count},
          last_fired_ms: if(is_nil(last), do: %{}, else: %{rule.id => last})
      }

      reason = reference_reason(rule, event, facts, desired, count, last, now)
      assert {:ok, step, updated} = Sandbox.step(state, event, facts, desired, now)
      assert step.conflicts == []

      if is_nil(reason) do
        assert step.proposals == [
                 %{
                   rule_id: rule.id,
                   target_id: "light:desk",
                   capability_key: "power",
                   value: value(:boolean, true),
                   root_id: "root:1",
                   depth: event.depth + 1,
                   ownership_ms: 10_000
                 }
               ]

        assert updated.root_counts["root:1"] == count + 1
        assert updated.last_fired_ms[rule.id] == now
      else
        assert step.proposals == [] and step.suppressed[rule.id] == reason
        assert updated == state
      end
    end
  end

  test "negative model projection binds source and IR without pretending to model omitted guards" do
    {:ok, rule} = Rule.new(@base)
    {:ok, program} = Compiler.compile([rule])
    assert {:ok, model} = LegacyConflict.compile_model([rule])
    assert model.compiler_profile == program.profile
    assert model.source_digest == program.source_digest and model.ir_digest == program.ir_digest
    assert model.scope == :negative_state_conflict_only
    assert model.model_profile == "bundled-iot-v1/state-conflict-projection-v1"
    assert :cooldown in model.omissions and :ownership in model.omissions
    assert :current_authority in model.omissions and :dispatch_uncertainty in model.omissions
    {:ok, changed} = LegacyConflict.compile_model([%{rule | cooldown_ms: 1_001}])
    assert changed.rules == model.rules
    refute changed.ir_digest == model.ir_digest
    {:ok, changed} = LegacyConflict.compile_model([%{rule | causal_budget: 5}])
    assert changed.rules == model.rules
    refute changed.source_digest == model.source_digest

    assert {:error, :unsupported_model_semantics} =
             LegacyConflict.compile_model([
               %{rule | predicate: %Predicate{op: :not, args: rule.predicate}}
             ])

    assert {:error, :unsupported_model_semantics} =
             LegacyConflict.compile_model([
               %{rule | trigger: {:rising_edge, @fact}}
             ])
  end

  test "generated mixed traces preserve accepted-state history rather than resetting it per step" do
    {:ok, base} = Rule.new(@base)

    rule = %{
      base
      | trigger: {:rising_edge, @fact},
        causal_budget: 2,
        predicate: %Predicate{op: :eq, args: {@fact, value(:boolean, true)}}
    }

    {:ok, sandbox} = Sandbox.new([rule])
    {:ok, reported} = edge("reported", false, true, @fact, 0)
    {:ok, synthetic} = edge("synthetic_ack", false, true, @fact, 0)
    on = %{@fact => {:known, value(:boolean, true)}}
    off = %{@fact => {:known, value(:boolean, false)}}
    desired_on = %{{"light:desk", "power"} => {:known, value(:boolean, true)}}

    trace = [
      {reported, %{}, %{}, 0},
      {reported, on, %{}, 100},
      {reported, on, %{}, 1_099},
      {reported, on, desired_on, 1_100},
      {synthetic, on, %{}, 1_100},
      {reported, off, %{}, 1_100},
      {reported, on, %{}, 1_100},
      {reported, %{}, %{}, 2_100},
      {reported, on, %{}, 2_100}
    ]

    {final, reference} =
      Enum.reduce(trace, {sandbox, %{count: 0, last: nil}}, fn
        {event, facts, desired, now}, {current, reference} ->
          reason =
            reference_reason(rule, event, facts, desired, reference.count, reference.last, now)

          {:ok, step, updated} = Sandbox.step(current, event, facts, desired, now)
          accepted = if is_nil(reason), do: 1, else: 0
          assert length(step.proposals) == accepted
          assert step.suppressed == if(is_nil(reason), do: %{}, else: %{rule.id => reason})

          next = %{
            count: reference.count + accepted,
            last: if(accepted == 1, do: now, else: reference.last)
          }

          assert Map.get(updated.root_counts, "root:1", 0) == next.count
          assert updated.last_fired_ms[rule.id] == next.last
          {updated, next}
      end)

    assert reference == %{count: 2, last: 1_100}
    assert final.root_counts == %{"root:1" => 2}
  end

  defp evaluate(predicate, facts) do
    {:ok, base} = Rule.new(@base)
    {:ok, program} = Compiler.compile([%{base | predicate: predicate}])
    {:ok, truth} = Compiler.evaluate(hd(program.entries).predicate_code, facts)
    truth
  end

  defp reference_reason(rule, event, facts, desired, count, last, now) do
    cond do
      event.origin != :reported or event.kind != :edge or event.before != false or
        event.after_value != true or event.fact != @fact ->
        :trigger_not_matched

      Predicate.evaluate(rule.predicate, facts) != true ->
        :predicate_false_or_unknown

      event.depth >= rule.causal_budget or count >= rule.causal_budget ->
        :causal_budget_exhausted

      is_integer(last) and now - last < rule.cooldown_ms ->
        :cooldown

      desired[{"light:desk", "power"}] == {:known, value(:boolean, true)} ->
        :desired_noop

      true ->
        nil
    end
  end

  defp reference_combine(:all, false, _), do: false
  defp reference_combine(:all, _, false), do: false
  defp reference_combine(:all, :unknown, _), do: :unknown
  defp reference_combine(:all, _, :unknown), do: :unknown
  defp reference_combine(:all, true, true), do: true
  defp reference_combine(:any, true, _), do: true
  defp reference_combine(:any, _, true), do: true
  defp reference_combine(:any, :unknown, _), do: :unknown
  defp reference_combine(:any, _, :unknown), do: :unknown
  defp reference_combine(:any, false, false), do: false
  defp reference_not(true), do: false
  defp reference_not(false), do: true
  defp reference_not(:unknown), do: :unknown
  defp value(kind, data), do: %Value{kind: kind, data: data}

  defp explicit(id, depth),
    do:
      Event.new(%{
        "kind" => "explicit_request",
        "rule_id" => id,
        "root_id" => "root:1",
        "depth" => depth
      })

  defp edge(origin, before, after_value, {thing, key}, depth),
    do:
      Event.new(%{
        "kind" => "edge",
        "origin" => origin,
        "before" => before,
        "after" => after_value,
        "fact" => %{"thing_id" => thing, "capability_key" => key},
        "root_id" => "root:1",
        "depth" => depth
      })

  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)
end
