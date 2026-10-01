defmodule WotexHome.Hue.ReadPath do
  @moduledoc """
  One finite HTTPS-only Hue v2 read on a selected IPv4 LAN.

  Trusted callers resolve an application key per request and supply independently
  reviewed BridgeTLS inputs. TLS verifies the CA chain, validity, bridge ID and
  exact peer certificate before sending that key. Numeric endpoints and local
  binding prevent DNS rebinding; no redirects, retries or mutations are encoded.
  Results are bounded bridge reports, never enrolled or physically qualified
  Home state. An unauthenticated discovery hint cannot be used as trust.
  """

  alias WotexHome.Lifx.IPv4Scope
  alias WotexHome.Hue.{BridgeTLS, V2}

  @max_response_bytes 262_144
  @max_header_bytes 8_192
  @max_timeout_ms 5_000

  @spec run(IPv4Scope.t(), tuple(), pos_integer(), map(), binary(), term()) ::
          {:ok, list()} | {:error, atom()}
  def run(%IPv4Scope{} = scope, address, port, trust, key, query) do
    with {:ok, ^scope} <- IPv4Scope.new(scope.local, scope.prefix),
         true <- peer?(scope, address),
         true <- is_integer(port) and port in 1..65_535,
         true <- is_binary(key) and key =~ ~r/\A[A-Za-z0-9_-]{16,128}\z/,
         {:ok, tls} <- BridgeTLS.options(trust),
         {:ok, path} <- V2.path(query) do
      deadline = System.monotonic_time(:millisecond) + @max_timeout_ms
      exchange(scope, address, port, trust, tls, key, query, path, deadline)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_read_target}
    end
  end

  def run(_, _, _, _, _, _), do: {:error, :invalid_read_target}

  defp peer?(scope, address) do
    IPv4Scope.contains_peer?(scope, address) or
      (scope.local == {127, 0, 0, 1} and address == scope.local)
  end

  defp exchange(scope, address, port, trust, tls, key, query, path, deadline) do
    options = [
      hostname: trust.bridge_id,
      mode: :passive,
      protocols: [:http1],
      max_header_list_size: @max_header_bytes,
      transport_opts:
        tls ++
          [
            ip: scope.local,
            timeout: min(1_000, remaining(deadline)),
            send_timeout: 1_000,
            send_timeout_close: true
          ]
    ]

    case Mint.HTTP.connect(:https, address, port, options) do
      {:ok, conn} ->
        try do
          with :ok <- BridgeTLS.check_socket(Mint.HTTP.get_socket(conn), scope.local, trust),
               {:ok, conn, ref} <-
                 Mint.HTTP.request(
                   conn,
                   "GET",
                   path,
                   [{"hue-application-key", key}, {"accept", "application/json"}],
                   nil
                 ),
               {:ok, response} <- receive_response(conn, ref, deadline, empty_response()),
               {:ok, bytes} <- valid_response(response),
               {:ok, reports} <- V2.response(bytes, query, trust.bridge_id) do
            {:ok, reports}
          else
            {:error, _conn, _error} -> {:error, :transport_error}
            {:error, reason} when is_atom(reason) -> {:error, reason}
            _ -> {:error, :transport_error}
          end
        after
          _ = Mint.HTTP.close(conn)
        end

      {:error, _reason} ->
        {:error, :tls_unverified}
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

  defp valid_response(%{status: status}) when status in [401, 403],
    do: {:error, :authentication_required}

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
