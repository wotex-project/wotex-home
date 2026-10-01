defmodule WotexHome.Lifx.Transport do
  @moduledoc """
  Caller-owned selected-interface datagram transport for LIFX exchanges.

  Implement `send/3` and `recv/2` around a socket whose interface and source
  scope were selected by the host. Exchange paths use this behaviour so
  packet and session code can be tested without opening a socket. The adapter
  must enforce deadlines and return the real source endpoint with each reply.

  An adapter with endpoint limitations implements the optional `preflight/3`
  callback. Exchange paths call it before issuing correlation state or claiming
  durable work. A fixture without endpoint limitations may omit the callback.
  """

  @type intent :: :discovery | :unicast

  @callback send(term(), String.t(), binary()) :: :ok | {:error, atom()}
  @callback recv(term(), pos_integer()) ::
              {:ok, String.t(), binary()} | {:error, atom()}
  @callback preflight(term(), String.t(), intent()) :: :ok | {:error, atom()}

  @optional_callbacks preflight: 3

  @doc "Checks an adapter route without consuming protocol or durable state."
  @spec check({module(), term()}, String.t(), intent()) :: :ok | {:error, atom()}
  def check({module, handle}, endpoint, intent)
      when is_atom(module) and is_binary(endpoint) and intent in [:discovery, :unicast] do
    if function_exported?(module, :preflight, 3) do
      case module.preflight(handle, endpoint, intent) do
        :ok -> :ok
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :invalid_transport_result}
      end
    else
      :ok
    end
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  def check(_, _, _), do: {:error, :invalid_transport}
end
