defmodule WotexHome.LifxDiscoveryWindowTest do
  use ExUnit.Case, async: true

  alias WotexHome.Discovery.Inventory
  alias WotexHome.Lifx.{DiscoveryWindow, IPv4Scope}

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  test "bounded window coalesces one endpoint and preserves a conflicting identity claim" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)
    assert {:ok, window, query} = DiscoveryWindow.new("en0", "boot:1", scope, 2, 7, 1_000, 2_000)
    assert byte_size(query) == 36
    assert DiscoveryWindow.broadcast(window) == {192, 168, 1, 255}
    reply = service_reply(2, 7)

    assert {:ok, first, window} =
             DiscoveryWindow.accept(window, reply, {192, 168, 1, 10}, 56_700, 1_100)

    assert first.claimed_identifiers == %{"stable_id" => "lifx:d073d5001337"}
    assert first.source_endpoint == "192.168.1.10:56700"

    assert {:ok, :duplicate, window} =
             DiscoveryWindow.accept(window, reply, {192, 168, 1, 10}, 56_700, 1_200)

    assert {:ok, second, window} =
             DiscoveryWindow.accept(window, reply, {192, 168, 1, 11}, 56_700, 1_300)

    assert first.raw_ref != second.raw_ref
    assert length(DiscoveryWindow.candidates(window)) == 2

    assert Enum.any?(Inventory.conflicts(DiscoveryWindow.candidates(window)), fn
             {{"stable_id", "lifx:d073d5001337"}, members} -> length(members) == 2
             _ -> false
           end)
  end

  test "out of window, wrong request, malformed payload and invalid endpoint do not add candidates" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 2}, 24)
    assert {:ok, window, _query} = DiscoveryWindow.new("en0", "boot:1", scope, 2, 7, 1_000, 2_000)
    reply = service_reply(2, 7)

    assert {:error, :window_closed, ^window} =
             DiscoveryWindow.accept(window, reply, {192, 168, 1, 10}, 56_700, 999)

    assert {:error, :window_closed, ^window} =
             DiscoveryWindow.accept(window, reply, {192, 168, 1, 10}, 56_700, 3_001)

    assert {:error, :unmatched_discovery_response, ^window} =
             DiscoveryWindow.accept(window, service_reply(3, 7), {192, 168, 1, 10}, 56_700, 1_100)

    assert {:error, :unmatched_discovery_response, ^window} =
             DiscoveryWindow.accept(window, reply, {239, 1, 2, 3}, 56_700, 1_100)

    assert {:error, :unmatched_discovery_response, ^window} =
             DiscoveryWindow.accept(window, reply, {192, 168, 2, 10}, 56_700, 1_100)

    assert {:error, :invalid_payload, ^window} =
             DiscoveryWindow.accept(
               window,
               service_reply(2, 7, <<1>>),
               {192, 168, 1, 10},
               56_700,
               1_100
             )

    assert DiscoveryWindow.candidates(window) == []
  end

  test "interface scope refuses invalid prefixes and interface endpoints" do
    assert {:error, :invalid_interface_scope} = IPv4Scope.new({192, 168, 1, 0}, 24)
    assert {:error, :invalid_interface_scope} = IPv4Scope.new({192, 168, 1, 255}, 24)
    assert {:error, :invalid_interface_scope} = IPv4Scope.new({192, 168, 1, 2}, 31)
  end

  defp service_reply(source, sequence, payload \\ <<1, 56_700::little-32>>) do
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, @target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, 3::little-16, 0::16, payload::binary>>
  end
end
