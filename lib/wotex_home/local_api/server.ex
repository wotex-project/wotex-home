defmodule WotexHome.LocalAPI.Server do
  @moduledoc """
  Opt-in, private Unix socket facade for held requests and redacted health.

  Every connection carries one versioned length-framed JSON request. The wire
  exposes no provisioning, raw database, rule activation or driver operation.
  The caller supplies a high-entropy credential issued by trusted local
  provisioning; the Store derives its principal and policy from durable state.
  """

  use GenServer
  import Bitwise

  alias WotexHome.Durable.{Receipt, Store}
  alias WotexHome.LocalAPI.Frame
  alias WotexHome.Mutation

  @max_request_bytes 65_536
  @request_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path)
    store = Keyword.get(opts, :store)

    with true <- is_binary(path) and byte_size(path) > 0 and byte_size(path) <= 100,
         true <- is_pid(store) and Process.alive?(store),
         :ok <- private_directory(Path.dirname(path)),
         :ok <- stale_socket(path),
         {:ok, listener} <- open_listener(path) do
      {acceptor, acceptor_ref} = spawn_monitor(fn -> accept_loop(listener, store) end)
      store_ref = Process.monitor(store)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         acceptor_ref: acceptor_ref,
         store_ref: store_ref,
         path: path
       }}
    else
      false -> {:stop, :invalid_local_api_config}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{store_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{acceptor_ref: ref} = state),
    do: {:stop, :listener_failed, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
    _ = File.rm(state.path)
    :ok
  end

  defp open_listener(path) do
    case :gen_tcp.listen(0, [
           :binary,
           {:ifaddr, {:local, String.to_charlist(path)}},
           {:active, false},
           {:backlog, 32}
         ]) do
      {:ok, listener} ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, listener}

          {:error, reason} ->
            _ = :gen_tcp.close(listener)
            _ = File.rm(path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp private_directory(directory) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        with :ok <- File.mkdir(directory),
             :ok <- File.chmod(directory, 0o700) do
          :ok
        else
          _ -> {:error, :invalid_socket_directory}
        end

      {:ok, stat} ->
        if stat.type == :directory and (stat.mode &&& 0o777) == 0o700,
          do: :ok,
          else: {:error, :invalid_socket_directory}

      _ ->
        {:error, :invalid_socket_directory}
    end
  end

  defp stale_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} when (stat.mode &&& 0o170000) == 0o140000 ->
        case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary], 100) do
          {:ok, socket} ->
            _ = :gen_tcp.close(socket)
            {:error, :already_running}

          {:error, _} ->
            case File.rm(path) do
              :ok -> :ok
              _ -> {:error, :invalid_socket_path}
            end
        end

      _ ->
        {:error, :invalid_socket_path}
    end
  end

  defp accept_loop(listener, store) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handle_socket(socket, store)
        _ = :gen_tcp.close(socket)
        accept_loop(listener, store)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        exit(:listener_failed)
    end
  end

  defp handle_socket(socket, store) do
    response =
      with {:ok, <<size::unsigned-big-32>>} <- :gen_tcp.recv(socket, 4, @request_timeout_ms),
           true <- size > 0 and size <= @max_request_bytes,
           {:ok, body} <- :gen_tcp.recv(socket, size, @request_timeout_ms),
           {:ok, request} <- Frame.decode_request(body) do
        dispatch(store, request)
      else
        false -> error(:request_too_large)
        {:error, reason} when is_atom(reason) -> error(reason)
        _ -> error(:invalid_request)
      end

    case Frame.encode_response(response) do
      {:ok, frame} -> :gen_tcp.send(socket, frame)
      {:error, _} -> :gen_tcp.send(socket, <<0, 0, 0, 0>>)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "health",
           "credential" => encoded
         } = request
       )
       when map_size(request) == 3 do
    with {:ok, credential} <- credential(encoded),
         {:ok, health} <- Store.authorized_health(store, credential) do
      ok(%{"health" => stringify_keys(health)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "submit",
           "credential" => encoded,
           "mutation" => input
         } = request
       )
       when map_size(request) == 4 do
    with {:ok, credential} <- credential(encoded),
         {:ok, mutation} <- Mutation.new(input),
         {:ok, receipt} <- Store.submit_request(store, credential, mutation) do
      ok(%{"receipt" => receipt_map(receipt)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "catalogue",
           "credential" => encoded,
           "watermark" => watermark,
           "after" => after_id,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 6 do
    with {:ok, credential} <- credential(encoded),
         {:ok, catalogue} <-
           Store.catalogue_page(store, credential, watermark, after_id, page_size) do
      ok(%{"catalogue" => stringify_keys(catalogue)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "snapshot",
           "credential" => encoded,
           "watermark" => watermark,
           "after" => after_key,
           "page_size" => page_size
         } = request
       )
       when map_size(request) == 6 do
    with {:ok, credential} <- credential(encoded),
         {:ok, snapshot} <-
           Store.snapshot_page(store, credential, watermark, after_key, page_size) do
      ok(%{"snapshot" => stringify_keys(snapshot)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(
         store,
         %{
           "api_version" => 1,
           "operation" => "status",
           "credential" => encoded,
           "authority_epoch" => epoch,
           "operation_id" => operation_id
         } = request
       )
       when map_size(request) == 5 do
    with {:ok, credential} <- credential(encoded) do
      case Store.request_status(store, credential, epoch, operation_id) do
        {:ok, receipt} -> ok(%{"receipt" => receipt_map(receipt)})
        :not_found -> %{"api_version" => 1, "outcome" => "not_found"}
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(_store, %{"api_version" => version}) when version != 1,
    do: error(:unsupported_api_version)

  defp dispatch(_store, _request), do: error(:unsupported_operation_or_fields)

  defp credential(encoded) when is_binary(encoded) and byte_size(encoded) <= 44 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, credential} when byte_size(credential) == 32 -> {:ok, credential}
      _ -> {:error, :invalid_credential}
    end
  end

  defp credential(_encoded), do: {:error, :invalid_credential}

  defp receipt_map(%Receipt{} = receipt) do
    %{
      "principal_id" => receipt.principal_id,
      "authority_epoch" => receipt.authority_epoch,
      "operation_id" => receipt.operation_id,
      "disposition" => Atom.to_string(receipt.disposition),
      "reason" => receipt.reason,
      "revision" => receipt.revision
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp ok(body), do: Map.merge(%{"api_version" => 1, "outcome" => "ok"}, body)

  defp error(reason),
    do: %{"api_version" => 1, "outcome" => "error", "reason" => Atom.to_string(reason)}
end
