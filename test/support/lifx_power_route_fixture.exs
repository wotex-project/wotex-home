defmodule WotexHome.TestSupport.PowerRouteTransport do
  @moduledoc "Private loopback fixture: redirects only the discovery broadcast to an independent peer. Replies keep their actual UDP endpoint."
  @behaviour WotexHome.Lifx.Transport

  def send({socket, peer_port, observer, :pause_report}, endpoint, bytes),
    do: send({socket, peer_port, observer}, endpoint, bytes)

  def send({socket, peer_port, observer}, endpoint, bytes) do
    <<type::little-16>> = binary_part(bytes, 32, 2)
    Kernel.send(observer, {:route_wire, type, System.monotonic_time(:millisecond)})
    send({socket, peer_port}, endpoint, bytes)
  end

  def send({socket, peer_port}, endpoint, bytes) do
    [address, port] = String.split(endpoint, ":")

    {ip, port} =
      if address == "127.255.255.255" do
        {{127, 0, 0, 1}, peer_port}
      else
        {:ok, ip} = :inet.parse_ipv4_address(String.to_charlist(address))
        {ip, String.to_integer(port)}
      end

    :gen_udp.send(socket, ip, port, bytes)
  end

  def recv({socket, _}, timeout) do
    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, {ip, port, bytes}} -> {:ok, "#{:inet.ntoa(ip)}:#{port}", bytes}
      error -> error
    end
  end

  def recv({socket, peer_port, _observer}, timeout), do: recv({socket, peer_port}, timeout)

  def recv({socket, peer_port, observer, :pause_report}, timeout) do
    case recv({socket, peer_port}, timeout) do
      {:ok, _, bytes} = result ->
        if binary_part(bytes, 32, 2) == <<107::little-16>> do
          Kernel.send(observer, {:before_route_report, self()})

          receive do
            :accept_route_report -> result
          after
            500 -> {:error, :timeout}
          end
        else
          result
        end

      error ->
        error
    end
  end
end

defmodule WotexHome.TestSupport.PowerRouteFixture do
  @moduledoc false
  def open(mode, observer \\ nil, pause_report \\ false) do
    elixir = System.find_executable("elixir")
    path = Path.expand("../../test_support/lifx_power_route_peer.ex", __DIR__)
    peer = Port.open({:spawn_executable, elixir}, [:binary, :exit_status, args: [path, mode]])

    port =
      receive do
        {^peer, {:data, data}} -> String.trim(data) |> String.to_integer()
      after
        5_000 -> raise "independent power route peer did not bind"
      end

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    cleanup = fn ->
      :gen_udp.close(socket)
      if Port.info(peer), do: Port.close(peer)
    end

    handle =
      cond do
        pause_report and is_pid(observer) -> {socket, port, observer, :pause_report}
        is_pid(observer) -> {socket, port, observer}
        true -> {socket, port}
      end

    {peer, {WotexHome.TestSupport.PowerRouteTransport, handle}, cleanup}
  end
end
