defmodule WotexHome.Lifx.IPv4Scope do
  @moduledoc "A selected IPv4 LAN interface and its finite discovery source scope."

  import Bitwise

  @enforce_keys [:local, :prefix, :mask, :network, :broadcast]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(tuple(), integer()) :: {:ok, t()} | {:error, :invalid_interface_scope}
  def new(local, prefix) when is_integer(prefix) and prefix in 8..30 do
    if valid_address?(local) do
      mask = 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF
      local_bits = bits(local)
      network = local_bits &&& mask
      broadcast = network ||| bxor(0xFFFFFFFF, mask)

      if local_bits != network and local_bits != broadcast and elem(local, 0) < 224 and
           elem(local, 0) > 0 do
        {:ok,
         %__MODULE__{
           local: local,
           prefix: prefix,
           mask: mask,
           network: network,
           broadcast: address(broadcast)
         }}
      else
        {:error, :invalid_interface_scope}
      end
    else
      {:error, :invalid_interface_scope}
    end
  end

  def new(_local, _prefix), do: {:error, :invalid_interface_scope}

  @spec contains_peer?(t(), tuple()) :: boolean()
  def contains_peer?(%__MODULE__{} = scope, peer) do
    valid_address?(peer) and peer != scope.local and peer != scope.broadcast and
      bits(peer) != scope.network and (bits(peer) &&& scope.mask) == scope.network and
      elem(peer, 0) > 0 and elem(peer, 0) < 224
  end

  @spec broadcast(t()) :: tuple()
  def broadcast(%__MODULE__{broadcast: broadcast}), do: broadcast

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 4,
    do: Enum.all?(Tuple.to_list(address), &(is_integer(&1) and &1 >= 0 and &1 <= 255))

  defp valid_address?(_address), do: false

  defp bits({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp address(bits),
    do: {bits >>> 24 &&& 255, bits >>> 16 &&& 255, bits >>> 8 &&& 255, bits &&& 255}
end
