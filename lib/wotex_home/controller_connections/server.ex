defmodule WotexHome.ControllerConnections.Server do
  @moduledoc "Explicit bounded TLS transport for the existing Authority and finite pairing owner."
  use GenServer
  alias WotexHome.Authority
  alias WotexHome.ControllerConnections.{Binding, Codec, InstallationIdentity, PairingReview}
  alias WotexHome.LocalAPI.{Exchange, Frame}
  @limit 32

  def start_link(opts) do
    if Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) in [
           [:authority, :binding, :enabled, :identity],
           [:authority, :binding, :enabled, :identity, :name]
         ] do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    else
      {:error, :invalid_controller_listener_config}
    end
  end

  @doc "Trusted local invitation template; opens no pairing window."
  def template(server), do: GenServer.call(server, :template)
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    with true <- Keyword.get(opts, :enabled) == true,
         %Authority{} = authority <- Keyword.get(opts, :authority),
         owner when is_pid(owner) <- Authority.owner(authority),
         reviews when is_pid(reviews) <- resolve(authority.pairing_reviews),
         :ok <- PairingReview.bound_owner(reviews, owner),
         %InstallationIdentity{} = identity <- Keyword.get(opts, :identity),
         binding = Keyword.get(opts, :binding),
         :ok <- Binding.check(binding),
         {:ok, options} <- InstallationIdentity.server_options(identity),
         {:ok, listener} <- listen(binding, options) do
      Process.flag(:trap_exit, true)
      token = make_ref()
      parent = self()

      context = %{
        authority: authority,
        owner: owner,
        reviews: reviews,
        identity: identity,
        binding: binding
      }

      {acceptor, acceptor_ref} =
        :erlang.spawn_opt(fn -> accept(parent, token, listener, context) end, [:link, :monitor])

      {:ok,
       Map.merge(context, %{
         listener: listener,
         acceptor: acceptor,
         acceptor_ref: acceptor_ref,
         token: token,
         owner_ref: Process.monitor(owner),
         reviews_ref: Process.monitor(reviews),
         workers: MapSet.new(),
         timer: Process.send_after(self(), :fence, 1_000)
       })}
    else
      _ -> {:stop, :invalid_controller_listener_config}
    end
  rescue
    _ -> {:stop, :invalid_controller_listener_config}
  catch
    _, _ -> {:stop, :invalid_controller_listener_config}
  end

  @impl true
  def handle_call(:template, _from, state) do
    with :ok <- intact(state),
         {:ok, public} <- InstallationIdentity.descriptor(state.identity) do
      {:reply, {:ok, Map.put(public, "endpoint", Binding.endpoint(state.binding))}, state}
    else
      _ -> {:stop, :controller_listener_fenced, {:error, :controller_listener_unavailable}, state}
    end
  end

  def handle_call(:status, _from, state),
    do: {:reply, %{enabled: true, connections: MapSet.size(state.workers), limit: @limit}, state}

  @impl true
  def handle_info(:fence, state) do
    case intact(state) do
      :ok -> {:noreply, %{state | timer: Process.send_after(self(), :fence, 1_000)}}
      _ -> {:stop, :controller_listener_fenced, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when ref in [state.owner_ref, state.reviews_ref], do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{acceptor_ref: ref} = state),
    do: {:stop, :controller_listener_failed, state}

  def handle_info({token, :admitted, pid}, %{token: token} = state),
    do: {:noreply, %{state | workers: MapSet.put(state.workers, pid)}}

  def handle_info({token, :finished, pid}, %{token: token} = state),
    do: {:noreply, %{state | workers: MapSet.delete(state.workers, pid)}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    :ssl.close(state.listener)
    Process.exit(state.acceptor, :kill)
    :ok
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_controller_listener) |> Map.put(:message, :redacted)

  defp listen(binding, options) do
    family = if tuple_size(binding.address) == 8, do: [:inet6, ipv6_v6only: true], else: [:inet]

    case :ssl.listen(
           binding.port,
           family ++ [ip: binding.address, backlog: @limit, reuseaddr: true] ++ options
         ) do
      {:ok, listener} ->
        if :ssl.sockname(listener) == {:ok, {binding.address, binding.port}} do
          {:ok, listener}
        else
          :ssl.close(listener)
          {:error, :controller_listener_unavailable}
        end

      _ ->
        {:error, :controller_listener_unavailable}
    end
  end

  defp accept(parent, token, listener, context) do
    Process.flag(:trap_exit, true)
    parent_ref = Process.monitor(parent)
    Process.put(:controller_listener_workers, MapSet.new())

    try do
      accept_loop(parent, parent_ref, token, listener, context, MapSet.new())
    after
      for worker <- Process.get(:controller_listener_workers), do: Process.exit(worker, :kill)
      :ssl.close(listener)
      Process.demonitor(parent_ref, [:flush])
    end
  end

  defp accept_loop(parent, parent_ref, token, listener, context, workers) do
    workers = drain(parent, parent_ref, token, workers)
    Process.put(:controller_listener_workers, workers)

    if intact(context) != :ok, do: exit(:controller_listener_fenced)

    case :ssl.transport_accept(listener, 1_000) do
      {:ok, socket} ->
        if MapSet.size(workers) >= @limit do
          reject(socket)
          accept_loop(parent, parent_ref, token, listener, context, workers)
        else
          deadline = mono() + 5_000
          worker = spawn_link(fn -> wait_socket(token, socket, context, deadline) end)

          case :ssl.controlling_process(socket, worker) do
            :ok ->
              send(parent, {token, :admitted, worker})
              send(worker, {token, :serve})

              accept_loop(
                parent,
                parent_ref,
                token,
                listener,
                context,
                MapSet.put(workers, worker)
              )

            _ ->
              Process.exit(worker, :kill)
              :ssl.close(socket, 0)
              accept_loop(parent, parent_ref, token, listener, context, workers)
          end
        end

      {:error, :timeout} ->
        accept_loop(parent, parent_ref, token, listener, context, workers)

      _ ->
        :ok
    end
  end

  defp drain(parent, parent_ref, token, workers) do
    receive do
      {:EXIT, ^parent, _} ->
        exit(:controller_listener_closed)

      {:DOWN, ^parent_ref, :process, ^parent, _} ->
        exit(:controller_listener_closed)

      {:EXIT, worker, _} ->
        send(parent, {token, :finished, worker})
        drain(parent, parent_ref, token, MapSet.delete(workers, worker))
    after
      0 -> workers
    end
  end

  # Most SSL APIs require a completed handshake. Transfer the unadmitted
  # socket to a disposable owner and end that owner, without starting TLS or
  # depending on the platform's graceful pre-handshake close path.
  defp reject(socket) do
    owner =
      spawn_link(fn ->
        receive do
          :discard -> :ok
        after
          1_000 -> :ok
        end
      end)

    case :ssl.controlling_process(socket, owner) do
      :ok ->
        Process.exit(owner, :kill)

      _ ->
        Process.exit(owner, :kill)
        :ssl.close(socket, 0)
    end
  end

  defp wait_socket(token, socket, context, deadline) do
    try do
      receive do
        {^token, :serve} -> serve(socket, context, deadline)
      after
        remaining(deadline) -> :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    after
      :ssl.close(socket, 0)
    end
  end

  defp serve(socket, context, handshake_deadline) do
    handshake =
      bounded(handshake_deadline, fn ->
        with :ok <- intact(context),
             {:ok, socket} <- :ssl.handshake(socket, remaining(handshake_deadline)),
             {:ok, [protocol: :"tlsv1.3"]} <- :ssl.connection_information(socket, [:protocol]),
             :ok <- intact(context),
             do: {:ok, socket}
      end)

    with {:ok, socket} <- handshake do
      deadline = mono() + 5_000

      case read_frame(socket, deadline) do
        {:ok, <<"[", _::binary>> = body} ->
          bounded(deadline, fn -> pairing(socket, context, body, deadline) end)

        {:ok, body} ->
          response =
            case Frame.decode_request(body) do
              {:ok, request} ->
                if intact(context) == :ok,
                  do: Exchange.perform(context.authority, request, deadline),
                  else: error(:operation_unavailable)

              {:error, reason} ->
                error(reason)
            end

          send_ordinary(socket, context, response)

        {:error, reason} ->
          send_ordinary(socket, context, error(reason))
      end
    else
      _ -> :ok
    end
  end

  defp read_frame(socket, deadline) do
    with {:ok, <<size::32>>} <- :ssl.recv(socket, 4, remaining(deadline)),
         true <- size in 1..65_536,
         {:ok, first} <- :ssl.recv(socket, 1, remaining(deadline)),
         true <- first != "[" or size <= 8_192,
         {:ok, tail} <- read_tail(socket, size - 1, deadline),
         do: {:ok, first <> tail},
         else: (
           false -> {:error, :request_too_large}
           {:error, reason} when is_atom(reason) -> {:error, reason}
           _ -> {:error, :invalid_request}
         )
  end

  defp read_tail(_socket, 0, _deadline), do: {:ok, ""}
  defp read_tail(socket, size, deadline), do: :ssl.recv(socket, size, remaining(deadline))

  defp pairing(socket, context, body, deadline) do
    with {:ok, request} <- Codec.decode("request", body) do
      result =
        with {:ok, ref} <- Authority.pairing_offer(context.authority, request) do
          receive do
            {:controller_pairing_review, ^ref, :approved} ->
              if intact(context) == :ok and remaining(deadline) > 0,
                do: Authority.pairing_complete(context.authority, request),
                else: {:error, :pairing_unavailable}

            {:controller_pairing_review, ^ref, reason} ->
              {:error, reason}
          after
            remaining(deadline) -> {:error, :confirmation_denied}
          end
        end

      response =
        case result do
          {:ok, paired} ->
            Codec.encode_frame("paired", paired)

          {:error, reason} ->
            {:ok, digest} = Codec.request_digest(request)
            original = Map.take(request, ~w(controller_id invitation_id client_id request_id))

            Codec.encode_frame(
              "refused",
              Map.merge(original, %{
                "request_digest" => digest,
                "reason" => Atom.to_string(reason)
              })
            )
        end

      if intact(context) == :ok do
        case response do
          {:ok, frame} -> :ssl.send(socket, frame)
          _ -> :ok
        end
      end
    else
      _ -> :ok
    end
  end

  defp send_ordinary(socket, context, response) do
    if intact(context) == :ok do
      case Frame.encode_response(response) do
        {:ok, frame} -> :ssl.send(socket, frame)
        _ -> :ssl.send(socket, <<0::32>>)
      end
    end
  end

  defp intact(context) do
    with true <-
           Process.alive?(context.owner) and Authority.owner(context.authority) == context.owner,
         true <- resolve(context.authority.pairing_reviews) == context.reviews,
         true <- Process.alive?(context.reviews),
         :ok <- Binding.check(context.binding),
         {:ok, _} <- InstallationIdentity.server_options(context.identity),
         do: :ok,
         else: (_ -> {:error, :controller_listener_unavailable})
  rescue
    _ -> {:error, :controller_listener_unavailable}
  catch
    _, _ -> {:error, :controller_listener_unavailable}
  end

  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp resolve(name) when is_atom(name) and not is_nil(name), do: Process.whereis(name)
  defp resolve(_), do: nil

  defp bounded(deadline, callback) do
    owner = self()
    token = make_ref()

    watchdog =
      spawn_link(fn ->
        monitor = Process.monitor(owner)

        receive do
          {^token, :done} -> Process.demonitor(monitor, [:flush])
          {:DOWN, ^monitor, :process, ^owner, _} -> :ok
        after
          remaining(deadline) -> Process.exit(owner, :kill)
        end
      end)

    try do
      callback.()
    after
      send(watchdog, {token, :done})
    end
  end

  defp error(reason),
    do: %{"api_version" => 1, "outcome" => "error", "reason" => Atom.to_string(reason)}

  defp mono, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - mono())
end
