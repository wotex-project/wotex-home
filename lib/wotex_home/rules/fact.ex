defmodule WotexHome.Rules.Fact do
  @moduledoc "A bounded reference to one declared Home capability."

  alias WotexHome.Id

  @type t :: {String.t(), String.t()}

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_fact}
  def new(%{"thing_id" => thing_id, "capability_key" => key} = input)
      when map_size(input) == 2 do
    if Id.valid?(thing_id) and Id.valid?(key),
      do: {:ok, {thing_id, key}},
      else: {:error, :invalid_fact}
  end

  def new(_input), do: {:error, :invalid_fact}
end
