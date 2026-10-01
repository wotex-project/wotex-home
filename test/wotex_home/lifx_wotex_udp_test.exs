defmodule WotexHome.Lifx.WotexUdpTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Lifx.{IPv4Scope, WotexUdp}

  @tag requires_socket: true
  test "selected-address owner exchanges one bounded datagram with an independent peer" do
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 8)
    {:ok, transport} = WotexUdp.open(scope)
    {:ok, peer} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    on_exit(fn ->
      :gen_udp.close(peer)
      WotexUdp.close(transport)
    end)

    {:ok, {{127, 0, 0, 1}, peer_port}} = :inet.sockname(peer)
    {:ok, local} = WotexUdp.local(transport)
    assert local.address == scope.local
    assert local.port > 0

    assert :ok = WotexUdp.send(transport, "127.0.0.1:#{peer_port}", <<1, 2, 3>>)
    assert {:ok, {{127, 0, 0, 1}, source_port, <<1, 2, 3>>}} = :gen_udp.recv(peer, 0, 1_000)
    assert source_port == local.port

    :ok = :gen_udp.send(peer, {127, 0, 0, 1}, local.port, <<4, 5, 6>>)
    assert {:ok, endpoint, <<4, 5, 6>>} = WotexUdp.recv(transport, 1_000)
    assert endpoint == "127.0.0.1:#{peer_port}"

    assert {:error, :out_of_scope} = WotexUdp.send(transport, "192.0.2.5:56700", <<1>>)
    assert {:error, :invalid_endpoint} = WotexUdp.send(transport, "127.0.0.1:056700", <<1>>)

    assert {:error, :invalid_datagram} =
             WotexUdp.send(transport, "127.0.0.1:#{peer_port}", :binary.copy(<<0>>, 1_025))
  end

  test "a selected-prefix broadcast is represented as limited broadcast before send" do
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 27)

    assert {:ok, route} =
             WotexUdp.plan_destination(scope, "127.0.0.31:56700", :discovery)

    assert route.requested_address == {127, 0, 0, 31}
    assert route.effective_address == {255, 255, 255, 255}
    assert route.destination.kind == :broadcast
    assert route.strategy == :limited_broadcast
  end

  test "a valid wider-subnet peer ending in .255 preserves its unicast wire address" do
    {:ok, scope} = IPv4Scope.new({127, 0, 0, 1}, 23)
    assert IPv4Scope.contains_peer?(scope, {127, 0, 0, 255})

    assert {:ok, route} =
             WotexUdp.plan_destination(scope, "127.0.0.255:56700", :unicast)

    assert route.intent == :unicast
    assert route.strategy == :prefix_scoped_unicast_compat
    assert route.requested_address == {127, 0, 0, 255}
    assert route.effective_address == {127, 0, 0, 255}
    assert route.destination.address == {127, 0, 0, 255}
    assert route.destination.kind == :broadcast
  end
end
