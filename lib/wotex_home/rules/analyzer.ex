defmodule WotexHome.Rules.Analyzer do
  @moduledoc """
  Structural checks for a narrow restricted-rule candidate set.

  Passing this analyzer is not admission. Compiler correspondence, invariant
  guards, proof obligations and an atomic activation service remain required.
  """

  alias WotexHome.Rules.{Predicate, Rule}
  alias WotexHome.Semantics.{Capability, Thing}

  @spec restricted([Rule.t()], %{String.t() => Thing.t()}) ::
          {:ok, :structurally_restricted} | {:error, atom()}
  def restricted(rules, things)
      when is_list(rules) and length(rules) > 0 and length(rules) <= 64 and is_map(things) do
    with :ok <- valid_rules(rules),
         :ok <- unique_rule_ids(rules),
         :ok <- capabilities(rules, things),
         :ok <- one_writer_per_domain(rules),
         :ok <- no_feedback(rules) do
      {:ok, :structurally_restricted}
    end
  end

  def restricted(_rules, _things), do: {:error, :invalid_rule_set}

  defp valid_rules(rules) do
    if Enum.all?(rules, &match?(%Rule{}, &1)),
      do: :ok,
      else: {:error, :invalid_rule_set}
  end

  defp unique_rule_ids(rules) do
    ids = Enum.map(rules, & &1.id)
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_rule_id}
  end

  defp capabilities(rules, things) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case rule_capabilities(rule, things) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rule_capabilities(rule, things) do
    {target_id, key, value} = rule.effect

    with {:ok, target} <- fetch_thing(things, target_id),
         {:ok, capability} <- Thing.capability(target, key),
         true <-
           Capability.supports?(capability, "write") and
             capability.risk_class == "ordinary" and Capability.accepts?(capability, value),
         :ok <- readable_inputs(rule, things),
         :ok <- comparable_inputs(rule.predicate, things) do
      :ok
    else
      :error -> {:error, :unsupported_effect}
      false -> {:error, :unsupported_effect}
      {:error, _} = error -> error
    end
  end

  defp readable_inputs(rule, things) do
    Enum.reduce_while(Rule.input_facts(rule), :ok, fn {thing_id, key}, :ok ->
      with {:ok, thing} <- fetch_thing(things, thing_id),
           {:ok, capability} <- Thing.capability(thing, key),
           true <-
             Capability.supports?(capability, "read") and
               capability.risk_class == "ordinary" do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :proof_required_or_unsupported_input}}
      end
    end)
  end

  defp comparable_inputs(%Predicate{op: op, args: {{thing_id, key}, value}}, things)
       when op in [:eq, :gt] do
    with {:ok, thing} <- fetch_thing(things, thing_id),
         {:ok, capability} <- Thing.capability(thing, key),
         true <- Capability.accepts?(capability, value) do
      :ok
    else
      _ -> {:error, :incompatible_predicate}
    end
  end

  defp comparable_inputs(%Predicate{op: :not, args: child}, things),
    do: comparable_inputs(child, things)

  defp comparable_inputs(%Predicate{op: op, args: children}, things) when op in [:all, :any] do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      case comparable_inputs(child, things) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp comparable_inputs(%Predicate{op: :literal_true}, _things), do: :ok

  defp one_writer_per_domain(rules) do
    domains = Enum.map(rules, &Rule.effect_domain/1)

    if length(domains) == length(Enum.uniq(domains)),
      do: :ok,
      else: {:error, :multiple_writers}
  end

  defp no_feedback(rules) do
    effect_domains = MapSet.new(Enum.map(rules, &Rule.effect_domain/1))

    if Enum.any?(rules, fn rule ->
         Enum.any?(Rule.input_facts(rule), fn {thing_id, _key} ->
           MapSet.member?(effect_domains, thing_id)
         end)
       end),
       do: {:error, :feedback_not_supported},
       else: :ok
  end

  defp fetch_thing(things, id) do
    case Map.fetch(things, id) do
      {:ok, %Thing{id: ^id} = thing} -> {:ok, thing}
      _ -> {:error, :unknown_thing}
    end
  end
end
