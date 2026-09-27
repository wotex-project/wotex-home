defmodule WotexHome.Lifx.WotexUdp do
  @moduledoc """
  Selected-address WoTEx UDP adapter for bounded LIFX exchanges.

  `open/1` binds a caller-owned WoTEx socket to the IPv4 address in a reviewed
  `WotexHome.Lifx.IPv4Scope`. Pass `{__MODULE__, adapter}` to a discovery,
  interview or read path, and close it when that host-owned session ends. The
  adapter accepts only canonical IPv4 endpoints within the selected prefix or
  its exact directed broadcast. WoTEx reports OS send acceptance, not delivery.

  A host must still establish which physical interface owns the address and
  keep the socket lifecycle under supervision. This adapter holds no Store,
  credential, enrollment or command authority.
  """

  @behaviour WotexHome.Lifx.Transport

  alias Wotex.UDP
  alias Wotex.UDP.{Config, Datagram, Endpoint, Error}
  alias WotexHome.Lifx.IPv4Scope

  @max_packet_bytes 1_024
  @max_timeout_ms 10_000
  @send_timeout_ms 1_000
  @lifx_port 56_700

  @enforce_keys [:handle, :scope]
  defstruct [:handle, :scope]

  @type t :: %__MODULE__{handle: Wotex.UDP.Handle.t(), scope: IPv4Scope.t()}

  @doc "Opens one passive socket on the exact selected local IPv4 address."
  @spec open(IPv4Scope.t()) :: {:ok, t()} | {:error, atom()}
  def open(%IPv4Scope{} = scope) do
    with {:ok, ^scope} <- IPv4Scope.new(scope.local, scope.prefix),
         {:ok, local} <- Endpoint.bind(scope.local, 0),
         {:ok, config} <-
           Config.new(
             local: local,
             broadcast: true,
             max_datagram_bytes: @max_packet_bytes,
             max_timeout_ms: @max_timeout_ms
           ),
         {:ok, handle} <- UDP.open(config) do
      case UDP.local(handle) do
        {:ok, %Endpoint{address: address, port: port}}
        when address == scope.local and port > 0 ->
          {:ok, %__MODULE__{handle: handle, scope: scope}}

        _ ->
          UDP.close(handle)
          {:error, :wrong_local_binding}
      end
    else
      {:error, %Error{kind: kind}} -> {:error, kind}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_interface_scope}
    end
  end

  def open(_), do: {:error, :invalid_interface_scope}

  @doc "Returns the bound endpoint so a trusted host can inspect its local port."
  @spec local(t()) :: {:ok, Endpoint.t()} | {:error, atom()}
  def local(%__MODULE__{handle: handle}), do: map_result(UDP.local(handle))

  @doc "Closes the caller-owned socket and invalidates its WoTEx handle."
  @spec close(t()) :: :ok | {:error, atom()}
  def close(%__MODULE__{handle: handle}), do: map_result(UDP.close(handle))

  @impl true
  def send(%__MODULE__{handle: handle, scope: scope}, endpoint, packet)
      when is_binary(packet) and byte_size(packet) > 0 and
             byte_size(packet) <= @max_packet_bytes do
    with {:ok, address, port} <- parse_endpoint(endpoint),
         {:ok, destination} <- destination(scope, address, port) do
      map_result(UDP.send(handle, destination, packet, @send_timeout_ms))
    end
  end

  def send(_, _, _), do: {:error, :invalid_datagram}

  @impl true
  def recv(%__MODULE__{handle: handle}, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@max_timeout_ms do
    case UDP.recv(handle, timeout_ms) do
      {:ok, %Datagram{source: %Endpoint{address: address, port: port}, data: data}}
      when tuple_size(address) == 4 and is_binary(data) and
             byte_size(data) <= @max_packet_bytes ->
        {:ok, "#{:inet.ntoa(address)}:#{port}", data}

      {:ok, _} ->
        {:error, :invalid_datagram}

      other ->
        map_result(other)
    end
  end

  def recv(_, _), do: {:error, :invalid_timeout}

  defp destination(scope, address, @lifx_port) when address == scope.broadcast do
    case Endpoint.broadcast(address, @lifx_port) do
      {:ok, endpoint} -> {:ok, endpoint}
      _ -> {:error, :broadcast_scope_unsupported}
    end
  end

  defp destination(scope, address, port) do
    # Loopback permits an independent scripted peer on the same host address.
    # DiscoveryWindow still refuses to turn that self-source into a device.
    if IPv4Scope.contains_peer?(scope, address) or
         (scope.local == {127, 0, 0, 1} and address == scope.local),
       do: map_result(Endpoint.unicast(address, port)),
       else: {:error, :out_of_scope}
  end

  defp parse_endpoint(endpoint) when is_binary(endpoint) and byte_size(endpoint) <= 64 do
    case String.split(endpoint, ":") do
      [host, port_text] ->
        with {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(host)),
             {port, ""} <- Integer.parse(port_text),
             true <- port in 1..65_535,
             true <- endpoint == "#{:inet.ntoa(address)}:#{port}" do
          {:ok, address, port}
        else
          _ -> {:error, :invalid_endpoint}
        end

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp parse_endpoint(_), do: {:error, :invalid_endpoint}

  defp map_result({:error, %Error{kind: kind}}), do: {:error, kind}
  defp map_result(other), do: other
end
