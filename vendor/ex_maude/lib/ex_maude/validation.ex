defmodule ExMaude.Validation do
  @moduledoc false

  @doc false
  @spec string?(term()) :: boolean()
  def string?(value) when is_binary(value),
    do: String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, value)

  def string?(_), do: false

  @doc false
  @spec proper_list?(term()) :: boolean()
  def proper_list?(value) when is_list(value) and is_integer(length(value)), do: true
  def proper_list?(_), do: false

  @doc false
  @spec list_count(term()) :: non_neg_integer()
  def list_count(value) when is_list(value) and is_integer(length(value)), do: length(value)
  def list_count(_), do: 0

  @doc false
  @spec duplicate_ids([term()]) :: map()
  def duplicate_ids(rules) do
    rules
    |> Enum.flat_map(fn
      %{id: id} when is_binary(id) -> [id]
      _ -> []
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count > 1 end)
    |> Map.new(fn {id, _} -> {id, ["rule ids must be unique"]} end)
  end
end
