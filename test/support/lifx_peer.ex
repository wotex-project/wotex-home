defmodule LifxPeer do
  @moduledoc false

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  def main([mode]) when mode in ["read", "interview"] do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    IO.puts(port)

    case mode do
      "read" -> read(socket)
      "interview" -> interview(socket)
    end

    :ok = :gen_udp.close(socket)
  end

  defp read(socket) do
    {:ok, {ip, port, request}} = :gen_udp.recv(socket, 0, 5_000)
    {source, sequence, 101} = request_fields(request)

    label = "scripted-peer" <> :binary.copy(<<0>>, 32 - byte_size("scripted-peer"))

    payload =
      <<12_000::little-16, 40_000::little-16, 50_000::little-16, 3_500::little-16,
        0::16, 65_535::little-16, label::binary-size(32), 0::64>>

    :ok = :gen_udp.send(socket, ip, port, response(source, sequence, 45, <<>>))
    :ok = :gen_udp.send(socket, ip, port, response(source, sequence, 107, payload))
  end

  defp interview(socket) do
    replies =
      Enum.reduce(1..2, %{}, fn _, seen ->
        {:ok, {ip, port, request}} = :gen_udp.recv(socket, 0, 5_000)
        {source, sequence, type} = request_fields(request)
        true = type in [14, 32] and not Map.has_key?(seen, type)
        Map.put(seen, type, {ip, port, source, sequence})
      end)

    {ip, port, source, version_sequence} = Map.fetch!(replies, 32)
    {^ip, ^port, ^source, firmware_sequence} = Map.fetch!(replies, 14)

    firmware = <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>
    version = <<1::little-32, 27::little-32, 0::little-32>>

    :ok = :gen_udp.send(socket, ip, port, response(source, version_sequence, 45, <<>>))
    :ok = :gen_udp.send(socket, ip, port, response(source, firmware_sequence, 15, firmware))
    :ok = :gen_udp.send(socket, ip, port, response(source, version_sequence, 33, version))
  end

  defp request_fields(
         <<36::little-16, 0x1400::little-16, source::little-32, @target::binary,
           0::16, _::binary-size(6), _::8, sequence::8, _::binary-size(8),
           type::little-16, _::16>>
       )
       when source >= 2,
       do: {source, sequence, type}

  defp response(source, sequence, type, payload) do
    size = 36 + byte_size(payload)

    <<size::little-16, 0x1400::little-16, source::little-32, @target::binary,
      0::16, 0::48, 0::8, sequence::8, 0::64, type::little-16, 0::16,
      payload::binary>>
  end
end

LifxPeer.main(System.argv())
