# Independent byte-level loopback peer. Imports no Home codec, clock or Store.
defmodule LifxPowerRoutePeer do
  @target <<0xD0, 0x73, 0xD5, 0x00, 0x00, 0x01>>

  def main([mode]) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, service_port}} = :inet.sockname(socket)
    IO.puts(service_port)
    {ip, port, source, sequence, 2, <<>>, <<0::48>>} = request(socket)
    if mode == "late_discovery", do: Process.sleep(250)
    target = if mode == "wrong_identity", do: <<0xD0, 0x73, 0xD5, 0, 0, 2>>, else: @target

    :ok =
      :gen_udp.send(
        socket,
        ip,
        port,
        response(source, sequence, 3, <<1, service_port::little-32>>, target)
      )

    if mode == "ambiguous" do
      {:ok, other} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, other_port}} = :inet.sockname(other)

      :ok =
        :gen_udp.send(
          other,
          ip,
          port,
          response(source, sequence, 3, <<1, other_port::little-32>>, @target)
        )

      :gen_udp.close(other)
    end

    if mode in ["route", "power", "late_read", "noise"] do
      {ip, port, source, sequence, 101, <<>>, @target} = request(socket)
      if mode == "late_read", do: Process.sleep(250)
      payload = <<0::16, 0::16, 0::16, 3_500::little-16, 0::16, 0::16, 0::256, 0::64>>

      if mode == "noise" do
        :ok =
          :gen_udp.send(
            socket,
            ip,
            port,
            response(source, rem(sequence + 1, 256), 107, payload, @target)
          )

        :ok =
          :gen_udp.send(
            socket,
            ip,
            port,
            response(source, sequence, 107, payload, <<0xD0, 0x73, 0xD5, 0, 0, 2>>)
          )
      end

      :ok = :gen_udp.send(socket, ip, port, response(source, sequence, 107, payload, @target))

      if mode == "power" do
        {ip, port, source, sequence, 117, <<65_535::little-16, 0::little-32>>, @target} =
          request(socket)

        IO.puts("set")
        :ok = :gen_udp.send(socket, ip, port, response(source, sequence, 45, <<>>, @target))
        {ip, port, source, sequence, 116, <<>>, @target} = request(socket)

        :ok =
          :gen_udp.send(
            socket,
            ip,
            port,
            response(source, sequence, 118, <<65_535::little-16>>, @target)
          )
      end
    end

    # Unexpected reads or sets after refusal/queued routing fail this peer.
    {:error, :timeout} = :gen_udp.recv(socket, 0, 300)
    :gen_udp.close(socket)
  end

  defp request(socket) do
    {:ok, {ip, port, bytes}} = :gen_udp.recv(socket, 0, 5_000)

    <<size::little-16, frame::little-16, source::little-32, target::binary-size(6), 0::16, _::48,
      _::8, sequence::8, _::64, type::little-16, 0::16, payload::binary>> = bytes

    true = size == byte_size(bytes) and frame in [0x1400, 0x3400] and source >= 2
    {ip, port, source, sequence, type, payload, target}
  end

  defp response(source, sequence, type, payload, target) do
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, target::binary, 0::16, 0::48, 0::8,
      sequence::8, 0::64, type::little-16, 0::16, payload::binary>>
  end
end

LifxPowerRoutePeer.main(System.argv())
