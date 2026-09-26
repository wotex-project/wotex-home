defmodule WotexHome.Semantics.Value do
  @moduledoc """
  Exact, closed values for the first Home capability subset.

  Fractions use integer parts per million. Colour values do not include power
  or brightness. Construction performs no colour conversion or gamut clipping.
  """

  @enforce_keys [:kind, :data]
  defstruct @enforce_keys

  @type kind :: :boolean | :fraction | :kelvin | :hsv | :xy | :smoke_state
  @type t :: %__MODULE__{kind: kind(), data: term()}

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_value}
  def new(%{"type" => "boolean", "value" => value} = input)
      when is_boolean(value) and map_size(input) == 2,
      do: {:ok, %__MODULE__{kind: :boolean, data: value}}

  def new(%{"type" => "fraction", "ppm" => ppm} = input)
      when is_integer(ppm) and ppm >= 0 and ppm <= 1_000_000 and map_size(input) == 2,
      do: {:ok, %__MODULE__{kind: :fraction, data: ppm}}

  def new(%{"type" => "kelvin", "kelvin" => kelvin} = input)
      when is_integer(kelvin) and kelvin > 0 and map_size(input) == 2,
      do: {:ok, %__MODULE__{kind: :kelvin, data: kelvin}}

  def new(%{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation} = input)
      when is_integer(hue) and hue >= 0 and hue < 360_000 and is_integer(saturation) and
             saturation >= 0 and saturation <= 1_000_000 and map_size(input) == 3,
      do: {:ok, %__MODULE__{kind: :hsv, data: {hue, saturation}}}

  def new(%{"type" => "xy", "x_ppm" => x, "y_ppm" => y} = input)
      when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 and x + y <= 1_000_000 and
             map_size(input) == 3,
      do: {:ok, %__MODULE__{kind: :xy, data: {x, y}}}

  def new(%{"type" => "smoke_state", "state" => state} = input)
      when state in ["clear", "alarm"] and map_size(input) == 2,
      do: {:ok, %__MODULE__{kind: :smoke_state, data: state}}

  def new(_input), do: {:error, :invalid_value}

  @spec in_range?(t(), map()) :: boolean()
  def in_range?(%__MODULE__{kind: :kelvin, data: value}, %{"min" => min, "max" => max}),
    do: value >= min and value <= max

  def in_range?(%__MODULE__{}, %{} = constraints) when map_size(constraints) == 0, do: true
  def in_range?(_value, _constraints), do: false
end
