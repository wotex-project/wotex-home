defmodule WotexHome.LifxPacketTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Lifx.Packet

  @target <<0xD0, 0x73, 0xD5, 0x00, 0x13, 0x37>>

  test "discovery and unicast headers use documented little-endian frame bits" do
    assert {:ok, discovery} = Packet.get_service(2, 1)
    assert byte_size(discovery) == 36
    assert binary_part(discovery, 0, 8) == <<36, 0, 0, 0x34, 2, 0, 0, 0>>
    assert {:ok, %Packet{type: 2, tagged: true, target: <<0::48>>}} = Packet.decode(discovery)

    assert {:ok, target} = Packet.target_from_hex("d073d5001337")
    assert target == @target
    assert {:ok, request} = Packet.get_version(2, target, 255)
    assert binary_part(request, 0, 4) == <<36, 0, 0, 0x14>>

    assert {:ok, %Packet{type: 32, tagged: false, sequence: 255, target: ^target}} =
             Packet.decode(request)

    assert {:ok, firmware_query} = Packet.get_host_firmware(2, target, 1)
    assert {:ok, %Packet{type: 14, payload: <<>>}} = Packet.decode(firmware_query)

    assert {:ok, light_power_query} = Packet.get_light_power(2, target, 2)
    assert {:ok, %Packet{type: 116, payload: <<>>}} = Packet.decode(light_power_query)
    assert {:ok, color_query} = Packet.get_color(2, target, 3)
    assert {:ok, %Packet{type: 101, payload: <<>>}} = Packet.decode(color_query)
  end

  test "absolute power encodes ack request and bounded duration" do
    assert {:ok, on} = Packet.set_light_power(2, @target, 7, true, 500)
    assert byte_size(on) == 42
    assert binary_part(on, 22, 2) == <<2, 7>>
    assert binary_part(on, 32, 4) == <<117, 0, 0, 0>>
    assert binary_part(on, 36, 6) == <<255, 255, 244, 1, 0, 0>>
    assert {:ok, %Packet{type: 117}} = Packet.decode(on)

    assert {:ok, off} = Packet.set_light_power(2, @target, 8, false, 0)
    assert binary_part(off, 36, 6) == <<0::48>>

    assert {:error, :invalid_power_request} =
             Packet.set_light_power(2, @target, 9, true, 60_001)
  end

  test "complete raw HSBK SetColor uses the documented 13-byte payload" do
    hsbk = %{hue: 21_845, saturation: 65_535, brightness: 32_768, kelvin: 3_500}
    assert {:ok, packet} = Packet.set_color(2, @target, 9, hsbk, 1_000)
    assert byte_size(packet) == 49
    assert binary_part(packet, 22, 2) == <<2, 9>>
    assert binary_part(packet, 32, 4) == <<102, 0, 0, 0>>

    assert binary_part(packet, 36, 13) ==
             <<0, 21_845::little-16, 65_535::little-16, 32_768::little-16, 3_500::little-16,
               1_000::little-32>>

    assert {:ok, %Packet{type: 102, tagged: false}} = Packet.decode(packet)

    assert {:error, :invalid_color_request} =
             Packet.set_color(2, @target, 9, %{hsbk | kelvin: 0}, 0)

    assert {:error, :invalid_color_request} =
             Packet.set_color(2, @target, 9, Map.put(hsbk, :extra, 1), 0)

    assert {:error, :invalid_color_request} =
             Packet.set_color(2, @target, 9, hsbk, 60_001)
  end

  test "malformed frame length, flags and target are rejected" do
    assert {:ok, packet} = Packet.get_power(2, @target, 1)
    assert {:error, :invalid_size} = Packet.decode(packet <> <<0>>)
    assert {:error, :invalid_size} = Packet.decode(binary_part(packet, 0, 35))
    assert {:error, :invalid_header} = Packet.decode(replace_byte(packet, 3, 0x04))
    assert {:error, :invalid_header} = Packet.decode(replace_byte(packet, 3, 0x54))
    assert {:error, :invalid_target} = Packet.decode(replace_byte(packet, 14, 1))
    assert {:error, :invalid_packet_request} = Packet.get_power(1, @target, 1)
    assert {:error, :invalid_target} = Packet.target_from_hex("not-a-serial")
  end

  test "known replies decode only their exact payload shapes" do
    assert {:ok, %{kind: :service, transport: :udp, port: 56_700}} =
             response(3, <<1, 56_700::little-32>>)

    assert {:ok, %{kind: :version, vendor: 1, product: 27}} =
             response(33, <<1::little-32, 27::little-32, 0::32>>)

    assert {:ok, %{kind: :host_firmware, build: 1_700_000_000, major: 3, minor: 60}} =
             response(15, <<1_700_000_000::little-64, 0::64, 60::little-16, 3::little-16>>)

    assert {:error, :invalid_payload} = response(15, <<0::128>>)

    assert {:ok, %{kind: :power, on?: false, raw_level: 0}} = response(22, <<0::16>>)

    assert {:ok, %{kind: :light_power, on?: true, raw_level: 65_535}} =
             response(118, <<65_535::little-16>>)

    assert {:ok, %{kind: :ack}} = response(45, <<>>)
    assert {:error, :invalid_payload} = response(45, <<1>>)
    assert {:error, :invalid_payload} = response(3, <<2, 56_700::little-32>>)
    assert {:error, :unsupported_message} = response(999, <<>>)
  end

  defp response(type, payload) do
    size = 36 + byte_size(payload)

    packet =
      <<size::little-16, 0x1400::little-16, 2::little-32, @target::binary, 0::16, 0::48, 0::16,
        0::64, type::little-16, 0::16, payload::binary>>

    with {:ok, decoded} <- Packet.decode(packet) do
      Packet.decode_response(decoded)
    end
  end

  defp replace_byte(packet, offset, value) do
    <<head::binary-size(offset), _::8, tail::binary>> = packet
    head <> <<value>> <> tail
  end
end
