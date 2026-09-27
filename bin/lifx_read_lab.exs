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
           :gen_udp.open(0, [
             :binary,
             active: false,
             ip: address,
             broadcast: true,
             recbuf: 131_072
           ]) do
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

  alias WotexHome.Lifx.CaptureSession
  alias WotexHome.LifxReadLab.Transport

  def run([interface_name]), do: run_probe(interface_name, nil)
  def run([interface_name, candidate_ref]), do: run_probe(interface_name, candidate_ref)

  def run(_args) do
    IO.puts(:stderr, "usage: mix run bin/lifx_read_lab.exs INTERFACE [CANDIDATE_REF]")
    System.halt(2)
  end

  defp run_probe(interface_name, selected_ref) do
    case Transport.open(interface_name) do
      {:ok, handle, scope} ->
        case CaptureSession.start_link(
               interface_id: interface_name,
               scope: scope,
               transport: {Transport, handle}
             ) do
          {:ok, owner} ->
            case :gen_udp.controlling_process(elem(handle, 0), owner) do
              :ok ->
                code =
                  try do
                    probe(interface_name, scope, owner, selected_ref)
                  after
                    GenServer.stop(owner)
                  end

                System.halt(code)

              {:error, reason} ->
                GenServer.stop(owner)
                IO.puts(:stderr, "LIFX read-only socket ownership failed: #{reason}")
                System.halt(2)
            end

          {:error, reason} ->
            Transport.close(handle)
            IO.puts(:stderr, "LIFX read-only capture failed: #{reason}")
            System.halt(2)
        end

      {:error, reason} ->
        IO.puts(:stderr, "LIFX read-only lab: #{reason}")
        System.halt(2)
    end
  end

  defp probe(interface_name, scope, owner, selected_ref) do
    case CaptureSession.discover(owner, 2, 7, 2_000) do
      {:ok, ref, candidates} ->
        IO.puts(
          "selected #{interface_name} #{:inet.ntoa(scope.local)}/#{scope.prefix}; #{length(candidates)} LIFX candidates"
        )

        case select(candidates, selected_ref) do
          {:ok, candidate} ->
            interview(owner, ref, candidate)

          {:error, reason} ->
            Enum.each(candidates, &IO.puts(&1.raw_ref))
            IO.puts(:stderr, "LIFX read-only selection unresolved: #{reason}")
            4
        end

      {:error, :no_candidates} ->
        IO.puts(
          "selected #{interface_name} #{:inet.ntoa(scope.local)}/#{scope.prefix}; 0 LIFX candidates"
        )

        3

      {:error, reason} ->
        IO.puts(:stderr, "LIFX read-only discovery failed: #{reason}")
        2
    end
  end

  defp select([candidate], nil), do: {:ok, candidate}

  defp select(candidates, ref) when is_binary(ref) do
    case Enum.filter(candidates, &(&1.raw_ref == ref)) do
      [candidate] -> {:ok, candidate}
      _ -> {:error, :candidate_not_in_capture}
    end
  end

  defp select(_candidates, nil), do: {:error, :candidate_selection_required}

  defp interview(owner, ref, candidate) do
    with {:ok, result} <- CaptureSession.interview(owner, ref, candidate.raw_ref, 2, 2_000),
         {:ok, evidence} <- CaptureSession.checkout(owner, ref) do
      digest =
        evidence.transcript
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      IO.puts(
        JSON.encode!(%{
          "candidate_ref" => candidate.raw_ref,
          "endpoint" => candidate.source_endpoint,
          "capture_epoch" => evidence.epoch,
          "transcript_sha256" => digest,
          "stable_id_claim" => result.stable_id,
          "manufacturer_reported" => result.manufacturer,
          "model_reported" => result.model,
          "firmware_reported" => result.firmware
        })
      )

      0
    else
      {:error, reason} ->
        IO.puts("#{candidate.raw_ref} interview unresolved: #{reason}")
        4
    end
  end
end

WotexHome.LifxReadLab.run(System.argv())
