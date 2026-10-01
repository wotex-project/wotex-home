defmodule WotexHome.Lifx.WotexUdpRouteTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Bitwise

  alias Wotex.UDP.{Error, Handle}
  alias WotexHome.Lifx.{IPv4Scope, Transport, WotexUdp}

  test "every supported prefix uses one on-link limited-broadcast strategy" do
    for prefix <- 8..30 do
      local = local_for(prefix)
      assert {:ok, scope} = IPv4Scope.new(local, prefix)
      requested = "#{:inet.ntoa(scope.broadcast)}:56700"

      assert {:ok, route} = WotexUdp.plan_destination(scope, requested, :discovery)
      assert route.requested_address == scope.broadcast
      assert route.effective_address == {255, 255, 255, 255}
      assert route.destination.address == {255, 255, 255, 255}
      assert route.destination.port == 56_700
      assert route.destination.kind == :broadcast
      assert route.strategy == :limited_broadcast
    end
  end

  test "limited broadcast may be requested explicitly only for LIFX discovery" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 24)

    assert {:ok, route} =
             WotexUdp.plan_destination(scope, "255.255.255.255:56700", :discovery)

    assert route.requested_address == route.effective_address

    assert {:error, :out_of_scope} =
             WotexUdp.plan_destination(scope, "255.255.255.255:56701", :discovery)

    assert {:error, :out_of_scope} =
             WotexUdp.plan_destination(scope, "255.255.255.255:56700", :unicast)
  end

  test "ordinary in-prefix hosts and advertised service ports are direct unicast" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 25)

    assert {:ok, route} =
             WotexUdp.plan_destination(scope, "192.168.1.100:65535", :unicast)

    assert route.strategy == :direct_unicast
    assert route.requested_address == {192, 168, 1, 100}
    assert route.effective_address == route.requested_address
    assert route.destination.kind == :unicast
    assert route.port == 65_535
  end

  test "scope roles cannot be confused with unicast" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 25)

    for endpoint <- [
          "192.168.1.0:56700",
          "192.168.1.20:56700",
          "192.168.1.127:56701",
          "192.168.1.128:56700",
          "224.0.0.251:5353"
        ] do
      assert {:error, :out_of_scope} =
               WotexUdp.plan_destination(scope, endpoint, :unicast)
    end
  end

  test "a .255 octet is classified from the prefix and keeps a unicast route" do
    assert {:ok, wider} = IPv4Scope.new({192, 168, 0, 20}, 23)
    assert IPv4Scope.contains_peer?(wider, {192, 168, 0, 255})

    assert {:ok, route} =
             WotexUdp.plan_destination(wider, "192.168.0.255:56700", :unicast)

    assert route.intent == :unicast
    assert route.strategy == :prefix_scoped_unicast_compat
    assert route.requested_address == {192, 168, 0, 255}
    assert route.effective_address == route.requested_address
    assert route.destination.address == route.requested_address
    assert route.destination.kind == :broadcast

    assert {:ok, narrower} = IPv4Scope.new({192, 168, 0, 20}, 24)

    assert {:error, :out_of_scope} =
             WotexUdp.plan_destination(narrower, "192.168.0.255:56700", :unicast)

    assert {:ok, discovery} =
             WotexUdp.plan_destination(narrower, "192.168.0.255:56700", :discovery)

    assert discovery.strategy == :limited_broadcast
  end

  test "every wider supported prefix admits an in-scope .255 unicast peer" do
    for prefix <- 8..23 do
      assert {:ok, scope} = IPv4Scope.new({10, 0, 0, 1}, prefix)
      assert IPv4Scope.contains_peer?(scope, {10, 0, 0, 255})

      assert {:ok, route} =
               WotexUdp.plan_destination(scope, "10.0.0.255:65535", :unicast)

      assert route.strategy == :prefix_scoped_unicast_compat
      assert route.port == 65_535
      assert route.destination.address == {10, 0, 0, 255}
      assert route.destination.port == 65_535
    end
  end

  test "endpoint text is canonical, bounded, IPv4-only and uses a nonzero port" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 24)

    for endpoint <- [
          "192.168.1.10:0",
          "192.168.1.10:65536",
          "192.168.1.10:-1",
          "192.168.1.10:056700",
          "192.168.001.10:56700",
          "0xc0.0xa8.0x01.0x0a:56700",
          "::1:56700",
          "host.local:56700",
          "192.168.1.10",
          "192.168.1.10:56700:1",
          <<255>>,
          String.duplicate("1", 65)
        ] do
      assert {:error, :invalid_endpoint} =
               WotexUdp.plan_destination(scope, endpoint, :unicast)
    end
  end

  test "the Home scope policy has explicit prefix and address-class boundaries" do
    for prefix <- Enum.to_list(0..7) ++ [31, 32] do
      assert {:error, :invalid_interface_scope} = IPv4Scope.new({10, 0, 0, 1}, prefix)
    end

    for local <- [
          {0, 1, 2, 3},
          {224, 0, 0, 1},
          {239, 255, 255, 254},
          {240, 0, 0, 1},
          {255, 255, 255, 254}
        ] do
      assert {:error, :invalid_interface_scope} = IPv4Scope.new(local, 24)
    end
  end

  test "the capability report names bounded and prefix-derived behavior" do
    assert WotexUdp.capabilities() == %{
             address_family: :ipv4,
             selected_address_binding: true,
             discovery_broadcast: :limited,
             directed_broadcast_request: :translated_to_limited,
             unicast_last_octet_255: :prefix_scoped_endpoint_compatibility,
             endpoint_role_source: :selected_prefix,
             socket_owner: :caller_session,
             receive_mode: :passive,
             receive_buffer_bytes: 2_048,
             max_datagram_bytes: 1_024,
             max_batch_datagrams: 1,
             max_pending_calls: 1,
             max_queued_send_bytes: 1_024,
             minimum_receive_timeout_ms: 1,
             max_receive_timeout_ms: 10_000,
             send_timeout_ms: 1_000,
             unicast_hops: 1,
             broadcast: true,
             multicast: false,
             oversize_receive: :consume_and_reject,
             send_success: :local_os_acceptance,
             error_boundary: :stable_kind_atoms,
             owner_loss: :invalidates_handle
           }
  end

  test "the complete upstream socket policy is explicit and inert" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 24)
    assert {:ok, config} = WotexUdp.configuration(scope)

    assert config.local.address == scope.local
    assert config.local.port == 0
    assert config.local.kind == :bind
    assert config.max_datagram_bytes == 1_024
    assert config.receive_buffer_bytes == 2_048
    assert config.max_batch_datagrams == 1
    assert config.max_pending_calls == 1
    assert config.max_queued_send_bytes == 1_024
    assert config.max_timeout_ms == 10_000
    assert config.unicast_hops == 1
    assert config.broadcast
    refute config.multicast

    assert {:error, :invalid_interface_scope} = WotexUdp.configuration(nil)
  end

  test "owner and admission failures cross the adapter only as stable atoms" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 24)
    invalid = %WotexUdp{handle: nil, scope: scope}

    assert {:error, :invalid_handle} = WotexUdp.local(invalid)
    assert {:error, :invalid_handle} = WotexUdp.close(invalid)
    assert {:error, :invalid_handle} = WotexUdp.recv(invalid, 1)
    assert {:error, :invalid_handle} = WotexUdp.send(invalid, "192.168.1.21:56700", <<1>>)

    overloaded_handle = handle(self())
    :atomics.put(overloaded_handle.admission, 1, overloaded_handle.max_queued_send_bytes + 1)
    overloaded = %WotexUdp{handle: overloaded_handle, scope: scope}
    assert {:error, :overload} = WotexUdp.local(overloaded)

    stale_owner =
      spawn(fn ->
        receive do
          {:"$gen_call", from, _request} ->
            GenServer.reply(
              from,
              {:error, %Error{kind: :stale_handle, operation: :owner, reason: nil}}
            )
        end
      end)

    assert {:error, :stale_handle} =
             WotexUdp.local(%WotexUdp{handle: handle(stale_owner), scope: scope})

    {lost_owner, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^lost_owner, :normal}

    assert {:error, :owner_lost} =
             WotexUdp.recv(%WotexUdp{handle: handle(lost_owner), scope: scope}, 1)
  end

  test "packet and receive deadline boundaries fail before socket ownership" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 1, 20}, 24)
    adapter = %WotexUdp{handle: nil, scope: scope}

    assert {:error, :invalid_datagram} = WotexUdp.send(adapter, "192.168.1.21:56700", <<>>)

    assert {:error, :invalid_handle} =
             WotexUdp.send(adapter, "192.168.1.21:56700", :binary.copy(<<0>>, 1_024))

    assert {:error, :invalid_datagram} =
             WotexUdp.send(adapter, "192.168.1.21:56700", :binary.copy(<<0>>, 1_025))

    assert {:error, :invalid_timeout} = WotexUdp.recv(adapter, 0)
    assert {:error, :invalid_handle} = WotexUdp.recv(adapter, 1)
    assert {:error, :invalid_handle} = WotexUdp.recv(adapter, 10_000)
    assert {:error, :invalid_timeout} = WotexUdp.recv(adapter, 10_001)
  end

  test "the transport capability callback uses the same socket-free planner" do
    assert {:ok, scope} = IPv4Scope.new({192, 168, 0, 20}, 23)
    adapter = %WotexUdp{handle: :not_used, scope: scope}

    assert :ok =
             Transport.check(
               {WotexUdp, adapter},
               "#{:inet.ntoa(scope.broadcast)}:56700",
               :discovery
             )

    assert :ok =
             Transport.check({WotexUdp, adapter}, "192.168.0.255:56700", :unicast)
  end

  defp local_for(prefix) do
    host_bits = 32 - prefix
    network = 10 <<< 24
    host = if host_bits == 1, do: 1, else: 1 <<< (host_bits - 1)
    bits = network + host

    {bits >>> 24 &&& 255, bits >>> 16 &&& 255, bits >>> 8 &&& 255, bits &&& 255}
  end

  defp handle(owner) do
    %Handle{
      owner: owner,
      epoch: make_ref(),
      admission: :atomics.new(1, signed: false),
      max_timeout_ms: 10_000,
      max_datagram_bytes: 1_024,
      max_pending_calls: 1,
      max_queued_send_bytes: 1_024
    }
  end
end
