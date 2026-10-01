defmodule WotexHome.Permissions do
  @moduledoc """
  The closed Home permission vocabulary, shared by storage and pure policy.

  Validation does not grant authority. An empty set is valid for a trusted
  policy context; provisioning separately requires at least one permission.
  Lists are bounded to the vocabulary size, duplicate-free and proper.
  """

  @permissions [
    "read",
    "control:ordinary",
    "rule:review",
    "enroll:review",
    "qualify:profile",
    "policy:manage"
  ]

  @spec valid?(term()) :: boolean()
  def valid?(permissions), do: valid(permissions, MapSet.new(), length(@permissions))

  defp valid([], _seen, _remaining), do: true

  defp valid([permission | rest], seen, remaining) when remaining > 0 do
    permission in @permissions and not MapSet.member?(seen, permission) and
      valid(rest, MapSet.put(seen, permission), remaining - 1)
  end

  defp valid(_permissions, _seen, _remaining), do: false
end
