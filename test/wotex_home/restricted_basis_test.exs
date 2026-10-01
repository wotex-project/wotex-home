defmodule WotexHome.RestrictedBasisTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.{Compiler, RestrictedBasis, Rule}
  alias WotexHome.RuntimeArtifacts
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:power-on",
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
    "ownership_ms" => 10_000,
    "cooldown_ms" => 0,
    "causal_budget" => 1
  }

  test "one explicit Boolean Light rule receives a digest-bound proposal basis" do
    assert {:ok, rule} = Rule.new(@rule)
    things = registry()

    assert {:ok, basis} = RestrictedBasis.qualify([rule], things)
    assert basis.result == :basis_complete
    assert basis.profile == "explicit-boolean-light-v3"
    assert basis.scope == :proposal_generation_only
    assert :runtime_correspondence in basis.obligations
    assert :pure_gate_precedence in basis.obligations
    assert :blocked_root_preservation in basis.obligations
    assert :closed_source_bound_ir in basis.obligations
    assert :compiler_correspondence in basis.obligations
    assert {:ok, program} = Compiler.compile([rule])
    assert basis.compiler_profile == program.profile
    assert basis.source_digest == program.source_digest
    assert basis.ir_digest == program.ir_digest
    assert byte_size(basis.rule_digest) == 64
    assert byte_size(basis.registry_digest) == 64
    assert byte_size(basis.runtime_digest) == 64
    assert {:ok, ^basis} = RestrictedBasis.qualify([rule], things)
    assert RestrictedBasis.valid?(basis)
    assert :ok = RestrictedBasis.current(basis, [rule], things)

    assert {:ok, expected} =
             RuntimeArtifacts.digest([:wotex_home], "wotex-home.rule-proposal-runtime.v3")

    assert basis.runtime_digest == expected

    assert {:ok, changed} = Rule.new(%{@rule | "source_revision" => 2})
    assert {:ok, changed_basis} = RestrictedBasis.qualify([changed], things)
    refute changed_basis.rule_digest == basis.rule_digest

    assert {:ok, alternate_id} = Rule.new(%{@rule | "id" => "rule:other"})

    assert {:ok, %{result: :basis_complete}} =
             RestrictedBasis.qualify([alternate_id], things)
  end

  test "edge, predicate, extra budget and extra writer remain outside the basis" do
    things = registry()
    assert {:ok, rule} = Rule.new(@rule)

    edge =
      %{
        @rule
        | "trigger" => %{
            "kind" => "rising_edge",
            "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"}
          }
      }

    assert {:ok, edge_rule} = Rule.new(edge)

    assert {:error, _reason} = RestrictedBasis.qualify([edge_rule], things)

    assert {:ok, predicate_rule} =
             Rule.new(%{
               @rule
               | "predicate" => %{
                   "op" => "eq",
                   "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"},
                   "value" => %{"type" => "boolean", "value" => true}
                 }
             })

    assert {:error, _reason} = RestrictedBasis.qualify([predicate_rule], things)

    for field <- ["causal_budget", "cooldown_ms"] do
      assert {:ok, widened} =
               Rule.new(Map.put(@rule, field, if(field == "causal_budget", do: 2, else: 1)))

      assert {:error, :unsupported_restricted_profile} =
               RestrictedBasis.qualify([widened], things)
    end

    assert {:error, :unsupported_restricted_profile} =
             RestrictedBasis.qualify([rule, %{rule | id: "rule:other"}], things)
  end

  test "forged rule and registry cannot obtain a basis" do
    assert {:ok, rule} = Rule.new(@rule)
    things = registry()
    refute match?({:ok, _}, RestrictedBasis.qualify([%{rule | causal_budget: 100}], things))

    refute match?(
             {:ok, _},
             RestrictedBasis.qualify([rule], %{"light:other" => things["light:desk"]})
           )
  end

  test "closed receipts reject relabelled scope, omitted obligations and legacy input" do
    {:ok, rule} = Rule.new(@rule)
    things = registry()
    {:ok, basis} = RestrictedBasis.qualify([rule], things)

    for changed <- [
          %{basis | scope: :admitted},
          %{basis | result: :safe},
          %{basis | profile: "explicit-boolean-light-v1"},
          %{basis | profile: "explicit-boolean-light-v2"},
          %{basis | compiler_profile: "unchecked-ir"},
          Map.delete(basis, :ir_digest),
          %{basis | target_id: ""},
          %{basis | obligations: tl(basis.obligations)},
          %{basis | runtime_digest: "not-a-digest"},
          Map.delete(basis, :basis_digest),
          Map.put(basis, :driver_token, <<1>>)
        ] do
      refute RestrictedBasis.valid?(changed)
      assert {:error, :invalid_proposal_basis} = RestrictedBasis.current(changed, [rule], things)
    end

    assert {:error, :invalid_proposal_basis} = RestrictedBasis.current(nil, [rule], things)
  end

  test "a content-valid but stale receipt is not current input or runtime evidence" do
    {:ok, rule} = Rule.new(@rule)
    things = registry()
    {:ok, basis} = RestrictedBasis.qualify([rule], things)
    {:ok, changed} = Rule.new(%{@rule | "source_revision" => 2})
    assert {:error, :stale_proposal_basis} = RestrictedBasis.current(basis, [changed], things)
    altered = %{basis | runtime_digest: String.duplicate("f", 64)}
    altered = Map.put(altered, :basis_digest, term_digest(Map.delete(altered, :basis_digest)))
    assert RestrictedBasis.valid?(altered)
    assert {:error, :stale_proposal_basis} = RestrictedBasis.current(altered, [rule], things)
    altered = %{basis | ir_digest: String.duplicate("e", 64)}
    altered = Map.put(altered, :basis_digest, term_digest(Map.delete(altered, :basis_digest)))
    assert RestrictedBasis.valid?(altered)
    assert {:error, :stale_proposal_basis} = RestrictedBasis.current(altered, [rule], things)
    declaration = things["light:desk"]
    power = %{declaration.capabilities["power"] | freshness_ms: 4_999}
    revised = %{declaration | capabilities: %{"power" => power}}

    assert {:error, :stale_proposal_basis} =
             RestrictedBasis.current(basis, [rule], %{"light:desk" => revised})
  end

  test "omitted safety, unknown and lease guards and priority inversions fail correspondence" do
    ebin = RestrictedBasis |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    alias WotexHome.Rules.{RestrictedBasis, Rule}
    alias WotexHome.Semantics.Thing
    {:ok, rule} = Rule.new(#{inspect(@rule)})
    {:ok, thing} = Thing.new(%{"id" => "light:desk", "role" => "Light", "profile_ref" => "lifx.old:1",
      "capabilities" => [#{inspect(@power)}]})
    things = %{thing.id => thing}
    {:ok, _} = RestrictedBasis.qualify([rule], things)
    Code.compiler_options(ignore_module_conflict: true)
    mutations = [
      "_ = {invariants, leases, epoch, now}; :allow",
      "_ = {leases, epoch, now}; if invariants[target] == :unknown, do: :safety_unknown, else: :allow",
      "_ = {leases, epoch, now}; case invariants[target] do :deny -> :safety_denied; :unknown -> :safety_unknown; :allow -> :allow end",
      "_ = {epoch, now}; if leases != [], do: :operator_override, else: (case invariants[target] do :deny -> :safety_denied; :unknown -> :safety_unknown; :allow -> :allow end)"
    ]
    for expression <- mutations do
      source = "defmodule WotexHome.Rules.RuntimeGate do; def decisions(targets, invariants, leases, epoch, now) do " <>
        "{:ok, Map.new(targets, fn target -> {target, (" <> expression <> ")} end)}; end; end"
      Code.compile_string(source)
      {:error, :runtime_correspondence_failed} = RestrictedBasis.qualify([rule], things)
      :code.purge(WotexHome.Rules.RuntimeGate)
    end
    IO.puts("mutants rejected")
    """

    assert {"mutants rejected\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  defp term_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp registry do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    %{"light:desk" => thing}
  end
end
