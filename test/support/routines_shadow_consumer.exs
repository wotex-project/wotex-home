defmodule RestrictedPortableShadow do
  @moduledoc false

  alias WotexHome.Rules.{Event, Predicate, Rule}
  alias WotexHome.Semantics.{Thing, Value}

  def new(rule, declaration, corpus, profile, limits, compiler_basis) do
    with true <- Rule.valid?(rule),
         true <- narrow?(rule),
         {:ok, thing} <- Thing.new(declaration),
         {target, "power", value} = rule.effect,
         true <- thing.id == target and thing.role == "Light",
         {:ok, capability} <- Thing.capability(thing, "power"),
         true <- capability.risk_class == "ordinary" do
      basis = Enum.at(corpus["bases"], 2)

      source = %{
        "format" => "wotex.routines.source@1",
        "profile" => "bounded-composition@1",
        "id" => rule.id,
        "revision" => Integer.to_string(rule.source_revision),
        "parameters" => %{},
        "bindings" => ["output"],
        "trigger" => %{"kind" => "manual"},
        "condition" => %{"op" => "literal", "value" => true},
        "steps" => %{
          "id" => "power",
          "kind" => "effect",
          "binding" => "output",
          "input" => value.data,
          "completion" => basis["evidence"]["completion"]
        },
        "overlap" => "reject",
        "run_ms" => 1
      }

      context = %{
        "registry" => corpus["registry"],
        "bases" => corpus["bases"],
        "bindings" => %{
          "output" => %{
            "basis" => Map.take(basis, ~w(id version semantic_digest)),
            "thing_id" => "urn:shadow:light",
            "resource_roles" => %{"target" => "urn:shadow:resource"}
          }
        },
        "definitions" => [],
        "arguments" => %{},
        "compiler_basis" => compiler_basis
      }

      with {:ok, program} <- Wotex.Routines.Compiler.compile(source, context, profile, limits) do
        snapshot = %{
          "id" => "snapshot:shadow",
          "membership_generation" => "membership:shadow",
          "active_programs" => [program.data["ir_digest"]],
          "resource_revisions" => %{"urn:shadow:light" => 1, "urn:shadow:resource" => 1},
          "binding_bases" => %{
            "output" => %{
              "profile_digest" => basis["semantic_digest"],
              "source_id" => "source:shadow",
              "source_epoch" => "connection:shadow",
              "source_time_basis" => nil
            }
          },
          "facts" => %{"output" => nil}
        }

        {:ok,
         %{
           rule: rule,
           program: program,
           snapshot: snapshot,
           profile: profile,
           limits: limits,
           run: nil,
           root: nil,
           consumed: false
         }}
      end
    else
      _ -> {:error, :unsupported_shadow_profile}
    end
  end

  def step(state, event, desired, gate, now) do
    target = elem(state.rule.effect, 0)

    if Event.valid?(event) and map_size(event) == 9 and is_map(desired) and is_map(gate) and
         Map.keys(gate) == [target] and
         gate[target] in [:allow, :safety_denied, :safety_unknown, :operator_override] and
         (state.root == nil or state.root == event.root_id) and is_integer(now) and now >= 0 do
      state = %{state | root: event.root_id}

      eligible =
        event.kind == :explicit_request and event.rule_id == state.rule.id and
          event.depth == 0 and gate[target] == :allow and not state.consumed and
          not desired_matches?(desired[{target, "power"}], elem(state.rule.effect, 2))

      if eligible or state.run != nil, do: kernel(state, event, now), else: {:ok, [], state}
    else
      {:error, :invalid_shadow_frame}
    end
  end

  defp kernel(state, event, now) do
    portable = %{
      "kind" => "manual",
      "original" => "shadow:" <> event.root_id,
      "program_digest" => state.program.data["ir_digest"]
    }

    time = %{
      "epoch" => "boot:shadow",
      "elapsed_ms" => now,
      "clock_generation" => "clock:shadow",
      "utc_low_ms" => nil,
      "utc_high_ms" => nil
    }

    with {:ok, result} <-
           Wotex.Routines.Kernel.advance(
             state.program,
             portable,
             state.snapshot,
             time,
             %{"original" => state.run, "busy" => nil, "edge" => nil},
             state.profile,
             state.limits
           ) do
      proposals =
        Enum.map(result["proposals"], fn proposal ->
          true = proposal["thing_id"] == "urn:shadow:light"
          true = proposal["path"] == []
          true = "urn:shadow:light" in proposal["resource_domains"]
          true = proposal["original"] == portable["original"]
          {:ok, value} = Value.new(%{"type" => "boolean", "value" => proposal["input"]})

          %{
            rule_id: state.rule.id,
            target_id: elem(state.rule.effect, 0),
            capability_key: "power",
            value: value,
            root_id: event.root_id,
            depth: 1,
            ownership_ms: 1
          }
        end)

      {:ok, proposals, %{state | run: result["run"], consumed: state.consumed or proposals != []}}
    end
  end

  defp desired_matches?({:known, %Value{} = actual}, expected), do: actual == expected
  defp desired_matches?(_, _), do: false

  defp narrow?(%Rule{
         trigger: {:explicit_request, nil},
         predicate: %Predicate{op: :literal_true, args: nil},
         effect: {_, "power", %Value{kind: :boolean}},
         causal_budget: 1,
         ownership_ms: 1,
         cooldown_ms: 0
       }),
       do: true

  defp narrow?(_), do: false
