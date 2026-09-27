defmodule WotexHome.LocalAPI.Client do
  @moduledoc """
  Bounded one-request client for Home's private Unix socket.

  Credentials remain caller-owned. A response confirms only the API result;
  a lost response to a mutation must be resolved with its original operation
  ID and status query, never a new command ID.
  """

  import Bitwise

  alias WotexHome.LocalAPI.Frame
  alias WotexHome.LocalAPI.PeerIdentity

  @max_response_bytes 1_048_576

  @spec request(String.t(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def request(path, request, timeout_ms \\ 5_000)

  def request(path, request, timeout_ms)
      when is_binary(path) and byte_size(path) > 0 and byte_size(path) <= 100 and
             is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= 15_000 do
    with true <- Path.type(path) == :absolute,
         {:ok, owner_uid} <- private_endpoint(path),
         {:ok, frame} <- Frame.encode_request(request) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      case :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, {:active, false}, {:send_timeout, timeout_ms}],
             remaining(deadline)
           ) do
        {:ok, socket} ->
          try do
            with :ok <- PeerIdentity.verify(socket, owner_uid) do
              exchange(socket, frame, deadline)
            end
          after
            :ok = :gen_tcp.close(socket)
          end

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, _reason} ->
          {:error, :socket_unavailable}
      end
    else
      false -> {:error, :invalid_socket_path}
      {:error, reason} -> {:error, reason}
    end
  end

  def request(_path, _request, _timeout_ms), do: {:error, :invalid_client_request}

  defp private_endpoint(path) do
    with {:ok, parent} <- File.lstat(Path.dirname(path)),
         {:ok, endpoint} <- File.lstat(path),
         true <-
           parent.type == :directory and (parent.mode &&& 0o777) == 0o700 and
             endpoint.type == :other and (endpoint.mode &&& 0o170000) == 0o140000 and
             (endpoint.mode &&& 0o777) == 0o600 and parent.uid == endpoint.uid do
      {:ok, endpoint.uid}
    else
      _ -> {:error, :invalid_socket_path}
    end
  end

  defp exchange(socket, frame, deadline) do
    with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
         :ok <- :gen_tcp.send(socket, frame),
         {:ok, <<size::unsigned-big-32>>} <- :gen_tcp.recv(socket, 4, remaining(deadline)),
         true <- size > 0 and size <= @max_response_bytes,
         {:ok, body} <- :gen_tcp.recv(socket, size, remaining(deadline)),
         {:ok, response} <- Frame.decode_response(body) do
      {:ok, response}
    else
      false ->
        {:error, :response_too_large}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} when reason in [:invalid_response, :response_too_large] ->
        {:error, reason}

      _ ->
        {:error, :socket_unavailable}
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
