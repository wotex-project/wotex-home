defmodule WotexHome.Lifx.Transport do
  @moduledoc """
  Caller-owned selected-interface datagram transport for LIFX exchanges.

  Implement `send/3` and `recv/2` around a socket whose interface and source
  scope were selected by the host. Exchange paths use this behaviour so
  packet and session code can be tested without opening a socket. The adapter
  must enforce deadlines and return the real source endpoint with each reply.
  """

  @callback send(term(), String.t(), binary()) :: :ok | {:error, atom()}
  @callback recv(term(), pos_integer()) ::
              {:ok, String.t(), binary()} | {:error, atom()}
end