end

defmodule RoutinesShadowArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.{Event, OverrideLease, Rule, RuntimeGate, Sandbox}
  alias WotexHome.Semantics.Value

  setup_all do
    corpus =
      :wotex_routines
      |> :code.priv_dir()
      |> List.to_string()
      |> Path.join("vectors/wro-01.json")
      |> File.read!()
      |> JSON.decode!()

    {:ok, limits} = Wotex.Routines.Limits.new(corpus["limits"])

    {:ok, profile} =
      Wotex.Routines.Profile.new(%{
        "source_bytes" => 65_536,
        "source_depth" => 32,
        "expanded_nodes" => 64,
        "predicate_nodes" => 64,
        "invocation_depth" => 4,
        "parallel_width" => 4,
        "effects" => 16,
        "waits" => 16,
        "active_definitions" => 64,
        "active_runs" => 64,
        "pending_work" => 64,
        "run_ms" => 86_400_000
      })

    templates =
      Map.new([false, true], fn requested ->
        {:ok, rule} = Rule.new(rule(requested))

        {:ok, shadow} =
          RestrictedPortableShadow.new(
            rule,
            declaration(),
            corpus,
            profile,
            limits,
            System.fetch_env!("HOME_SHADOW_COMPILER_BASIS")
          )

        {requested, {rule, shadow}}
      end)

    %{corpus: corpus, profile: profile, limits: limits, templates: templates}
  end

  test "the finite ordinary-Light proposal corpus agrees with the archive kernel", c do
    cases =
      for requested <- [false, true],
          event_kind <- [:matching, :other, :depth, :reported, :ack],
          desired_kind <- [:unknown, :same, :opposite],
          safety <- [:allow, :deny, :unknown],
          lease_kind <- [:none, :live, :expired, :old_epoch],
          do: {requested, event_kind, desired_kind, safety, lease_kind}

    assert length(cases) == 360

    Enum.each(cases, fn {requested, event_kind, desired_kind, safety, lease_kind} ->
      {rule, shadow} = c.templates[requested]
      {:ok, sandbox} = Sandbox.new([rule])
      event = event(event_kind)
      desired = desired(requested, desired_kind)

      {:ok, gate} =
        RuntimeGate.decisions(
          ["light:shadow"],
          %{"light:shadow" => safety},
          leases(lease_kind),
          1,
          150
        )

      expected_gate =
        cond do
          safety == :deny -> :safety_denied
          safety == :unknown -> :safety_unknown
          lease_kind == :live -> :operator_override
          true -> :allow
        end

      assert gate == %{"light:shadow" => expected_gate}
      {:ok, actual, next} = Sandbox.step(sandbox, event, %{}, desired, 150, gate)

      assert {:ok, portable, portable_next} =
               RestrictedPortableShadow.step(shadow, event, desired, gate, 150)

      assert portable == actual.proposals
      assert actual.conflicts == []

      assert portable != [] ==
               (event_kind == :matching and desired_kind != :same and expected_gate == :allow)

      {:ok, repeat, _} = Sandbox.step(next, event, %{}, desired, 150, gate)

      assert {:ok, portable_repeat, _} =
               RestrictedPortableShadow.step(portable_next, event, desired, gate, 150)

      assert portable_repeat == repeat.proposals
      assert portable_repeat == []
      assert next.root_counts == if(portable == [], do: %{}, else: %{"root:shadow" => 1})
      if portable_next.run, do: assert(portable_next.run["spent"] == [])
    end)
  end

  test "blocked original is released without an invented held receipt or spent root", c do
    {rule, shadow} = c.templates[true]
    {:ok, sandbox} = Sandbox.new([rule])
    event = event(:matching)

    {:ok, blocked_gate} =
      RuntimeGate.decisions(["light:shadow"], %{"light:shadow" => :allow}, leases(:live), 1, 199)

    {:ok, first, retained} = Sandbox.step(sandbox, event, %{}, %{}, 199, blocked_gate)

    assert {:ok, [], shadow} =
             RestrictedPortableShadow.step(shadow, event, %{}, blocked_gate, 199)

    assert first.proposals == []
    assert retained.root_counts == %{}
    assert shadow.run == nil

    {:ok, released_gate} =
      RuntimeGate.decisions(["light:shadow"], %{"light:shadow" => :allow}, leases(:live), 1, 200)

    {:ok, second, consumed} = Sandbox.step(retained, event, %{}, %{}, 200, released_gate)

    assert {:ok, portable, shadow} =
             RestrictedPortableShadow.step(shadow, event, %{}, released_gate, 200)

    assert portable == second.proposals
    assert consumed.root_counts == %{"root:shadow" => 1}
    assert shadow.run["spent"] == []
  end

  test "unsupported/forged source and cross-original trace are explicit refusals", c do
    {rule, shadow} = c.templates[true]

    for changed <- [
          %{rule | causal_budget: 2},
          %{rule | ownership_ms: 2},
          %{rule | cooldown_ms: 1},
          %{rule | source_revision: nil}
        ] do
      assert {:error, :unsupported_shadow_profile} =
               RestrictedPortableShadow.new(
                 changed,
                 declaration(),
                 c.corpus,
                 c.profile,
                 c.limits,
                 System.fetch_env!("HOME_SHADOW_COMPILER_BASIS")
               )
    end

    assert {:error, :invalid_shadow_frame} =
             RestrictedPortableShadow.step(shadow, event(:matching), %{}, %{}, 150)

    assert {:ok, _, next} =
             RestrictedPortableShadow.step(
               shadow,
               event(:matching),
               %{},
               %{"light:shadow" => :allow},
               150
             )

    other = %{event(:matching) | root_id: "root:other"}

    assert {:error, :invalid_shadow_frame} =
             RestrictedPortableShadow.step(next, other, %{}, %{"light:shadow" => :allow}, 150)

    {:ok, sandbox} = Sandbox.new([rule])
    forged = %{sandbox | program: %{sandbox.program | ir_digest: String.duplicate("0", 64)}}

    assert {:error, :invalid_step} =
             Sandbox.step(forged, event(:matching), %{}, %{}, 150, %{"light:shadow" => :allow})

    program = %{
      shadow.program
      | data: put_in(shadow.program.data, ["ir", "steps", "input"], false)
    }

    assert {:error, %Wotex.Routines.Error{code: :stale_or_forged_program}} =
             RestrictedPortableShadow.step(
               %{shadow | program: program},
               event(:matching),
               %{},
               %{"light:shadow" => :allow},
               150
             )
  end

  test "all code is freshly compiled under the consumer and producer libraries remain passive" do
    root = File.cwd!()

    assert File.stat!(root).inode ==
             File.stat!(System.fetch_env!("HOME_SHADOW_CONSUMER_ROOT")).inode

    for module <- [
          Wotex.Routines.Kernel,
          Wotex.Routines.Compiler,
          Wotex.JSON,
          WotexContinuum,
          WotexHome.Rules.Compiler,
          WotexHome.Rules.Sandbox
        ] do
      Code.ensure_loaded!(module)

      assert module
             |> :code.which()
             |> List.to_string()
             |> String.starts_with?(Path.join(root, "_build"))
    end

    assert Application.spec(:wotex_home) == nil

    for app <- [:wotex, :wotex_continuum, :wotex_routines],
        do: assert(Application.spec(app, :mod) in [nil, []])
  end

  defp rule(value),
    do: %{
      "version" => 1,
      "id" => "rule:shadow",
      "source_revision" => 1,
      "trigger" => %{"kind" => "explicit_request"},
      "predicate" => %{"op" => "literal_true"},
      "effect" => %{
        "target_id" => "light:shadow",
        "capability_key" => "power",
        "value" => %{"type" => "boolean", "value" => value}
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => 1,
      "cooldown_ms" => 0,
      "causal_budget" => 1
    }

  defp declaration,
    do: %{
      "id" => "light:shadow",
      "role" => "Light",
      "profile_ref" => "profile:shadow",
      "capabilities" => [
        %{
          "thing_id" => "light:shadow",
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => "profile:shadow",
          "evidence_ref" => "fixture:shadow",
          "freshness_ms" => 5000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    }

  defp desired(_, :unknown), do: %{}

  defp desired(requested, kind) do
    value = if kind == :same, do: requested, else: not requested
    {:ok, value} = Value.new(%{"type" => "boolean", "value" => value})
    %{{"light:shadow", "power"} => {:known, value}}
  end

  defp event(kind) when kind in [:matching, :other, :depth] do
    {:ok, event} =
      Event.new(%{
        "kind" => "explicit_request",
        "root_id" => "root:shadow",
        "rule_id" => if(kind == :other, do: "rule:other", else: "rule:shadow"),
        "depth" => if(kind == :depth, do: 1, else: 0)
      })

    event
  end

  defp event(kind) do
    {:ok, event} =
      Event.new(%{
        "kind" => "edge",
        "root_id" => "root:shadow",
        "depth" => 0,
        "origin" => if(kind == :ack, do: "synthetic_ack", else: "reported"),
        "fact" => %{"thing_id" => "light:shadow", "capability_key" => "power"},
        "before" => false,
        "after" => true
      })

    event
  end

  defp leases(:none), do: []

  defp leases(kind) do
    {:ok, lease} =
      OverrideLease.new(%{
        "target_id" => "light:shadow",
        "operator_id" => "operator:shadow",
        "authority_epoch" => if(kind == :old_epoch, do: 2, else: 1),
        "start_ms" => 100,
        "expires_ms" => if(kind == :expired, do: 150, else: 200),
        "basis_revision" => 1
      })

    [lease]
  end
end
