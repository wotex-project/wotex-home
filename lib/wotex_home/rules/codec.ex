defmodule WotexHome.Rules.Codec do
  @moduledoc """
  Bounded canonical storage for the complete supported closed draft grammar.

  Encoding revalidates structs and preserves rule and predicate-list order.
  Duplicate rule IDs remain representable so review can retain their rejection.
  No serialized rule is an admission or scheduler registration.
  """

  alias WotexHome.Rules.{Predicate, Rule}
  alias WotexHome.Semantics.Value

  @max_bytes 65_536

  def encode(rules) when is_list(rules) and length(rules) in 1..64 do
    if Enum.all?(rules, &Rule.valid?/1) do
      document = JSON.encode!(%{"rules" => Enum.map(rules, &rule_map/1)})

      if byte_size(document) <= @max_bytes,
        do: {:ok, document},
        else: {:error, :rule_set_too_large}
    else
      {:error, :invalid_rule_set}
    end
  end

  def encode(_rules), do: {:error, :invalid_rule_set}

  def decode(document) when is_binary(document) and byte_size(document) <= @max_bytes do
    with {:ok, %{"rules" => inputs} = envelope} <- JSON.decode(document),
         true <- map_size(envelope) == 1 and is_list(inputs) and length(inputs) in 1..64,
         {:ok, rules} <- parse(inputs),
         {:ok, ^document} <- encode(rules) do
      {:ok, rules}
    else
      _ -> {:error, :invalid_rule_document}
    end
  end

  def decode(_document), do: {:error, :invalid_rule_document}

  @doc "Canonical closed predicate source, shared by rules and durable constraints."
  def encode_predicate(%Predicate{} = predicate) do
    if Predicate.valid?(predicate) do
      document = JSON.encode!(predicate_map(predicate))

      if byte_size(document) <= @max_bytes,
        do: {:ok, document},
        else: {:error, :predicate_too_large}
    else
      {:error, :invalid_predicate_document}
    end
  end

  def encode_predicate(_predicate), do: {:error, :invalid_predicate_document}

  def decode_predicate(document)
      when is_binary(document) and byte_size(document) <= @max_bytes do
    with {:ok, input} <- JSON.decode(document),
         {:ok, predicate} <- Predicate.new(input),
         {:ok, ^document} <- encode_predicate(predicate) do
      {:ok, predicate}
    else
      _ -> {:error, :invalid_predicate_document}
    end
  end

  def decode_predicate(_document), do: {:error, :invalid_predicate_document}

  defp parse(inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, rules} ->
      case Rule.new(input) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  defp rule_map(rule) do
    {target_id, key, value} = rule.effect

    %{
      "version" => 1,
      "id" => rule.id,
      "source_revision" => rule.source_revision,
      "trigger" => trigger_map(rule.trigger),
      "predicate" => predicate_map(rule.predicate),
      "effect" => %{
        "target_id" => target_id,
        "capability_key" => key,
        "value" => value_map(value)
      },
      "authority_class" => "automation",
      "unknown_policy" => "block",
      "ownership_ms" => rule.ownership_ms,
      "cooldown_ms" => rule.cooldown_ms,
      "causal_budget" => rule.causal_budget
    }
  end

  defp trigger_map({:explicit_request, nil}), do: %{"kind" => "explicit_request"}
  defp trigger_map({kind, fact}), do: %{"kind" => Atom.to_string(kind), "fact" => fact_map(fact)}

  defp fact_map({id, key}), do: %{"thing_id" => id, "capability_key" => key}

  defp predicate_map(%Predicate{op: :literal_true}), do: %{"op" => "literal_true"}

  defp predicate_map(%Predicate{op: op, args: {fact, value}}) when op in [:eq, :gt],
    do: %{"op" => Atom.to_string(op), "fact" => fact_map(fact), "value" => value_map(value)}

  defp predicate_map(%Predicate{op: :not, args: child}),
    do: %{"op" => "not", "predicate" => predicate_map(child)}

  defp predicate_map(%Predicate{op: op, args: children}) when op in [:all, :any],
    do: %{"op" => Atom.to_string(op), "predicates" => Enum.map(children, &predicate_map/1)}

  defp value_map(%Value{kind: :boolean, data: value}),
    do: %{"type" => "boolean", "value" => value}

  defp value_map(%Value{kind: :fraction, data: value}),
    do: %{"type" => "fraction", "ppm" => value}

  defp value_map(%Value{kind: :kelvin, data: value}), do: %{"type" => "kelvin", "kelvin" => value}

  defp value_map(%Value{kind: :hsv, data: {hue, saturation}}),
    do: %{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation}

  defp value_map(%Value{kind: :xy, data: {x, y}}),
    do: %{"type" => "xy", "x_ppm" => x, "y_ppm" => y}

  defp value_map(%Value{kind: :smoke_state, data: state}),
    do: %{"type" => "smoke_state", "state" => state}
end
