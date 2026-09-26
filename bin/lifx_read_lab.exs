defmodule WotexHome.LifxReadLab.Transport do
  @moduledoc false
  @behaviour WotexHome.Lifx.Transport

  alias WotexHome.Lifx.IPv4Scope

  def open(interface_name) do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         {_, properties} <- List.keyfind(interfaces, String.to_charlist(interface_name), 0),
         true <-
           Enum.all?([:up, :running, :broadcast], &(&1 in Keyword.get(properties, :flags, []))),
         [{address, mask}] <- ipv4_pairs(properties),
         {:ok, prefix} <- prefix(mask),
         {:ok, scope} <- IPv4Scope.new(address, prefix),
         {:ok, socket} <-
           :gen_udp.open(0, [:binary, active: false, ip: address, broadcast: true]) do
      {:ok, {socket, scope}, scope}
    else
      _ -> {:error, :selected_interface_unavailable}
    end
  end

  @impl true
  def send({socket, scope}, endpoint, bytes) when is_binary(endpoint) and is_binary(bytes) do
    with true <- byte_size(bytes) in 36..256,
         [address_text, port_text] <- String.split(endpoint, ":"),
         {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(address_text)),
         {port, ""} <- Integer.parse(port_text),
         true <- port in 1..65_535,
         true <-
           (address == IPv4Scope.broadcast(scope) and port == 56_700) or
             IPv4Scope.contains_peer?(scope, address) do
      :gen_udp.send(socket, address, port, bytes)
    else
      _ -> {:error, :endpoint_out_of_scope}
    end
  end

  def send(_handle, _endpoint, _bytes), do: {:error, :endpoint_out_of_scope}

  @impl true
  def recv({socket, _scope}, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case :gen_udp.recv(socket, 0, timeout_ms) do
      {:ok, {address, port, bytes}} when byte_size(bytes) <= 1_024 ->
        {:ok, "#{:inet.ntoa(address)}:#{port}", bytes}

      {:ok, _} ->
        {:error, :oversized_datagram}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def close({socket, _scope}), do: :gen_udp.close(socket)

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

defmodule WotexHome.LifxReadLab do
  @moduledoc false

  alias WotexHome.Lifx.{DiscoveryPath, InterviewPath, Ledger}
  alias WotexHome.LifxReadLab.Transport

  def run([interface_name]) do
    case Transport.open(interface_name) do
      {:ok, handle, scope} ->
        try do
          probe(interface_name, handle, scope)
        after
          Transport.close(handle)
        end

      {:error, reason} ->
        IO.puts(:stderr, "LIFX read-only lab: #{reason}")
        System.halt(2)
    end
  end

  def run(_args) do
    IO.puts(:stderr, "usage: mix run bin/lifx_read_lab.exs INTERFACE")
    System.halt(2)
  end

  defp probe(interface_name, handle, scope) do
    base = System.monotonic_time(:millisecond)

    clock = fn ->
      {System.monotonic_time(:millisecond) - base + 1_000, System.system_time(:millisecond)}
    end

    receive_epoch = "lab:#{System.unique_integer([:positive])}"

    case DiscoveryPath.run(interface_name, receive_epoch, scope, 2, 7,
           transport: {Transport, handle},
           clock: clock,
           duration_ms: 2_000
         ) do
      {:ok, candidates, _window} ->
        IO.puts(
          "selected #{interface_name} #{:inet.ntoa(scope.local)}/#{scope.prefix}; #{length(candidates)} LIFX candidates"
        )

        {:ok, ledger} = Ledger.new(2)

        candidates
        |> Enum.take(8)
        |> Enum.reduce(ledger, fn candidate, ledger ->
          interview(candidate, ledger, handle, clock)
        end)

        if candidates == [], do: System.halt(3)

      {:error, reason, _window} ->
        IO.puts(:stderr, "LIFX read-only discovery failed: #{reason}")
        System.halt(2)
    end
  end

  defp interview(candidate, ledger, handle, clock) do
    target_text = String.replace_prefix(candidate.claimed_identifiers["stable_id"], "lifx:", "")

    with {:ok, target} <- Base.decode16(target_text, case: :lower),
         {:ok, result, next_ledger} <-
           InterviewPath.run(candidate, target, ledger,
             transport: {Transport, handle},
             clock: clock,
             timeout_ms: 2_000
           ) do
      IO.puts(
        JSON.encode!(%{
          "candidate_ref" => candidate.raw_ref,
          "endpoint" => candidate.source_endpoint,
          "stable_id_claim" => result.stable_id,
          "manufacturer_reported" => result.manufacturer,
          "model_reported" => result.model,
          "firmware_reported" => result.firmware
        })
      )

      next_ledger
    else
      {:error, reason, next_ledger} ->
        IO.puts("#{candidate.raw_ref} interview unresolved: #{reason}")
        next_ledger

      _ ->
        IO.puts("#{candidate.raw_ref} interview unresolved: invalid target")
        ledger
    end
  end
end

WotexHome.LifxReadLab.run(System.argv())
