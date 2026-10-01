defmodule WotexHome.Rules.Compiler do
  @moduledoc """
  Closed, source-bound Home rule IR and its three-valued predicate machine.

  Compilation keeps every supported trigger, exact typed effect, authority,
  unknown policy, ownership, cooldown and causal bound. Predicates become a
  bounded postfix program; they never become Elixir or native checker source.
  Source and IR commitments identify different artifacts. Neither is admission.

  `current/2` regenerates the complete IR from the source rather than trusting a
  digest on a supplied struct. The draft sandbox uses this same IR. A checker
  must state its own supported model and omissions instead of silently dropping
  Home fields. This module owns no state, scheduler, credentials or device I/O.
  """

  alias WotexHome.Rules.{Codec, Event, Predicate, Rule}
  alias WotexHome.Semantics.Value

  @profile "home-rule-ir-v1"
  @enforce_keys [:profile, :sources, :entries, :source_digest, :ir_digest]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec compile([Rule.t()]) :: {:ok, t()} | {:error, atom()}
  def compile(rules) when is_list(rules) and length(rules) in 1..64 do
    with true <- Enum.all?(rules, &Rule.valid?/1),
         true <- Enum.uniq_by(rules, & &1.id) == rules,
         sources = Enum.sort_by(rules, & &1.id),
         {:ok, document} <- Codec.encode(sources),
         {:ok, ^sources} <- Codec.decode(document) do
      entries = Enum.map(sources, &entry/1)
      source_digest = digest({@profile, document})

      {:ok,
       %__MODULE__{
         profile: @profile,
         sources: sources,
         entries: entries,
         source_digest: source_digest,
         ir_digest: digest({@profile, source_digest, entries})
       }}
    else
      false -> {:error, :invalid_rule_set}
      {:ok, _noncanonical_source} -> {:error, :invalid_rule_set}
      error -> error
    end
  end

  def compile(_rules), do: {:error, :invalid_rule_set}

  @doc "Compile a standalone closed constraint with the exact rule predicate machine."
  def compile_predicate(document) do
    with {:ok, predicate} <- Codec.decode_predicate(document) do
      profile = "home-predicate-ir-v1"
      instructions = code(predicate)
      facts = predicate |> Predicate.facts() |> Enum.sort()
      source_digest = digest({profile, document})

      {:ok,
       %{
         profile: profile,
         source_document: document,
         instructions: instructions,
         facts: facts,
         source_digest: source_digest,
         ir_digest: digest({profile, source_digest, instructions, facts})
       }}
    end
  end

  @doc "A closed identity summary, never qualification or command authority."
  def binding(%__MODULE__{} = program) do
    if valid?(program),
      do: {:ok, Map.take(program, [:profile, :source_digest, :ir_digest])},
      else: {:error, :invalid_rule_program}
  end

  def binding(_program), do: {:error, :invalid_rule_program}

  @doc "Reject forged, stale or incomplete IR, even with recomputed digests."
  def current(%__MODULE__{} = program, rules) do
    case compile(rules) do
      {:ok, ^program} -> :ok
      {:ok, _different} -> {:error, :stale_rule_program}
      error -> error
    end
  end

  def current(_program, _rules), do: {:error, :invalid_rule_program}

  def valid?(%__MODULE__{sources: sources} = program),
    do: current(program, sources) == :ok

  def valid?(_program), do: false

  @doc "Evaluate only closed, bounded instructions; malformed data is not truth."
  @spec evaluate(list(), map()) :: {:ok, Predicate.truth()} | {:error, atom()}
  def evaluate(instructions, facts)
      when is_list(instructions) and length(instructions) in 1..64 and is_map(facts) and
             map_size(facts) <= 128 do
    case Enum.reduce_while(instructions, {:ok, []}, &instruction(&1, &2, facts)) do
      {:ok, [truth]} when truth in [true, false, :unknown] -> {:ok, truth}
      _ -> {:error, :invalid_predicate_program}
    end
  end

  def evaluate(_instructions, _facts), do: {:error, :invalid_predicate_program}

  @doc "Match a compiled trigger, never treating an ACK as a reported edge."
  def triggered?(%{id: id, trigger: {:explicit_request, nil}}, %Event{} = event),
    do: Event.valid?(event) and event.kind == :explicit_request and event.rule_id == id

  def triggered?(%{trigger: {edge, fact}}, %Event{} = event)
      when edge in [:rising_edge, :falling_edge] do
    before = edge == :falling_edge
    after_value = edge == :rising_edge

    Event.valid?(event) and event.kind == :edge and event.origin == :reported and
      event.fact == fact and event.before == before and event.after_value == after_value
  end

  def triggered?(_entry, _event), do: false

  defp entry(rule) do
    %{
      id: rule.id,
      source_revision: rule.source_revision,
      trigger: rule.trigger,
      predicate_code: code(rule.predicate),
      effect: rule.effect,
      authority_class: rule.authority_class,
      unknown_policy: rule.unknown_policy,
      ownership_ms: rule.ownership_ms,
      cooldown_ms: rule.cooldown_ms,
      causal_budget: rule.causal_budget
    }
  end

  defp code(%Predicate{op: :literal_true}), do: [:literal_true]

  defp code(%Predicate{op: op, args: {fact, value}}) when op in [:eq, :gt],
    do: [{op, fact, value}]

  defp code(%Predicate{op: :not, args: child}), do: code(child) ++ [:not]

  defp code(%Predicate{op: op, args: children}) when op in [:all, :any],
    do: Enum.flat_map(children, &code/1) ++ [{op, length(children)}]

  defp instruction(:literal_true, {:ok, stack}, _facts), do: {:cont, {:ok, [true | stack]}}

  defp instruction({op, fact, expected}, {:ok, stack}, facts) when op in [:eq, :gt] do
    if valid_comparison?(op, fact, expected) do
      truth = compare(op, Map.get(facts, fact, :unknown), expected)
      {:cont, {:ok, [truth | stack]}}
    else
      {:halt, :error}
    end
  end

  defp instruction(:not, {:ok, [truth | rest]}, _facts),
    do: {:cont, {:ok, [negate(truth) | rest]}}

  defp instruction({op, count}, {:ok, stack}, _facts)
       when op in [:all, :any] and is_integer(count) and count in 1..8 do
    {values, rest} = Enum.split(stack, count)

    if length(values) == count,
      do: {:cont, {:ok, [combine(op, values) | rest]}},
      else: {:halt, :error}
  end

  defp instruction(_instruction, _state, _facts), do: {:halt, :error}

  defp valid_comparison?(op, fact, %Value{} = value),
    do:
      WotexHome.Rules.Fact.valid?(fact) and closed_value?(value) and
        (op == :eq or value.kind in [:fraction, :kelvin])

  defp valid_comparison?(_op, _fact, _value), do: false

  defp compare(op, {:known, %Value{} = actual}, expected) do
    if closed_value?(actual) and actual.kind == expected.kind do
      case op do
        :eq -> actual == expected
        :gt -> actual.data > expected.data
      end
    else
      :unknown
    end
  end

  defp compare(_op, _actual, _expected), do: :unknown

  defp closed_value?(%Value{} = value), do: map_size(value) == 3 and Value.valid?(value)

  defp negate(true), do: false
  defp negate(false), do: true
  defp negate(:unknown), do: :unknown

  defp combine(:all, values) do
    cond do
      false in values -> false
      :unknown in values -> :unknown
      true -> true
    end
  end

  defp combine(:any, values) do
    cond do
      true in values -> true
      :unknown in values -> :unknown
      true -> false
    end
  end

  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)
end
