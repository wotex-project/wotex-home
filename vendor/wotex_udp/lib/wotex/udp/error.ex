defmodule Wotex.UDP.Error do
  @moduledoc """
  Classified failures at the datagram boundary.

  Errors contain the failing operation and a stable `kind`. `reason` retains
  only an operating-system atom when available. No datagram bytes, addresses,
  or arbitrary exception terms are embedded in an error, so callers can log
  an error without disclosing an untrusted payload.

  `:timeout` means the call's finite deadline expired. `:permission` maps
  operating-system access denials. `:socket` covers other host failures;
  callers can inspect its `reason` atom without depending on a particular OS.
  """

  defexception [:kind, :operation, :reason]

  @type kind ::
          :invalid_endpoint
          | :invalid_config
          | :invalid_deadline
          | :invalid_batch_size
          | :datagram_too_large
          | :invalid_datagram
          | :invalid_handle
          | :broadcast_disabled
          | :multicast_disabled
          | :unsupported_feature
          | :overload
          | :address_family
          | :timeout
          | :permission
          | :closed
          | :owner_lost
          | :stale_handle
          | :socket

  @type t :: %__MODULE__{kind: kind(), operation: atom(), reason: atom() | nil}

  @impl Exception
  def message(%__MODULE__{kind: kind, operation: operation}) do
    "UDP #{operation} failed: #{kind}"
  end

  @doc "Classifies a socket result without retaining payloads or raw arguments."
  @spec from_socket(atom(), term()) :: t()
  def from_socket(operation, reason) do
    kind =
      case reason do
        :timeout -> :timeout
        :eacces -> :permission
        :eperm -> :permission
        :enoprotoopt -> :unsupported_feature
        :eopnotsupp -> :unsupported_feature
        :enotsup -> :unsupported_feature
        :enobufs -> :overload
        :emsgsize -> :datagram_too_large
        :closed -> :closed
        _ -> :socket
      end

    %__MODULE__{kind: kind, operation: operation, reason: safe_reason(reason)}
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_), do: nil
end
