defmodule WotexHome.Lifx.Transport do
  @moduledoc "Caller-owned selected-interface datagram transport for LIFX exchanges."

  @callback send(term(), String.t(), binary()) :: :ok | {:error, atom()}
  @callback recv(term(), pos_integer()) ::
              {:ok, String.t(), binary()} | {:error, atom()}
end
