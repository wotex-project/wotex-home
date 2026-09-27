defmodule WotexHome.Shelly.Gen2ReadPath do
  @moduledoc """
  One finite, read-only Shelly Gen2+ RPC exchange on a selected IPv4 LAN.

  `run/5` binds a passive Mint HTTP/1 socket to the selected local address,
  checks that binding before sending, posts a closed identity or switch-status
  request to `/rpc`, and closes the socket after one response. It never follows
  redirects, discovers a bridge, attaches a credential or retries a request.
  The response is parsed by `WotexHome.Shelly.Gen2RPC` as an untrusted report.

  HTTP is plaintext. Devices requiring Digest authentication or a qualified
  HTTPS identity need a separate transport profile; a 401 response fails
  closed. A successful result still needs exact model, component and firmware
  review before it becomes a Home Thing or observation.
  """

  alias WotexHome.Lifx.IPv4Scope
  alias WotexHome.Shelly.Gen2RPC

  @max_response_bytes 32_768
  @max_header_bytes 8_192
  @max_timeout_ms 5_000

  @doc "Reads one identity or switch-status frame from an in-scope numeric endpoint."
  @spec run(IPv4Scope.t(), tuple(), pos_integer(), Gen2RPC.query(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def run(%IPv4Scope{} = scope, address, port, query, rpc_id) do
    with {:ok, ^scope} <- IPv4Scope.new(scope.local, scope.prefix),
         true <- peer?(scope, address),
         true <- is_integer(port) and port in 1..65_535,
         {:ok, body} <- Gen2RPC.request(query, rpc_id) do
      deadline = System.monotonic_time(:millisecond) + @max_timeout_ms
      exchange(scope, address, port, body, query, rpc_id, deadline)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_read_target}
    end
  end

  def run(_, _, _, _, _), do: {:error, :invalid_read_target}

  defp peer?(scope, address) do
    IPv4Scope.contains_peer?(scope, address) or
      (scope.local == {127, 0, 0, 1} and address == scope.local)
  end

  defp exchange(scope, address, port, body, query, rpc_id, deadline) do
    host = address |> :inet.ntoa() |> to_string()

    options = [
      hostname: host,
      mode: :passive,
      protocols: [:http1],
      max_header_list_size: @max_header_bytes,
      transport_opts: [ip: scope.local, timeout: min(1_000, remaining(deadline))]
    ]

    case Mint.HTTP.connect(:http, address, port, options) do
      {:ok, conn} ->
        try do
          with :ok <- local_binding(conn, scope.local),
               {:ok, conn, ref} <-
                 Mint.HTTP.request(
                   conn,
                   "POST",
                   "/rpc",
                   [{"content-type", "application/json"}, {"accept", "application/json"}],
                   body
                 ),
               {:ok, response} <- receive_response(conn, ref, deadline, empty_response()),
               {:ok, bytes} <- valid_response(response),
               {:ok, report} <- Gen2RPC.response(bytes, rpc_id, query) do
            {:ok, report}
          else
            {:error, _conn, _error} -> {:error, :transport_error}
            {:error, reason} when is_atom(reason) -> {:error, reason}
            _ -> {:error, :transport_error}
          end
        after
          _ = Mint.HTTP.close(conn)
        end

      {:error, _reason} ->
        {:error, :transport_error}
    end
  end

  defp local_binding(conn, expected) do
    case :inet.sockname(Mint.HTTP.get_socket(conn)) do
      {:ok, {^expected, port}} when port > 0 -> :ok
      _ -> {:error, :wrong_local_binding}
    end
  end

  defp empty_response,
    do: %{status: nil, headers: nil, body: [], size: 0, done: false}

  defp receive_response(conn, ref, deadline, response) do
    case remaining(deadline) do
      0 ->
        {:error, :request_timeout}

      wait_ms ->
        case Mint.HTTP.recv(conn, 0, wait_ms) do
          {:ok, next_conn, frames} ->
            case accept_frames(frames, ref, response) do
              {:ok, %{done: true} = complete} -> {:ok, complete}
              {:ok, partial} -> receive_response(next_conn, ref, deadline, partial)
              {:error, _} = error -> error
            end

          {:error, _next_conn, _reason, _frames} ->
            {:error, :transport_error}
        end
    end
  end

  defp accept_frames(frames, ref, response) do
    Enum.reduce_while(frames, {:ok, response}, fn frame, {:ok, current} ->
      case accept_frame(frame, ref, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp accept_frame({:status, ref, status}, ref, %{status: nil} = response)
       when is_integer(status),
       do: {:ok, %{response | status: status}}

  defp accept_frame({:headers, ref, headers}, ref, %{status: status, headers: nil} = response)
       when is_integer(status) and is_list(headers) and length(headers) <= 32,
       do: {:ok, %{response | headers: headers}}

  defp accept_frame({:data, ref, bytes}, ref, %{headers: headers} = response)
       when is_list(headers) and is_binary(bytes) do
    size = response.size + byte_size(bytes)

    if size <= @max_response_bytes,
      do: {:ok, %{response | body: [bytes | response.body], size: size}},
      else: {:error, :response_too_large}
  end

  defp accept_frame({:done, ref}, ref, %{headers: headers} = response)
       when is_list(headers),
       do: {:ok, %{response | done: true}}

  defp accept_frame(_, _, _), do: {:error, :invalid_http_response}

  defp valid_response(%{status: 401}), do: {:error, :authentication_required}
  defp valid_response(%{status: status}) when status != 200, do: {:error, :unexpected_http_status}

  defp valid_response(%{headers: headers, body: chunks, done: true}) do
    content_types =
      for {name, value} <- headers,
          is_binary(name) and is_binary(value) and
            String.downcase(name, :ascii) == "content-type",
          do: String.downcase(value, :ascii)

    if length(content_types) == 1 and
         (hd(content_types) == "application/json" or
            String.starts_with?(hd(content_types), "application/json;")) do
      {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      {:error, :invalid_http_response}
    end
  end

  defp valid_response(_), do: {:error, :invalid_http_response}

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
