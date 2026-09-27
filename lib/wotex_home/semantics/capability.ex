defmodule WotexHome.Semantics.Capability do
  @moduledoc """
  A qualified capability declaration, not a source of command authority.

  Only explicitly enumerated role/key/value combinations can be constructed.
  Profile and evidence references remain opaque until qualification checks.

  `new/1` accepts a closed declaration and rejects combinations outside the
  current Light and SmokeDetector subset. Use `supports?/2` to ask whether an
  operation is declared and `accepts?/2` to check a typed value against its
  range. Neither function checks the caller's current grant or device state.
  """

  alias WotexHome.Id
  alias WotexHome.Semantics.Value

  @keys ~w(thing_id role key value_kind unit operations risk_class profile_ref evidence_ref freshness_ms constraints extensions)
  @schema %{
    {"Light", "power"} => {"boolean", "none", ["read", "write"], "ordinary"},
    {"Light", "brightness"} => {"fraction", "ppm", ["read", "write"], "ordinary"},
    {"Light", "colour_hsv"} => {"hsv", "mdeg+ppm", ["read", "write"], "ordinary"},
    {"Light", "colour_xy"} => {"xy", "ppm", ["read", "write"], "ordinary"},
    {"Light", "colour_temperature"} => {"kelvin", "K", ["read", "write"], "ordinary"},
    {"SmokeDetector", "smoke_state"} => {"smoke_state", "none", ["read"], "sensitive"},
    {"SmokeDetector", "fault"} => {"boolean", "none", ["read"], "sensitive"},
    {"SmokeDetector", "self_test"} => {"boolean", "none", ["read"], "sensitive"},
    {"SmokeDetector", "battery_fraction"} => {"fraction", "ppm", ["read"], "sensitive"}
  }

  @enforce_keys [
    :thing_id,
    :role,
    :key,
    :value_kind,
    :unit,
    :operations,
    :risk_class,
    :profile_ref,
    :evidence_ref,
    :freshness_ms,
    :constraints,
    :extensions
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(input) when is_map(input) do
    with :ok <- closed(input),
         :ok <- ids(input),
         :ok <- schema(input),
         :ok <- operations(input),
         :ok <- freshness(input),
         :ok <- constraints(input),
         :ok <- extensions(input) do
      {:ok,
       struct!(__MODULE__,
         thing_id: input["thing_id"],
         role: input["role"],
         key: input["key"],
         value_kind: input["value_kind"],
         unit: input["unit"],
         operations: input["operations"],
         risk_class: input["risk_class"],
         profile_ref: input["profile_ref"],
         evidence_ref: input["evidence_ref"],
         freshness_ms: input["freshness_ms"],
         constraints: input["constraints"],
         extensions: input["extensions"]
       )}
    end
  end

  def new(_input), do: {:error, :invalid_capability}

  @spec supports?(t(), String.t()) :: boolean()
  def supports?(%__MODULE__{operations: operations}, operation),
    do: operation in operations

  @spec accepts?(t(), Value.t()) :: boolean()
  def accepts?(%__MODULE__{} = capability, %Value{} = value) do
    Value.valid?(value) and Atom.to_string(value.kind) == capability.value_kind and
      Value.in_range?(value, capability.constraints)
  end

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp ids(input) do
    if Enum.all?(~w(thing_id key profile_ref evidence_ref), &Id.valid?(input[&1])),
      do: :ok,
      else: {:error, :invalid_id}
  end

  defp schema(input) do
    case Map.get(@schema, {input["role"], input["key"]}) do
      {kind, unit, _allowed, risk_class} ->
        if kind == input["value_kind"] and unit == input["unit"] and
             risk_class == input["risk_class"],
           do: :ok,
           else: {:error, :unsupported_capability}

      _ ->
        {:error, :unsupported_capability}
    end
  end

  defp operations(input) do
    {_, _, allowed, _risk_class} = Map.fetch!(@schema, {input["role"], input["key"]})
    selected = input["operations"]

    if is_list(selected) and selected != [] and Enum.uniq(selected) == selected and
         Enum.all?(selected, &(&1 in allowed)),
       do: :ok,
       else: {:error, :invalid_operations}
  end

  defp freshness(%{"freshness_ms" => ms}) when is_integer(ms) and ms > 0 and ms <= 86_400_000,
    do: :ok

  defp freshness(_input), do: {:error, :invalid_freshness}

  defp constraints(%{
         "value_kind" => "kelvin",
         "constraints" => %{"min" => min, "max" => max} = c
       })
       when map_size(c) == 2 and is_integer(min) and is_integer(max) and min > 0 and min <= max and
              max <= 1_000_000,
       do: :ok

  defp constraints(%{"value_kind" => kind, "constraints" => c})
       when kind != "kelvin" and is_map(c) and map_size(c) == 0,
       do: :ok

  defp constraints(_input), do: {:error, :invalid_constraints}

  defp extensions(%{"extensions" => extensions})
       when is_map(extensions) and map_size(extensions) <= 16 do
    if Enum.all?(extensions, fn {key, value} ->
         is_binary(key) and Regex.match?(~r/\A[A-Za-z0-9]+:[A-Za-z0-9._-]+\z/, key) and
           byte_size(key) <= 128 and is_binary(value) and byte_size(value) <= 256
       end),
       do: :ok,
       else: {:error, :invalid_extensions}
  end

  defp extensions(_input), do: {:error, :invalid_extensions}
end
