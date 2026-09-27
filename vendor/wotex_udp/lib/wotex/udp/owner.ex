defmodule Wotex.UDP.Owner do
  @moduledoc """
  An explicitly started process that owns one UDP socket and one owner epoch.

  A consumer may place this process under its own supervisor. Passive reads
  have finite deadlines and no unsolicited datagrams enter the owner's
  mailbox. An atomic admission counter bounds pending calls and queued send
  bytes before a call enters that mailbox. The operating system owns its
  receive buffer. Each call carries an absolute deadline; an expired queued
  send is discarded before socket I/O. A timed-out call keeps its admission
  reservation until the owner drains it. Closing this process releases the
  socket and memberships.
  """

  use GenServer

  alias Wotex.UDP.{Admission, Backend, Config, Error, Handle}

  @doc "Starts one socket owner linked to the caller. No global name is used."
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @doc "Starts an owner without linking until socket admission has succeeded."
  @spec start(Config.t()) :: GenServer.on_start()
  def start(%Config{} = config), do: GenServer.start(__MODULE__, config)

  @doc "Gets the opaque handle for this owner's current epoch."
  @spec handle(pid()) :: {:ok, Handle.t()} | {:error, Error.t()}
  def handle(owner), do: call_owner(owner, :handle, 5_000)

  @doc "Calls an operation only when its handle matches the live owner epoch."
  @spec call(Handle.t(), atom(), [term()]) :: term()
  def call(
        %Handle{
          owner: owner,
          epoch: epoch,
          admission: admission,
          max_timeout_ms: limit,
          max_pending_calls: max_calls,
          max_queued_send_bytes: max_bytes
        },
        operation,
        args
      )
      when is_pid(owner) and is_reference(epoch) and
             is_integer(limit) and limit > 0 and is_integer(max_calls) and max_calls > 0 and
             is_integer(max_bytes) and max_bytes > 0 do
    queued_bytes = queued_bytes(operation, args)
    timeout = call_timeout(operation, args, limit)
    deadline = System.monotonic_time(:millisecond) + timeout

    case Admission.acquire(admission, max_calls, max_bytes, queued_bytes) do
      :ok ->
        call_owner(owner, {operation, epoch, args, deadline}, timeout + 100)

      error ->
        error
    end
  end

  def call(_, operation, _),
    do: {:error, %Error{kind: :invalid_handle, operation: operation, reason: nil}}

  @impl GenServer
  def init(config) do
    case Backend.open(config) do
      {:ok, socket} ->
        {:ok,
         %{
           socket: socket,
           epoch: make_ref(),
           admission: :atomics.new(1, signed: false),
           config: config
         }}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call(:handle, _, state) do
    handle = %Handle{
      owner: self(),
      epoch: state.epoch,
      admission: state.admission,
      max_timeout_ms: state.config.max_timeout_ms,
      max_datagram_bytes: state.config.max_datagram_bytes,
      max_pending_calls: state.config.max_pending_calls,
      max_queued_send_bytes: state.config.max_queued_send_bytes
    }

    {:reply, {:ok, handle}, state}
  end

  def handle_call({operation, epoch, args, deadline}, _, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    result =
      cond do
        epoch != state.epoch ->
          {:error, %Error{kind: :stale_handle, operation: :owner, reason: nil}}

        remaining < 0 ->
          {:error, %Error{kind: :timeout, operation: operation, reason: nil}}

        true ->
          dispatch(state.socket, operation, args, remaining)
      end

    Admission.release(
      state.admission,
      state.config.max_queued_send_bytes,
      queued_bytes(operation, args)
    )

    if operation == :close and result == :ok do
      {:stop, :normal, :ok, state}
    else
      {:reply, result, state}
    end
  end

  @impl GenServer
  def terminate(_, state), do: Backend.close(state.socket)

  defp call_owner(owner, request, timeout) do
    GenServer.call(owner, request, timeout)
  catch
    :exit, {:timeout, _} -> {:error, %Error{kind: :timeout, operation: :owner, reason: nil}}
    :exit, _ -> {:error, %Error{kind: :owner_lost, operation: :owner, reason: nil}}
  end

  defp queued_bytes(:send, [_, data, _]) when is_binary(data), do: byte_size(data)
  defp queued_bytes(_, _), do: 0

  defp call_timeout(operation, args, limit) when operation in [:send, :recv, :recv_batch] do
    case List.last(args) do
      timeout when is_integer(timeout) and timeout >= 0 and timeout <= limit -> timeout
      _ -> limit
    end
  end

  defp call_timeout(_, _, limit), do: limit

  defp dispatch(_, :close, [], _), do: :ok
  defp dispatch(socket, :local, [], _), do: Backend.local(socket)

  defp dispatch(socket, :send, [destination, data, timeout], remaining),
    do: Backend.send(socket, destination, data, effective_timeout(socket, timeout, remaining))

  defp dispatch(socket, :recv, [timeout], remaining),
    do: Backend.recv(socket, effective_timeout(socket, timeout, remaining))

  defp dispatch(socket, :recv_batch, [count, timeout], remaining),
    do: Backend.recv_batch(socket, count, effective_timeout(socket, timeout, remaining))

  defp dispatch(socket, :join, [group, interface], _), do: Backend.join(socket, group, interface)
  defp dispatch(socket, :leave, [group, interface], _), do: Backend.leave(socket, group, interface)

  defp effective_timeout(%Backend{config: %Config{max_timeout_ms: limit}}, timeout, remaining)
       when is_integer(timeout) and timeout >= 0 and timeout <= limit,
       do: min(timeout, remaining)

  defp effective_timeout(_, timeout, _), do: timeout
end
