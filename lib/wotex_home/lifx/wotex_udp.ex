defmodule WotexHome.Lifx.WotexUdp do
  @moduledoc """
  Selected-address WoTEx UDP adapter for bounded LIFX exchanges.

  `open/1` binds a caller-owned WoTEx socket to the IPv4 address in a reviewed
  `WotexHome.Lifx.IPv4Scope`. Pass `{__MODULE__, adapter}` to a discovery,
  interview or read path, and close it when that host-owned session ends. The
  adapter accepts only canonical IPv4 endpoints within the selected prefix.
  LIFX discovery requests addressed to the selected prefix broadcast are sent
  as the standards-defined limited broadcast (`255.255.255.255`), which the
  pinned WoTEx endpoint contract can represent for every supported prefix.
  When a wider selected prefix makes an address ending in `.255` an ordinary
  host, Home retains the unicast route decision and uses WoTEx's explicitly
  broadcast-enabled IPv4 endpoint representation only as a send-policy
  compatibility tag. The destination address is unchanged; subnet role is
  always decided from the reviewed prefix, never from its final octet.
  One owner admits one operation and one 1,024-byte queued send at a time,
  reads passively, rejects oversize packets, and uses hop limit one. WoTEx
  reports OS send acceptance, not delivery.

  A host must still establish which physical interface owns the address and
  keep the socket lifecycle under supervision. This adapter holds no Store,
  credential, enrollment or command authority.
  """

  @behaviour WotexHome.Lifx.Transport

  alias Wotex.UDP
  alias Wotex.UDP.{Config, Datagram, Endpoint, Error}
  alias WotexHome.Lifx.IPv4Scope

  defmodule Route do
    @moduledoc "A socket-free description of one Home-to-WoTEx endpoint decision."

    @enforce_keys [
      :intent,
      :strategy,
      :requested_address,
      :effective_address,
      :port,
      :destination
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            intent: WotexHome.Lifx.Transport.intent(),
            strategy: :direct_unicast | :prefix_scoped_unicast_compat | :limited_broadcast,
            requested_address: Wotex.UDP.Endpoint.ipv4(),
            effective_address: Wotex.UDP.Endpoint.ipv4(),
            port: pos_integer(),
            destination: Wotex.UDP.Endpoint.t()
          }
  end

  @max_packet_bytes 1_024
  @receive_buffer_bytes 2_048
  @max_batch_datagrams 1
  @max_pending_calls 1
  @max_queued_send_bytes @max_packet_bytes
  @max_timeout_ms 10_000
  @send_timeout_ms 1_000
  @unicast_hops 1
  @lifx_port 56_700
  @limited_broadcast {255, 255, 255, 255}

  @enforce_keys [:handle, :scope]
  defstruct [:handle, :scope]

  @type t :: %__MODULE__{handle: Wotex.UDP.Handle.t(), scope: IPv4Scope.t()}

  @doc "Returns the exact capabilities and known limitation of the pinned adapter."
  @spec capabilities() :: map()
  def capabilities do
    %{
      address_family: :ipv4,
      selected_address_binding: true,
      discovery_broadcast: :limited,
      directed_broadcast_request: :translated_to_limited,
      unicast_last_octet_255: :prefix_scoped_endpoint_compatibility,
      endpoint_role_source: :selected_prefix,
      socket_owner: :caller_session,
      receive_mode: :passive,
      receive_buffer_bytes: @receive_buffer_bytes,
      max_datagram_bytes: @max_packet_bytes,
      max_batch_datagrams: @max_batch_datagrams,
      max_pending_calls: @max_pending_calls,
      max_queued_send_bytes: @max_queued_send_bytes,
      minimum_receive_timeout_ms: 1,
      max_receive_timeout_ms: @max_timeout_ms,
      send_timeout_ms: @send_timeout_ms,
      unicast_hops: @unicast_hops,
      broadcast: true,
      multicast: false,
      oversize_receive: :consume_and_reject,
      send_success: :local_os_acceptance,
      error_boundary: :stable_kind_atoms,
      owner_loss: :invalidates_handle
    }
  end

  @doc "Builds the exact inert socket policy used by one Home LIFX owner."
  @spec configuration(IPv4Scope.t()) :: {:ok, Config.t()} | {:error, atom()}
  def configuration(%IPv4Scope{} = scope) do
    with {:ok, ^scope} <- IPv4Scope.new(scope.local, scope.prefix),
         {:ok, local} <- Endpoint.bind(scope.local, 0),
         {:ok, config} <-
           Config.new(
             local: local,
             max_datagram_bytes: @max_packet_bytes,
             receive_buffer_bytes: @receive_buffer_bytes,
             max_batch_datagrams: @max_batch_datagrams,
             max_pending_calls: @max_pending_calls,
             max_queued_send_bytes: @max_queued_send_bytes,
             max_timeout_ms: @max_timeout_ms,
             unicast_hops: @unicast_hops,
             broadcast: true,
             multicast: false
           ) do
      {:ok, config}
    else
      {:error, %Error{kind: kind}} -> {:error, kind}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_interface_scope}
    end
  end

  def configuration(_), do: {:error, :invalid_interface_scope}

  @doc "Plans one endpoint without opening or using a socket."
  @spec plan_destination(IPv4Scope.t(), String.t(), WotexHome.Lifx.Transport.intent()) ::
          {:ok, Route.t()} | {:error, atom()}
  def plan_destination(%IPv4Scope{} = scope, endpoint, intent)
      when intent in [:discovery, :unicast] do
    with {:ok, ^scope} <- IPv4Scope.new(scope.local, scope.prefix),
         {:ok, address, port} <- parse_endpoint(endpoint) do
      plan(scope, address, port, intent)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_interface_scope}
    end
  end

  def plan_destination(_, _, _), do: {:error, :invalid_endpoint}

  @doc "Opens one passive socket on the exact selected local IPv4 address."
  @spec open(IPv4Scope.t()) :: {:ok, t()} | {:error, atom()}
  def open(%IPv4Scope{} = scope) do
    with {:ok, config} <- configuration(scope),
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
  def preflight(%__MODULE__{scope: scope}, endpoint, intent) do
    case plan_destination(scope, endpoint, intent) do
      {:ok, %Route{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def preflight(_, _, _), do: {:error, :invalid_transport}

  @impl true
  def send(%__MODULE__{handle: handle, scope: scope}, endpoint, packet)
      when is_binary(packet) and byte_size(packet) > 0 and
             byte_size(packet) <= @max_packet_bytes do
    with {:ok, route} <- plan_send(scope, endpoint) do
      map_result(UDP.send(handle, route.destination, packet, @send_timeout_ms))
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

  defp plan_send(scope, endpoint) do
    with {:ok, address, port} <- parse_endpoint(endpoint) do
      intent =
        if port == @lifx_port and address in [scope.broadcast, @limited_broadcast],
          do: :discovery,
          else: :unicast

      plan(scope, address, port, intent)
    end
  end

  defp plan(scope, address, @lifx_port, :discovery)
       when address == scope.broadcast or address == @limited_broadcast do
    case Endpoint.broadcast(@limited_broadcast, @lifx_port) do
      {:ok, destination} ->
        {:ok,
         %Route{
           intent: :discovery,
           strategy: :limited_broadcast,
           requested_address: address,
           effective_address: @limited_broadcast,
           port: @lifx_port,
           destination: destination
         }}

      _ ->
        {:error, :unsupported_discovery_broadcast}
    end
  end

  defp plan(_scope, _address, _port, :discovery), do: {:error, :out_of_scope}

  defp plan(scope, address, port, :unicast) do
    # Loopback permits an independent scripted peer on the same host address.
    # DiscoveryWindow still refuses to turn that self-source into a device.
    if IPv4Scope.contains_peer?(scope, address) or
         (scope.local == {127, 0, 0, 1} and address == scope.local) do
      case unicast_destination(address, port) do
        {:ok, strategy, destination} ->
          {:ok,
           %Route{
             intent: :unicast,
             strategy: strategy,
             requested_address: address,
             effective_address: address,
             port: port,
             destination: destination
           }}

        _ ->
          {:error, :invalid_endpoint}
      end
    else
      {:error, :out_of_scope}
    end
  end

  defp unicast_destination(address, port) do
    case Endpoint.unicast(address, port) do
      {:ok, destination} ->
        {:ok, :direct_unicast, destination}

      _ when elem(address, 3) == 255 ->
        # WoTEx's pinned endpoint contract uses the last octet as a
        # conservative send-policy classification. The backend ultimately
        # passes only this unchanged address and port to `sendto`; Home has
        # already established from the selected prefix that it is not the
        # network's directed broadcast. Keeping the endpoint tagged here also
        # requires the socket's explicit broadcast opt-in, so no restriction
        # is silently weakened.
        case Endpoint.broadcast(address, port) do
          {:ok, destination} ->
            {:ok, :prefix_scoped_unicast_compat, destination}

          _ ->
            {:error, :invalid_endpoint}
        end

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp parse_endpoint(endpoint) when is_binary(endpoint) and byte_size(endpoint) <= 64 do
    parts = if String.valid?(endpoint), do: String.split(endpoint, ":"), else: []

    case parts do
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
