defmodule WotexHome.Lifx.DiscoveryWindow do
  @moduledoc """
  Pure, finite LIFX broadcast discovery window.

  It consumes UDP source metadata and StateService bytes, but opens no socket.
  Repeated replies from one target/endpoint coalesce. The same target claimed
  from distinct endpoints remains two candidates so enrollment can see the
  identity collision instead of silently choosing one route.
  """

  alias WotexHome.Discovery.Candidate
  alias WotexHome.Id
  alias WotexHome.Lifx.{IPv4Scope, Packet}

  @max_i64 9_223_372_036_854_775_807
  @max_candidates 128

  @enforce_keys [
    :interface_id,
    :receive_epoch,
    :scope,
    :source,
    :sequence,
    :start_ms,
    :deadline_ms,
    :seen
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(
          String.t(),
          String.t(),
          IPv4Scope.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, t(), binary()} | {:error, atom()}
  def new(
        interface_id,
        receive_epoch,
        %IPv4Scope{} = scope,
        source,
        sequence,
        now_ms,
        duration_ms
      ) do
    with true <- Id.valid?(interface_id) and Id.valid?(receive_epoch),
         true <- IPv4Scope.new(scope.local, scope.prefix) == {:ok, scope},
         true <- valid_time?(now_ms, duration_ms),
         {:ok, query} <- Packet.get_service(source, sequence) do
      {:ok,
       %__MODULE__{
         interface_id: interface_id,
         receive_epoch: receive_epoch,
         scope: scope,
         source: source,
         sequence: sequence,
         start_ms: now_ms,
         deadline_ms: now_ms + duration_ms,
         seen: %{}
       }, query}
    else
      false -> {:error, :invalid_discovery_window}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_interface_id, _receive_epoch, _scope, _source, _sequence, _now_ms, _duration_ms),
    do: {:error, :invalid_discovery_window}

  @spec accept(t(), binary(), tuple(), pos_integer(), non_neg_integer()) ::
          {:ok, Candidate.t() | :duplicate, t()} | {:error, atom(), t()}
  def accept(%__MODULE__{} = window, bytes, address, source_port, now_ms) do
    with :ok <- in_window(window, now_ms),
         true <- IPv4Scope.contains_peer?(window.scope, address) and valid_port?(source_port),
         {:ok, packet} <- Packet.decode(bytes),
         true <-
           packet.source == window.source and packet.sequence == window.sequence and
             packet.target != <<0::48>> and not packet.tagged,
         {:ok, %{kind: :service, port: service_port}} <- Packet.decode_response(packet) do
      candidate(window, packet.target, address, service_port, now_ms)
    else
      false -> {:error, :unmatched_discovery_response, window}
      {:error, reason} -> {:error, reason, window}
      _ -> {:error, :unmatched_discovery_response, window}
    end
  end

  @spec candidates(t()) :: [Candidate.t()]
  def candidates(%__MODULE__{seen: seen}),
    do: seen |> Map.values() |> Enum.sort_by(& &1.raw_ref)

  @spec broadcast(t()) :: tuple()
  def broadcast(%__MODULE__{scope: scope}), do: IPv4Scope.broadcast(scope)

  defp candidate(window, target, address, service_port, now_ms) do
    serial = Base.encode16(target, case: :lower)
    endpoint = "#{:inet.ntoa(address)}:#{service_port}"
    key = {target, address, service_port}

    case Map.fetch(window.seen, key) do
      {:ok, _existing} ->
        {:ok, :duplicate, window}

      :error when map_size(window.seen) >= @max_candidates ->
        {:error, :too_many_candidates, window}

      :error ->
        endpoint_digest =
          :crypto.hash(:sha256, endpoint)
          |> binary_part(0, 8)
          |> Base.encode16(case: :lower)

        {:ok, candidate} =
          Candidate.new(%{
            "interface_id" => window.interface_id,
            "transport" => "udp",
            "source_endpoint" => endpoint,
            "receive_epoch" => window.receive_epoch,
            "received_monotonic_ms" => now_ms,
            "raw_ref" => "lifx:#{serial}:#{endpoint_digest}",
            "claimed_identifiers" => %{"stable_id" => "lifx:#{serial}"},
            "trust_class" => "untrusted_network"
          })

        {:ok, candidate, %{window | seen: Map.put(window.seen, key, candidate)}}
    end
  end

  defp valid_time?(now_ms, duration_ms),
    do:
      is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 and
        is_integer(duration_ms) and duration_ms >= 100 and duration_ms <= 10_000 and
        now_ms + duration_ms <= @max_i64

  defp in_window(window, now_ms) do
    if is_integer(now_ms) and now_ms >= window.start_ms and now_ms <= window.deadline_ms,
      do: :ok,
      else: {:error, :window_closed}
  end

  defp valid_port?(source_port),
    do: is_integer(source_port) and source_port > 0 and source_port <= 65_535
end
