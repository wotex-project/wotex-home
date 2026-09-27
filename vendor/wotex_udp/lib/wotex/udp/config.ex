defmodule Wotex.UDP.Config do
  @moduledoc """
  Limits and opt-ins for one caller-owned socket.

  `local:` is required and must be an `Endpoint.bind/2` value. Defaults cap
  datagrams at 1,472 bytes, the kernel receive buffer request at 65,536 bytes,
  one batch at 32 datagrams, 32 pending calls, 65,536 queued send bytes,
  and each send or receive deadline at 60,000 ms.
  The default unicast hop limit is 64 and the multicast hop limit is 1.
  The operating system may adjust the actual receive buffer size. There is no
  background delivery queue in this package. Pending calls reserve a bounded
  slot before they can enter the owner's mailbox.

  Broadcast and multicast start disabled. A consumer must opt in for each
  socket and explicitly identify a multicast interface when joining a group.
  """

  alias Wotex.UDP.{Endpoint, Error}

  @enforce_keys [:local]
  defstruct local: nil,
            max_datagram_bytes: 1_472,
            receive_buffer_bytes: 65_536,
            max_batch_datagrams: 32,
            max_pending_calls: 32,
            max_queued_send_bytes: 65_536,
            max_timeout_ms: 60_000,
            unicast_hops: 64,
            multicast_hops: 1,
            broadcast: false,
            multicast: false

  @type t :: %__MODULE__{
          local: Endpoint.t(),
          max_datagram_bytes: 1..65_507,
          receive_buffer_bytes: 2_048..4_194_304,
          max_batch_datagrams: 1..256,
          max_pending_calls: 1..256,
          max_queued_send_bytes: 1..4_194_304,
          max_timeout_ms: 1..60_000,
          unicast_hops: 1..255,
          multicast_hops: 0..255,
          broadcast: boolean(),
          multicast: boolean()
        }

  @doc "Validates a finite configuration and rejects unknown or duplicate options."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    allowed = [
      :local,
      :max_datagram_bytes,
      :receive_buffer_bytes,
      :max_batch_datagrams,
      :max_pending_calls,
      :max_queued_send_bytes,
      :max_timeout_ms,
      :unicast_hops,
      :multicast_hops,
      :broadcast,
      :multicast
    ]

    if Keyword.keyword?(options) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) do
      config = struct(__MODULE__, options)

      if valid?(config), do: {:ok, config}, else: invalid()
    else
      invalid()
    end
  end

  def new(_), do: invalid()

  @doc "Returns whether a configuration still satisfies all finite bounds."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = config) do
    match?(%Endpoint{kind: :bind}, config.local) and Endpoint.valid?(config.local) and
      bounds_valid?(config) and options_valid?(config)
  end

  defp bounds_valid?(config) do
    in_range?(config.max_datagram_bytes, 1, 65_507) and
      in_range?(config.receive_buffer_bytes, 2_048, 4_194_304) and
      config.receive_buffer_bytes >= config.max_datagram_bytes + 1 and
      in_range?(config.max_batch_datagrams, 1, 256) and
      in_range?(config.max_pending_calls, 1, 256) and
      in_range?(config.max_queued_send_bytes, 1, 4_194_304) and
      config.max_queued_send_bytes >= config.max_datagram_bytes and
      in_range?(config.max_timeout_ms, 1, 60_000)
  end

  defp options_valid?(config) do
    in_range?(config.unicast_hops, 1, 255) and
      in_range?(config.multicast_hops, 0, 255) and
      is_boolean(config.broadcast) and is_boolean(config.multicast)
  end

  defp in_range?(value, min, max), do: is_integer(value) and value >= min and value <= max

  defp invalid, do: {:error, %Error{kind: :invalid_config, operation: :config, reason: nil}}
end
