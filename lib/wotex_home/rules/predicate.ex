defmodule WotexHome.Rules.Predicate do
  @moduledoc """
  Closed three-valued predicate AST for draft rules.

  Missing and stale facts are supplied as `:unknown`. Negation preserves
  unknown; no absence-to-false conversion is permitted.
  """

  alias WotexHome.Rules.Fact
  alias WotexHome.Semantics.Value

  @enforce_keys [:op, :args]
  defstruct @enforce_keys

  @type truth :: true | false | :unknown
  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) do
    with {:ok, predicate, count} <- parse(input, 0),
         true <- count <= 64 do
      {:ok, predicate}
    else
      false -> {:error, :predicate_too_large}
      {:error, _} = error -> error
    end
  end

  @spec facts(t()) :: MapSet.t(Fact.t())
  def facts(%__MODULE__{op: op, args: {fact, _value}}) when op in [:eq, :gt],
    do: MapSet.new([fact])

  def facts(%__MODULE__{op: :not, args: predicate}), do: facts(predicate)

  def facts(%__MODULE__{op: op, args: children}) when op in [:all, :any],
    do: Enum.reduce(children, MapSet.new(), &MapSet.union(facts(&1), &2))

  def facts(%__MODULE__{op: :literal_true}), do: MapSet.new()

  @spec evaluate(t(), map()) :: truth()
  def evaluate(%__MODULE__{op: :literal_true}, _observations), do: true

  def evaluate(%__MODULE__{op: :eq, args: {fact, expected}}, observations) do
    case Map.get(observations, fact, :unknown) do
      {:known, %Value{} = actual} ->
        if Value.valid?(actual) and actual.kind == expected.kind,
          do: if(actual == expected, do: true, else: false),
          else: :unknown

      _ ->
        :unknown
    end
  end

  def evaluate(%__MODULE__{op: :gt, args: {fact, threshold}}, observations) do
    case Map.get(observations, fact, :unknown) do
      {:known, %Value{kind: kind, data: value}}
      when kind == threshold.kind and kind in [:fraction, :kelvin] and is_integer(value) ->
        if Value.valid?(%Value{kind: kind, data: value}),
          do: if(value > threshold.data, do: true, else: false),
          else: :unknown

      _ ->
        :unknown
    end
  end

  def evaluate(%__MODULE__{op: :not, args: predicate}, observations) do
    case evaluate(predicate, observations) do
      true -> false
      false -> true
      :unknown -> :unknown
    end
  end

  def evaluate(%__MODULE__{op: :all, args: children}, observations) do
    results = Enum.map(children, &evaluate(&1, observations))

    cond do
      false in results -> false
      :unknown in results -> :unknown
      true -> true
    end
  end

  def evaluate(%__MODULE__{op: :any, args: children}, observations) do
    results = Enum.map(children, &evaluate(&1, observations))

    cond do
      true in results -> true
      :unknown in results -> :unknown
      true -> false
    end
  end

  defp parse(_input, depth) when depth > 4, do: {:error, :predicate_too_deep}

  defp parse(%{"op" => "literal_true"} = input, _depth) when map_size(input) == 1,
    do: {:ok, %__MODULE__{op: :literal_true, args: nil}, 1}

  defp parse(%{"op" => op, "fact" => raw_fact, "value" => raw_value} = input, _depth)
       when op in ["eq", "gt"] and map_size(input) == 3 do
    with {:ok, fact} <- Fact.new(raw_fact),
         {:ok, value} <- Value.new(raw_value),
         :ok <- comparable(op, value) do
      {:ok, %__MODULE__{op: if(op == "eq", do: :eq, else: :gt), args: {fact, value}}, 1}
    end
  end

  defp parse(%{"op" => "not", "predicate" => raw} = input, depth)
       when map_size(input) == 2 do
    with {:ok, child, count} <- parse(raw, depth + 1) do
      {:ok, %__MODULE__{op: :not, args: child}, count + 1}
    end
  end

  defp parse(%{"op" => op, "predicates" => raw} = input, depth)
       when op in ["all", "any"] and map_size(input) == 2 and is_list(raw) and
              length(raw) > 0 and length(raw) <= 8 do
    with {:ok, children, count} <- parse_many(raw, depth + 1) do
      {:ok, %__MODULE__{op: if(op == "all", do: :all, else: :any), args: children}, count + 1}
    end
  end

  defp parse(_input, _depth), do: {:error, :unsupported_predicate}

  defp parse_many(raw, depth) do
    Enum.reduce_while(raw, {:ok, [], 0}, fn item, {:ok, children, count} ->
      case parse(item, depth) do
        {:ok, child, child_count} when count + child_count <= 64 ->
          {:cont, {:ok, [child | children], count + child_count}}

        {:ok, _child, _child_count} ->
          {:halt, {:error, :predicate_too_large}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, children, count} -> {:ok, Enum.reverse(children), count}
      error -> error
    end
  end

  defp comparable("eq", _value), do: :ok
  defp comparable("gt", %Value{kind: kind}) when kind in [:fraction, :kelvin], do: :ok
  defp comparable(_op, _value), do: {:error, :unsupported_comparison}
end
