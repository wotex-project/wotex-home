defmodule Wotex.UDP.Backend do
  @moduledoc """
  Socket operations used by the explicit UDP owner.

  This module holds the Erlang socket in the owner process. Consumers use
  `Wotex.UDP`, which checks the owner epoch and normalizes owner loss. The
  backend performs passive reads only, with finite sizes and deadlines.
  """

  alias Wotex.UDP.{Config, Datagram, Endpoint, Error}

  @enforce_keys [:handle, :config]
  defstruct [:handle, :config]

  @type t :: %__MODULE__{handle: :socket.socket(), config: Config.t()}
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @doc """
  Opens a UDP socket in the caller process and binds it to `config.local`.

  The requested kernel receive buffer is finite; the host may round its
  actual size. A failed option or bind closes the newly opened socket.
  """
  @spec open(Config.t()) :: result(t())
  def open(%Config{} = config) do
    if Config.valid?(config) do
      family = config.local.family

      case :socket.open(family, :dgram, :udp) do
        {:ok, handle} ->
          with :ok <- :socket.setopt(handle, :socket, :rcvbuf, config.receive_buffer_bytes),
               :ok <- enable_broadcast(handle, config),
               :ok <- set_hops(handle, config),
               :ok <- :socket.bind(handle, Endpoint.sockaddr(config.local)) do
            {:ok, %__MODULE__{handle: handle, config: config}}
          else
            {:error, reason} ->
              :socket.close(handle)
              {:error, Error.from_socket(:open, reason)}
          end

        {:error, reason} ->
          {:error, Error.from_socket(:open, reason)}
      end
    else
      {:error, %Error{kind: :invalid_config, operation: :open, reason: nil}}
    end
  end

  def open(_), do: {:error, %Error{kind: :invalid_config, operation: :open, reason: nil}}

  @doc "Closes the socket. Its owner is responsible for lifecycle cleanup."
  @spec close(t()) :: :ok | {:error, Error.t()}
  def close(%__MODULE__{handle: handle}), do: normalize(:close, :socket.close(handle))

  @doc "Returns the bound local endpoint, including an OS-assigned port."
  @spec local(t()) :: result(Endpoint.t())
  def local(%__MODULE__{handle: handle}) do
    with {:ok, address} <- :socket.sockname(handle),
         {:ok, endpoint} <- Endpoint.from_sockaddr(address) do
      {:ok, endpoint}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.from_socket(:local, reason)}
    end
  end

  @doc """
  Sends one binary datagram to a validated destination before `timeout` ms.

  A successful result means the host accepted the bytes for sending; it does
  not prove network delivery. Oversize data and disallowed broadcast or
  multicast destinations fail before any socket call. No retry occurs.
  """
  @spec send(t(), Endpoint.t(), binary(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def send(%__MODULE__{handle: handle, config: config}, %Endpoint{} = destination, data, timeout)
      when is_binary(data) do
    with :ok <- check_timeout(config, timeout),
         :ok <- check_destination(config, destination),
         :ok <- check_size(data, config.max_datagram_bytes) do
      normalize(:send, :socket.sendto(handle, data, Endpoint.sockaddr(destination), timeout))
    end
  end

  def send(_, _, _, _),
    do: {:error, %Error{kind: :invalid_endpoint, operation: :send, reason: nil}}

  @doc """
  Receives one datagram and its source within `timeout` ms.

  A datagram larger than the configured limit is consumed and rejected. The
  result never contains a truncated payload. A zero timeout polls once.
  """
  @spec recv(t(), non_neg_integer()) :: result(Datagram.t())
  def recv(%__MODULE__{handle: handle, config: config}, timeout) do
    with :ok <- check_timeout(config, timeout),
         {:ok, {source, data}} <-
           :socket.recvfrom(handle, config.max_datagram_bytes + 1, [], timeout),
         :ok <- check_size(data, config.max_datagram_bytes),
         {:ok, endpoint} <- Endpoint.from_sockaddr(source) do
      {:ok, %Datagram{data: data, source: endpoint}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.from_socket(:recv, reason)}
    end
  end

  @doc """
  Receives at most `count` datagrams within one total deadline.

  `count` cannot exceed `config.max_batch_datagrams`. Once a datagram has
  arrived, a subsequent timeout returns the collected datagrams. An oversize
  datagram or socket error fails the batch and discards the partial result.
  """
  @spec recv_batch(t(), pos_integer(), non_neg_integer()) :: result([Datagram.t()])
  def recv_batch(%__MODULE__{config: config} = socket, count, timeout) do
    with :ok <- check_timeout(config, timeout),
         true <- is_integer(count) and count > 0 and count <= config.max_batch_datagrams do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_recv_batch(socket, count, deadline, [])
    else
      false -> {:error, %Error{kind: :invalid_batch_size, operation: :recv_batch, reason: nil}}
      error -> error
    end
  end

  @doc """
  Joins a multicast group on an explicit interface.

  For IPv4 pass the interface's numeric IPv4 address. For IPv6 pass its
  nonnegative interface index. The socket must have `multicast: true`.
  """
  @spec join(t(), Endpoint.t(), Endpoint.address() | non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def join(socket, group, interface), do: membership(socket, group, interface, :add_membership)

  @doc "Leaves a multicast group using the same group and interface as `join/3`."
  @spec leave(t(), Endpoint.t(), Endpoint.address() | non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def leave(socket, group, interface), do: membership(socket, group, interface, :drop_membership)

  defp do_recv_batch(_, 0, _, datagrams), do: {:ok, Enum.reverse(datagrams)}

  defp do_recv_batch(socket, count, deadline, datagrams) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    case recv(socket, remaining) do
      {:ok, datagram} -> do_recv_batch(socket, count - 1, deadline, [datagram | datagrams])
      {:error, %Error{kind: :timeout}} when datagrams != [] -> {:ok, Enum.reverse(datagrams)}
      error -> error
    end
  end

  defp membership(%__MODULE__{handle: handle, config: config}, group, interface, option) do
    with :ok <- check_destination(config, group),
         true <- group.kind == :multicast,
         {:ok, level, value} <- membership_value(group, interface) do
      normalize(option, :socket.setopt(handle, level, option, value))
    else
      false -> {:error, %Error{kind: :invalid_endpoint, operation: option, reason: nil}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp membership_value(%Endpoint{family: :inet, address: group}, interface)
       when is_tuple(interface) and tuple_size(interface) == 4 do
    case Endpoint.bind(interface, 0) do
      {:ok, _} -> {:ok, :ip, %{multiaddr: group, interface: interface}}
      error -> error
    end
  end

  defp membership_value(%Endpoint{family: :inet6, address: group}, interface)
       when is_integer(interface) and interface >= 0 do
    {:ok, :ipv6, %{multiaddr: group, interface: interface}}
  end

  defp membership_value(_, _),
    do: {:error, %Error{kind: :invalid_endpoint, operation: :membership, reason: nil}}

  defp check_destination(config, %Endpoint{} = destination) do
    cond do
      not Endpoint.valid?(destination) or destination.kind == :bind ->
        {:error, %Error{kind: :invalid_endpoint, operation: :send, reason: nil}}

      destination.family != config.local.family ->
        {:error, %Error{kind: :address_family, operation: :send, reason: nil}}

      destination.kind == :broadcast and not config.broadcast ->
        {:error, %Error{kind: :broadcast_disabled, operation: :send, reason: nil}}

      destination.kind == :multicast and not config.multicast ->
        {:error, %Error{kind: :multicast_disabled, operation: :send, reason: nil}}

      true ->
        :ok
    end
  end

  defp check_destination(_, _),
    do: {:error, %Error{kind: :invalid_endpoint, operation: :send, reason: nil}}

  defp check_timeout(config, timeout)
       when is_integer(timeout) and timeout >= 0 and timeout <= config.max_timeout_ms,
       do: :ok

  defp check_timeout(_, _),
    do: {:error, %Error{kind: :invalid_deadline, operation: :deadline, reason: nil}}

  defp check_size(data, maximum) when byte_size(data) <= maximum, do: :ok

  defp check_size(_, _),
    do: {:error, %Error{kind: :datagram_too_large, operation: :datagram, reason: nil}}

  defp enable_broadcast(_, %Config{broadcast: false}), do: :ok

  defp enable_broadcast(handle, %Config{broadcast: true}),
    do: :socket.setopt(handle, :socket, :broadcast, true)

  defp set_hops(handle, %Config{local: %Endpoint{family: :inet}} = config) do
    with :ok <- :socket.setopt(handle, :ip, :ttl, config.unicast_hops) do
      if config.multicast do
        :socket.setopt(handle, :ip, :multicast_ttl, config.multicast_hops)
      else
        :ok
      end
    end
  end

  defp set_hops(handle, %Config{local: %Endpoint{family: :inet6}} = config) do
    with :ok <- :socket.setopt(handle, :ipv6, :unicast_hops, config.unicast_hops) do
      if config.multicast do
        :socket.setopt(handle, :ipv6, :multicast_hops, config.multicast_hops)
      else
        :ok
      end
    end
  end

  defp normalize(_, :ok), do: :ok

  defp normalize(operation, {:ok, _}),
    do: {:error, %Error{kind: :socket, operation: operation, reason: :partial_send}}

  defp normalize(operation, {:error, reason}), do: {:error, Error.from_socket(operation, reason)}
end
