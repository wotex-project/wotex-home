defmodule WotexHome.Permissions do
  @moduledoc """
  Validates the closed Home permission vocabulary used by storage and pure policy.

  `valid?/1` returns `true` for a proper duplicate-free list of known permission
  strings, bounded to the vocabulary size. Unknown strings, repeated entries
  and improper lists return `false` without creating atoms. The host-transfer
  permission must appear alone, preserving its separate recovery role.

  An empty list is structurally valid for trusted policy context; principal
  provisioning separately requires at least one permission. Validation grants
  no authority and authenticates no credential.
  `WotexHome.Durable.Store` owns current principals, target grants and operation
  permissions.
  """

  @permissions [
    "read",
    "control:ordinary",
    "rule:review",
    "rule:manage",
    "enroll:review",
    "qualify:profile",
    "policy:manage",
    "host:maintain",
    "profile:manage",
    "host:transfer"
  ]

  @spec valid?(term()) :: boolean()
  def valid?(permissions),
    do:
      valid(permissions, MapSet.new(), length(@permissions)) and
        ("host:transfer" not in permissions or permissions == ["host:transfer"])

  defp valid([], _seen, _remaining), do: true

  defp valid([permission | rest], seen, remaining) when remaining > 0 do
    permission in @permissions and not MapSet.member?(seen, permission) and
      valid(rest, MapSet.put(seen, permission), remaining - 1)
  end

  defp valid(_permissions, _seen, _remaining), do: false
end
