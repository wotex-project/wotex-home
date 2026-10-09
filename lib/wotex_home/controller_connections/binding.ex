defmodule WotexHome.ControllerConnections.Binding do
  @moduledoc "One explicitly selected live interface/address and nonprivileged TCP port."

  def check(%{interface: name, address: address, port: port} = binding)
      when map_size(binding) == 3 and is_binary(name) and byte_size(name) in 1..64 and
             is_integer(port) and port in 1_024..65_535 do
    with true <- address?(address),
         {:ok, interfaces} <- :inet.getifaddrs(),
         {_, properties} <- List.keyfind(interfaces, String.to_charlist(name), 0),
         flags when is_list(flags) <- Keyword.get(properties, :flags),
         true <- :up in flags and :running in flags,
         [^address] <- Keyword.get_values(properties, :addr) |> Enum.filter(&(&1 == address)),
         do: :ok,
         else: (_ -> unavailable())
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def check(_), do: unavailable()

  def endpoint(%{address: {a, b, c, d}, port: port}),
    do: ["ipv4", Enum.join([a, b, c, d], "."), port]

  def endpoint(%{address: address, port: port}) when tuple_size(address) == 8,
    do: [
      "ipv6",
      address
      |> Tuple.to_list()
      |> Enum.map_join(
        ":",
        &(Integer.to_string(&1, 16) |> String.downcase() |> String.pad_leading(4, "0"))
      ),
      port
    ]

  defp address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    [a | _] = octets = Tuple.to_list(address)
    Enum.all?(octets, &(is_integer(&1) and &1 in 0..255)) and a in 1..223
  end

  defp address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    parts = Tuple.to_list(address)
    first = hd(parts)

    Enum.all?(parts, &(is_integer(&1) and &1 in 0..65_535)) and
      Enum.any?(parts, &(&1 != 0)) and first < 0xFF00 and
      Bitwise.band(first, 0xFFC0) != 0xFE80 and
      Enum.take(parts, 6) != [0, 0, 0, 0, 0, 0xFFFF]
  end

  defp address?(_), do: false
  defp unavailable, do: {:error, :controller_binding_unavailable}
end
