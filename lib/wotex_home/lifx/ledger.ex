defmodule WotexHome.Lifx.Ledger do
  @moduledoc """
  Bounded in-boot correlation for unicast LIFX replies.

  A sequence wrap advances the client source before sequence zero is reused.
  Late packets from an earlier source cannot satisfy a new request. This is
  correlation only; LIFX LAN replies are not cryptographically authenticated.
  """

  alias WotexHome.Lifx.Packet

  @max_i64 9_223_372_036_854_775_807
  @max_u32 4_294_967_295
  @expected_types %{
    version: 33,
    host_firmware: 15,
    power: 22,
    light_power: 118,
    light_state: 107,
    ack: 45
  }

  @enforce_keys [:source, :next_sequence, :pending]
  defstruct @enforce_keys

  @type key :: {non_neg_integer(), binary(), non_neg_integer()}
  @type t :: %__MODULE__{
          source: non_neg_integer(),
          next_sequence: non_neg_integer(),
          pending: %{key() => %{type: non_neg_integer(), deadline_ms: non_neg_integer()}}
        }

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, :invalid_source}
  def new(source) when is_integer(source) and source >= 2 and source <= @max_u32,
    do: {:ok, %__MODULE__{source: source, next_sequence: 0, pending: %{}}}

  def new(_source), do: {:error, :invalid_source}

  @spec issue(t(), binary(), atom(), non_neg_integer(), pos_integer()) ::
          {:ok, key(), t()} | {:error, atom()}
  def issue(%__MODULE__{} = ledger, target, expected, now_ms, ttl_ms) do
    with true <- valid_target?(target) and Map.has_key?(@expected_types, expected),
         true <- valid_deadline?(now_ms, ttl_ms) do
      {_expired, ledger} = expire(ledger, now_ms)

      cond do
        map_size(ledger.pending) >= 64 ->
          {:error, :too_many_requests}

        count_target(ledger, target) >= 4 ->
          {:error, :device_busy}

        true ->
          key = {ledger.source, target, ledger.next_sequence}
          entry = %{type: Map.fetch!(@expected_types, expected), deadline_ms: now_ms + ttl_ms}
          {next_source, next_sequence} = advance(ledger.source, ledger.next_sequence)

          {:ok, key,
           %{
             ledger
             | source: next_source,
               next_sequence: next_sequence,
               pending: Map.put(ledger.pending, key, entry)
           }}
      end
    else
      false -> {:error, :invalid_request}
    end
  end

  @spec accept(t(), Packet.t(), non_neg_integer()) ::
          {:ok, map(), t()} | {:error, atom(), t()}
  def accept(%__MODULE__{} = ledger, %Packet{} = packet, now_ms)
      when is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
    key = {packet.source, packet.target, packet.sequence}

    case Map.fetch(ledger.pending, key) do
      {:ok, %{deadline_ms: deadline}} when now_ms > deadline ->
        {:error, :expired, %{ledger | pending: Map.delete(ledger.pending, key)}}

      {:ok, %{type: expected_type}} when packet.type == expected_type ->
        case Packet.decode_response(packet) do
          {:ok, response} ->
            {:ok, response, %{ledger | pending: Map.delete(ledger.pending, key)}}

          {:error, reason} ->
            {:error, reason, ledger}
        end

      {:ok, _entry} ->
        {:error, :unexpected_response, ledger}

      :error ->
        {:error, :unmatched_response, ledger}
    end
  end

  def accept(%__MODULE__{} = ledger, _packet, _now_ms),
    do: {:error, :invalid_response, ledger}

  @spec expire(t(), non_neg_integer()) :: {[key()], t()}
  def expire(%__MODULE__{} = ledger, now_ms)
      when is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
    {expired, active} =
      Enum.split_with(ledger.pending, fn {_key, entry} -> now_ms > entry.deadline_ms end)

    {Enum.map(expired, &elem(&1, 0)), %{ledger | pending: Map.new(active)}}
  end

  defp valid_target?(target),
    do: is_binary(target) and byte_size(target) == 6 and target != <<0::48>>

  defp valid_deadline?(now_ms, ttl_ms),
    do:
      is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 and
        is_integer(ttl_ms) and ttl_ms > 0 and ttl_ms <= 10_000 and
        now_ms + ttl_ms <= @max_i64

  defp count_target(ledger, target) do
    Enum.count(ledger.pending, fn {{_source, pending_target, _sequence}, _entry} ->
      pending_target == target
    end)
  end

  defp advance(source, 255), do: {if(source == @max_u32, do: 2, else: source + 1), 0}
  defp advance(source, sequence), do: {source, sequence + 1}
end
