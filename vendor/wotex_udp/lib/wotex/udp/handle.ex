defmodule Wotex.UDP.Handle do
  @moduledoc """
  Opaque capability for one explicitly started UDP owner epoch.

  Pass this value to `Wotex.UDP` functions without inspecting or persisting
  its fields. A stopped owner cannot be reactivated by OS descriptor reuse.
  """

  @enforce_keys [
    :owner,
    :epoch,
    :admission,
    :max_timeout_ms,
    :max_datagram_bytes,
    :max_pending_calls,
    :max_queued_send_bytes
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            owner: pid(),
            epoch: reference(),
            admission: :atomics.atomics_ref(),
            max_timeout_ms: pos_integer(),
            max_datagram_bytes: pos_integer(),
            max_pending_calls: pos_integer(),
            max_queued_send_bytes: pos_integer()
          }

  @doc "Returns the maximum payload size, or `:error` for an invalid handle."
  @spec max_datagram_bytes(term()) :: pos_integer() | :error
  def max_datagram_bytes(%__MODULE__{max_datagram_bytes: maximum})
      when is_integer(maximum) and maximum > 0,
      do: maximum

  def max_datagram_bytes(_), do: :error
end
