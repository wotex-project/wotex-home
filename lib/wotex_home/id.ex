defmodule WotexHome.Id do
  @moduledoc """
  Validates opaque identifiers at the Home boundary without creating atoms.

  IDs are ASCII, 1–128 bytes, and begin with an alphanumeric character.
  They are identifiers, not display labels or device attestations.

  Use `valid?/1` in predicates and `check/1` in constructors that return an
  error tuple. Keep user-facing names in separate fields; accepting an opaque
  ID says nothing about the Thing it names.
  """

  @pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value),
    do: byte_size(value) <= 128 and Regex.match?(@pattern, value)

  def valid?(_value), do: false

  @spec check(term()) :: :ok | {:error, :invalid_id}
  def check(value), do: if(valid?(value), do: :ok, else: {:error, :invalid_id})
end
