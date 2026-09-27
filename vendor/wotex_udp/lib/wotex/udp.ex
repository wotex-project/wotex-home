defmodule Wotex.UDP do
  @moduledoc """
  Bounded UDP datagrams through an explicitly started, caller-owned process.

  Constructing an `Endpoint` or `Config` performs no I/O. `open/1` starts an
  owner linked to the caller and returns an opaque `Handle`. A long-lived
  consumer can instead put `child_spec/2` under its supervisor and obtain a
  handle from the started owner with `handle/1`. The consumer owns shutdown.

      {:ok, local} = Wotex.UDP.Endpoint.bind({127, 0, 0, 1}, 0)
      {:ok, config} = Wotex.UDP.Config.new(local: local)
      {:ok, handle} = Wotex.UDP.open(config)
      {:ok, bound} = Wotex.UDP.local(handle)
      :ok = Wotex.UDP.close(handle)

  Calls on an old epoch fail with `:stale_handle`, and calls after the owner
  dies fail with `:owner_lost`. Passive receives bound datagram size, count
  and elapsed time. No listener, automatic retry or payload decoder runs.
  UDP send success is local OS acceptance, not remote delivery.
  """

  alias Wotex.UDP.{Config, Datagram, Endpoint, Error, Handle, Owner}

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @doc "Explicitly starts and links one socket owner, returning its opaque handle."
  @spec open(Config.t()) :: result(Handle.t())
  def open(%Config{} = config) do
    case Owner.start(config) do
      {:ok, owner} ->
        Process.link(owner)
        Owner.handle(owner)

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.from_socket(:open, reason)}
    end
  end

  @doc "Returns a child specification for a consumer supervisor."
  @spec child_spec(Config.t(), keyword()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config, options \\ []) do
    Supervisor.child_spec({Owner, config}, options)
  end

  @doc "Gets a handle from a live supervised owner process."
  @spec handle(pid()) :: result(Handle.t())
  def handle(owner), do: Owner.handle(owner)

  @doc "Stops the owner and closes its socket and memberships."
  @spec close(Handle.t()) :: :ok | {:error, Error.t()}
  def close(handle), do: Owner.call(handle, :close, [])

  @doc "Returns the bound local endpoint, including an OS-assigned port."
  @spec local(Handle.t()) :: result(Endpoint.t())
  def local(handle), do: Owner.call(handle, :local, [])

  @doc "Sends one binary datagram before a finite timeout, without retry."
  @spec send(Handle.t(), Endpoint.t(), binary(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def send(handle, destination, data, timeout) do
    maximum = Handle.max_datagram_bytes(handle)

    cond do
      maximum == :error ->
        {:error, %Error{kind: :invalid_handle, operation: :send, reason: nil}}

      not is_binary(data) ->
        {:error, %Error{kind: :invalid_datagram, operation: :send, reason: nil}}

      byte_size(data) > maximum ->
        {:error, %Error{kind: :datagram_too_large, operation: :send, reason: nil}}

      true ->
        Owner.call(handle, :send, [destination, data, timeout])
    end
  end

  @doc "Receives one complete bounded datagram and its untrusted source."
  @spec recv(Handle.t(), non_neg_integer()) :: result(Datagram.t())
  def recv(handle, timeout), do: Owner.call(handle, :recv, [timeout])

  @doc "Receives at most `count` datagrams within one total deadline."
  @spec recv_batch(Handle.t(), pos_integer(), non_neg_integer()) :: result([Datagram.t()])
  def recv_batch(handle, count, timeout), do: Owner.call(handle, :recv_batch, [count, timeout])

  @doc "Joins a multicast group on an explicit IPv4 address or IPv6 interface index."
  @spec join(Handle.t(), Endpoint.t(), Endpoint.address() | non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def join(handle, group, interface), do: Owner.call(handle, :join, [group, interface])

  @doc "Leaves a multicast group on the interface previously used to join."
  @spec leave(Handle.t(), Endpoint.t(), Endpoint.address() | non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def leave(handle, group, interface), do: Owner.call(handle, :leave, [group, interface])
end
