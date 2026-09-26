defmodule WotexHome.Lifx.Packet do
  @moduledoc """
  Bounded LIFX LAN packet subset for old lights.

  This module only encodes and decodes bytes. It owns no socket or device
  credential and does not interpret UDP send success as device acceptance.
  """

  import Bitwise

  @header_bytes 36
  @max_packet_bytes 1_024
  @max_u32 4_294_967_295

  @enforce_keys [:source, :target, :sequence, :type, :payload, :tagged]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: non_neg_integer(),
          target: binary(),
          sequence: non_neg_integer(),
          type: non_neg_integer(),
          payload: binary(),
          tagged: boolean()
        }

  @spec target_from_hex(String.t()) :: {:ok, binary()} | {:error, :invalid_target}
  def target_from_hex(serial) when is_binary(serial) and byte_size(serial) == 12 do
    case Base.decode16(serial, case: :mixed) do
      {:ok, target} when byte_size(target) == 6 and target != <<0::48>> -> {:ok, target}
      _ -> {:error, :invalid_target}
    end
  end

  def target_from_hex(_serial), do: {:error, :invalid_target}

  @spec get_service(non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def get_service(source, sequence),
    do: encode(source, <<0::48>>, sequence, 2, <<>>, true, false)

  @spec get_version(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def get_version(source, target, sequence),
    do: encode(source, target, sequence, 32, <<>>, false, false)

  @spec get_host_firmware(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def get_host_firmware(source, target, sequence),
    do: encode(source, target, sequence, 14, <<>>, false, false)

  @spec get_power(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def get_power(source, target, sequence),
    do: encode(source, target, sequence, 20, <<>>, false, false)

  @spec get_light_power(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def get_light_power(source, target, sequence),
    do: encode(source, target, sequence, 116, <<>>, false, false)

  @spec get_color(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def get_color(source, target, sequence),
    do: encode(source, target, sequence, 101, <<>>, false, false)

  @spec set_light_power(
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          boolean(),
          non_neg_integer()
        ) ::
          {:ok, binary()} | {:error, atom()}
  def set_light_power(source, target, sequence, on?, duration_ms)
      when is_boolean(on?) and is_integer(duration_ms) and duration_ms >= 0 and
             duration_ms <= 60_000 do
    level = if(on?, do: 65_535, else: 0)

    encode(
      source,
      target,
      sequence,
      117,
      <<level::little-16, duration_ms::little-32>>,
      false,
      true
    )
  end

  def set_light_power(_source, _target, _sequence, _on?, _duration_ms),
    do: {:error, :invalid_power_request}

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(packet)
      when is_binary(packet) and byte_size(packet) >= @header_bytes and
             byte_size(packet) <= @max_packet_bytes do
    <<size::little-16, frame::little-16, source::little-32, target::binary-size(8),
      _reserved_address::binary-size(6), _flags::8, sequence::8,
      _reserved_protocol::binary-size(8), type::little-16, _reserved_type::binary-size(2),
      payload::binary>> = packet

    cond do
      size != byte_size(packet) ->
        {:error, :invalid_size}

      (frame &&& 0x0FFF) != 1_024 or (frame &&& 0x1000) == 0 or
          (frame &&& 0xC000) != 0 ->
        {:error, :invalid_header}

      source < 2 ->
        {:error, :invalid_source}

      binary_part(target, 6, 2) != <<0, 0>> ->
        {:error, :invalid_target}

      true ->
        {:ok,
         %__MODULE__{
           source: source,
           target: binary_part(target, 0, 6),
           sequence: sequence,
           type: type,
           payload: payload,
           tagged: (frame &&& 0x2000) != 0
         }}
    end
  end

  def decode(_packet), do: {:error, :invalid_size}

  @spec decode_response(t()) :: {:ok, map()} | {:error, atom()}
  def decode_response(%__MODULE__{type: 3, payload: <<1, port::little-32>>})
      when port > 0 and port <= 65_535,
      do: {:ok, %{kind: :service, transport: :udp, port: port}}

  def decode_response(%__MODULE__{
        type: 33,
        payload: <<vendor::little-32, product::little-32, _::32>>
      }),
      do: {:ok, %{kind: :version, vendor: vendor, product: product}}

  def decode_response(%__MODULE__{
        type: 15,
        payload:
          <<build::little-64, _reserved::binary-size(8), minor::little-16, major::little-16>>
      }),
      do: {:ok, %{kind: :host_firmware, build: build, major: major, minor: minor}}

  def decode_response(%__MODULE__{type: 22, payload: <<level::little-16>>}),
    do: {:ok, %{kind: :power, on?: level != 0, raw_level: level}}

  def decode_response(%__MODULE__{type: 118, payload: <<level::little-16>>}),
    do: {:ok, %{kind: :light_power, on?: level != 0, raw_level: level}}

  def decode_response(%__MODULE__{type: 45, payload: <<>>}), do: {:ok, %{kind: :ack}}

  def decode_response(%__MODULE__{
        type: 107,
        payload:
          <<hue::little-16, saturation::little-16, brightness::little-16, kelvin::little-16,
            _reserved::binary-size(2), power::little-16, label::binary-size(32),
            _reserved_tail::binary-size(8)>>
      }),
      do:
        {:ok,
         %{
           kind: :light_state,
           hue: hue,
           saturation: saturation,
           brightness: brightness,
           kelvin: kelvin,
           power_on?: power != 0,
           raw_power: power,
           label: label |> :binary.split(<<0>>) |> hd()
         }}

  def decode_response(%__MODULE__{type: type})
      when type in [3, 15, 22, 33, 45, 107, 118],
      do: {:error, :invalid_payload}

  def decode_response(%__MODULE__{}), do: {:error, :unsupported_message}

  defp encode(source, target, sequence, type, payload, tagged?, ack?) do
    with true <- is_integer(source) and source >= 2 and source <= @max_u32,
         true <- valid_target?(target, tagged?),
         true <- is_integer(sequence) and sequence >= 0 and sequence <= 255,
         true <- byte_size(payload) + @header_bytes <= @max_packet_bytes do
      target8 = target <> <<0, 0>>
      flags = if(ack?, do: 2, else: 0)
      frame = if(tagged?, do: 0x3400, else: 0x1400)
      size = @header_bytes + byte_size(payload)

      {:ok,
       <<size::little-16, frame::little-16, source::little-32, target8::binary-size(8), 0::48,
         flags::8, sequence::8, 0::64, type::little-16, 0::16, payload::binary>>}
    else
      false -> {:error, :invalid_packet_request}
    end
  end

  defp valid_target?(<<0::48>>, true), do: true

  defp valid_target?(target, false) when is_binary(target) and byte_size(target) == 6,
    do: target != <<0::48>>

  defp valid_target?(_target, _tagged?), do: false
end
