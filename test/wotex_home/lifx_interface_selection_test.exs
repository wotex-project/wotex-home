defmodule WotexHome.LifxInterfaceSelectionTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Lifx.InterfaceSelection

  test "one active IPv4 address selects its exact prefix" do
    properties = [
      flags: [:up, :running, :broadcast],
      addr: {192, 168, 86, 149},
      netmask: {255, 255, 255, 0},
      addr: {65152, 0, 0, 0, 0, 0, 0, 1},
      netmask: {65535, 65535, 65535, 65535, 0, 0, 0, 0}
    ]

    assert {:ok, scope} = InterfaceSelection.from_properties(properties)
    assert scope.local == {192, 168, 86, 149}
    assert scope.broadcast == {192, 168, 86, 255}

    assert {:error, :selected_interface_unavailable} =
             InterfaceSelection.from_properties(
               properties ++ [addr: {192, 168, 86, 150}, netmask: {255, 255, 255, 0}]
             )

    assert {:error, :selected_interface_unavailable} =
             InterfaceSelection.from_properties(
               Keyword.put(properties, :flags, [:up, :broadcast])
             )

    assert {:error, :selected_interface_unavailable} =
             InterfaceSelection.from_properties(
               Keyword.put(properties, :netmask, {255, 0, 255, 0})
             )

    assert {:error, :selected_interface_unavailable} = InterfaceSelection.from_properties([123])
  end

  test "an absent named interface cannot start a selected capture" do
    assert {:error, :selected_interface_unavailable} =
             WotexHome.Lifx.CaptureSession.start_link(interface_name: "no-such-interface")
  end
end
