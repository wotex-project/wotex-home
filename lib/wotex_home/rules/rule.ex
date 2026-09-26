defmodule WotexHome.Rules.Rule do
  @moduledoc """
  Closed draft rule data. Construction does not register a scheduler or admit a
  rule to the controller.
  """

  alias WotexHome.Id
  alias WotexHome.Rules.{Fact, Predicate}
  alias WotexHome.Semantics.Value

  @keys ~w(version id source_revision trigger predicate effect authority_class unknown_policy ownership_ms cooldown_ms causal_budget)
  @max_i64 9_223_372_036_854_775_807
  @max_duration_ms 86_400_000
  @enforce_keys [
    :id,
    :source_revision,
    :trigger,
    :predicate,
    :effect,
    :authority_class,
    :unknown_policy,
    :ownership_ms,
    :cooldown_ms,
    :causal_budget
  ]
  defstruct @enforce_keys

  @type trigger :: {:explicit_request, nil} | {:rising_edge | :falling_edge, Fact.t()}
  @type effect :: {String.t(), String.t(), Value.t()}
  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) when is_map(input) do
    with :ok <- closed(input),
         :ok <- metadata(input),
         {:ok, trigger} <- trigger(input["trigger"]),
         {:ok, predicate} <- Predicate.new(input["predicate"]),
         {:ok, effect} <- effect(input["effect"]) do
      {:ok,
       %__MODULE__{
         id: input["id"],
         source_revision: input["source_revision"],
         trigger: trigger,
         predicate: predicate,
         effect: effect,
         authority_class: :automation,
         unknown_policy: :block,
         ownership_ms: input["ownership_ms"],
         cooldown_ms: input["cooldown_ms"],
         causal_budget: input["causal_budget"]
       }}
    end
  end

  def new(_input), do: {:error, :invalid_rule}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = rule) do
    Id.valid?(rule.id) and nonnegative_i64?(rule.source_revision) and
      valid_trigger?(rule.trigger) and Predicate.valid?(rule.predicate) and
      valid_effect?(rule.effect) and rule.authority_class == :automation and
      rule.unknown_policy == :block and bounded_duration?(rule.ownership_ms, 1) and
      bounded_duration?(rule.cooldown_ms, 0) and
      is_integer(rule.causal_budget) and rule.causal_budget in 1..32
  end

  def valid?(_rule), do: false

  defp valid_trigger?({:explicit_request, nil}), do: true

  defp valid_trigger?({edge, {thing_id, key} = fact})
       when edge in [:rising_edge, :falling_edge],
       do: Fact.new(%{"thing_id" => thing_id, "capability_key" => key}) == {:ok, fact}

  defp valid_trigger?(_trigger), do: false

  defp valid_effect?({target_id, key, %Value{} = value}),
    do: Id.valid?(target_id) and Id.valid?(key) and Value.valid?(value)

  defp valid_effect?(_effect), do: false

  @spec input_facts(t()) :: MapSet.t(Fact.t())
  def input_facts(%__MODULE__{trigger: {:explicit_request, nil}, predicate: predicate}),
    do: Predicate.facts(predicate)

  def input_facts(%__MODULE__{trigger: {_edge, fact}, predicate: predicate}),
    do: MapSet.put(Predicate.facts(predicate), fact)

  @spec effect_domain(t()) :: String.t()
  def effect_domain(%__MODULE__{effect: {target_id, _capability_key, _value}}), do: target_id

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp metadata(input) do
    if input["version"] == 1 and Id.valid?(input["id"]) and
         nonnegative_i64?(input["source_revision"]) and
         input["authority_class"] == "automation" and
         input["unknown_policy"] == "block" and
         bounded_duration?(input["ownership_ms"], 1) and
         bounded_duration?(input["cooldown_ms"], 0) and
         is_integer(input["causal_budget"]) and input["causal_budget"] >= 1 and
         input["causal_budget"] <= 32,
       do: :ok,
       else: {:error, :invalid_rule_metadata}
  end

  defp trigger(%{"kind" => "explicit_request"} = input) when map_size(input) == 1,
    do: {:ok, {:explicit_request, nil}}

  defp trigger(%{"kind" => kind, "fact" => raw_fact} = input)
       when kind in ["rising_edge", "falling_edge"] and map_size(input) == 2 do
    with {:ok, fact} <- Fact.new(raw_fact) do
      {:ok, {if(kind == "rising_edge", do: :rising_edge, else: :falling_edge), fact}}
    end
  end

  defp trigger(_input), do: {:error, :unsupported_trigger}

  defp effect(%{"target_id" => target_id, "capability_key" => key, "value" => raw_value} = input)
       when map_size(input) == 3 do
    with true <- Id.valid?(target_id) and Id.valid?(key),
         {:ok, value} <- Value.new(raw_value) do
      {:ok, {target_id, key, value}}
    else
      false -> {:error, :invalid_effect}
      {:error, _} = error -> error
    end
  end

  defp effect(_input), do: {:error, :invalid_effect}

  defp nonnegative_i64?(value), do: is_integer(value) and value >= 0 and value <= @max_i64

  defp bounded_duration?(value, min),
    do: is_integer(value) and value >= min and value <= @max_duration_ms
end
