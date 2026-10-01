defmodule WotexHome.Lifx.CaptureTransport do
  @moduledoc false

  @behaviour WotexHome.Lifx.Transport

  @max_packet_bytes 1_024
  @max_endpoint_bytes 64

  @impl true
  def preflight({transport, handle, _token}, endpoint, intent),
    do: WotexHome.Lifx.Transport.check({transport, handle}, endpoint, intent)

  @impl true
  def send({transport, handle, token}, endpoint, packet)
      when is_binary(endpoint) and byte_size(endpoint) <= @max_endpoint_bytes and
             is_binary(packet) and byte_size(packet) <= @max_packet_bytes do
    case transport.send(handle, endpoint, packet) do
      :ok ->
        send(self(), {:lifx_capture_datagram, token, :outbound_accepted, endpoint, packet})
        :ok

      other ->
        other
    end
  end

  def send(_, _, _), do: {:error, :capture_budget_exceeded}

  @impl true
  def recv({transport, handle, token}, timeout_ms) do
    case transport.recv(handle, timeout_ms) do
      {:ok, endpoint, bytes} = result
      when is_binary(endpoint) and byte_size(endpoint) <= @max_endpoint_bytes and
             is_binary(bytes) and byte_size(bytes) <= @max_packet_bytes ->
        send(self(), {:lifx_capture_datagram, token, :inbound, endpoint, bytes})
        result

      {:ok, _, _} ->
        {:error, :capture_budget_exceeded}

      other ->
        other
    end
  end
end
