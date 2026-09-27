defmodule WotexHome.Lifx.InterfaceSelection do
  @moduledoc """
  Selects one live IPv4 LAN interface for a LIFX capture.

  A named interface must be up, running and broadcast-capable, with exactly one
  usable IPv4 address and contiguous netmask. Ambiguous or changing interface
  data fails closed. The resulting scope describes the network; the capture
  owner still has to bind and verify its socket on that address.
  """

  alias WotexHome.Lifx.IPv4Scope

  @doc "Reads the named interface and returns its single selected IPv4 scope."
  @spec select(String.t()) :: {:ok, IPv4Scope.t()} | {:error, :selected_interface_unavailable}
  def select(name) when is_binary(name) and byte_size(name) in 1..64 do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         {_, properties} <- List.keyfind(interfaces, String.to_charlist(name), 0) do
      from_properties(properties)
    else
      _ -> {:error, :selected_interface_unavailable}
    end
  end

  def select(_), do: {:error, :selected_interface_unavailable}

  @doc "Validates an interface property list, useful for examining ambiguous OS results."
  @spec from_properties(list()) ::
          {:ok, IPv4Scope.t()} | {:error, :selected_interface_unavailable}
  def from_properties(properties) when is_list(properties) do
    flags = if Keyword.keyword?(properties), do: Keyword.get(properties, :flags, []), else: []

    with true <- is_list(flags),
         true <- Enum.all?([:up, :running, :broadcast], &(&1 in flags)),
         [{address, mask}] <- ipv4_pairs(properties),
         {:ok, prefix} <- prefix(mask),
         {:ok, scope} <- IPv4Scope.new(address, prefix) do
      {:ok, scope}
    else
      _ -> {:error, :selected_interface_unavailable}
    end
  end

  def from_properties(_), do: {:error, :selected_interface_unavailable}

  defp ipv4_pairs(properties) do
    properties
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{:addr, address}, {:netmask, mask}]
      when is_tuple(address) and tuple_size(address) == 4 and is_tuple(mask) and
             tuple_size(mask) == 4 ->
        [{address, mask}]

      _ ->
        []
    end)
  end

  defp prefix(mask) do
    octets = Tuple.to_list(mask)

    if Enum.all?(octets, &(is_integer(&1) and &1 in 0..255)) do
      bits = for octet <- octets, bit <- 7..0//-1, do: Bitwise.band(Bitwise.bsr(octet, bit), 1)
      count = Enum.sum(bits)

      if bits == List.duplicate(1, count) ++ List.duplicate(0, 32 - count),
        do: {:ok, count},
        else: {:error, :invalid_netmask}
    else
      {:error, :invalid_netmask}
    end
  end
end
