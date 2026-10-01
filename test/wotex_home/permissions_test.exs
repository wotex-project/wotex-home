defmodule WotexHome.PermissionsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Bitwise
  alias WotexHome.Permissions
  alias WotexHome.Durable.Registry

  @permissions [
    "read",
    "control:ordinary",
    "rule:review",
    "rule:manage",
    "enroll:review",
    "qualify:profile",
    "policy:manage"
  ]

  test "every subset shares the storage vocabulary without inventing grants" do
    for mask <- 0..127 do
      permissions =
        for {permission, bit} <- Enum.with_index(@permissions),
            band(mask, bsl(1, bit)) != 0,
            do: permission

      assert Permissions.valid?(permissions)
      assert Permissions.valid?(Enum.reverse(permissions))

      if permissions == [] do
        assert {:error, :invalid_permissions} = Registry.encode_permissions(permissions)
      else
        assert {:ok, document} = Registry.encode_permissions(permissions)
        assert {:ok, ^permissions} = Registry.decode_permissions(document)
      end
    end
  end

  test "unknown, repeated, oversized and improper permission lists are data errors" do
    for invalid <- [
          nil,
          "control:ordinary",
          %{},
          [:read],
          ["admin"],
          ["read", "read"],
          @permissions ++ ["read"],
          ["read" | "qualify:profile"],
          List.duplicate("read", 100_000)
        ] do
      refute Permissions.valid?(invalid)
      assert {:error, :invalid_permissions} = Registry.encode_permissions(invalid)
    end

    assert {:error, :corrupt_principal} = Registry.decode_permissions("[\"admin\"]")
    assert {:error, :corrupt_principal} = Registry.decode_permissions("[\"read\",\"read\"]")
  end
end
