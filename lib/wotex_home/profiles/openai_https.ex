defmodule WotexHome.Profiles.OpenAIHTTPS do
  @moduledoc """
  Performs one finite authenticated HTTPS POST to the selected generation peer.

  `post/4` receives a checked `WotexHome.Profiles.OpenAIEndpoint`, ephemeral key,
  UTF-8 request body and timeout in 1–30,000 milliseconds. It verifies the fixed
  API hostname before sending the key to `POST /v1/responses`. One absolute
  deadline covers connection, write, headers and incrementally bounded body.
  The calling worker owns and closes the socket.

  Success is `{:ok, response_bytes}` for a 200 JSON response with a body ceiling
  of 4,194,304 bytes. Content-Length, chunked and close-delimited framing are
  checked explicitly; redirects, compression and ambiguous framing refuse.
  Failures are closed unavailable, unknown, invalid_response or deadline_expired
  results rather than returned service error text.

  No request is retried. Unknown after a possible POST cannot prove that the
  model received nothing or stopped working. The transport neither parses a
  draft nor accepts a candidate;
  `WotexHome.Profiles.OpenAIWire.response/3` owns response extraction, and
  `WotexHome.Durable.Store` owns current source/export and settlement guards.
  """

  alias WotexHome.Profiles.OpenAIEndpoint
  @body_max 4_194_304
  @chunk_meta_max 262_144

  @doc "Uses one verified socket and one original deadline without redirects or retries."
  def post(endpoint, key, body, timeout) do
    with :ok <- OpenAIEndpoint.validate(endpoint),
         true <-
           is_binary(key) and byte_size(key) in 16..4096 and
             Regex.match?(~r/\Ask-[A-Za-z0-9_-]+\z/, key),
         true <- is_binary(body) and byte_size(body) in 1..2_101_248 and String.valid?(body),
         true <- is_integer(timeout) and timeout in 1..30000,
         {:ok, options} <- OpenAIEndpoint.options(endpoint),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      deadline = mono() + timeout

      case :ssl.connect(endpoint.address, endpoint.port, options, remaining(deadline)) do
        {:ok, socket} ->
          try do
            with {:ok, {address, port}} <- :ssl.peername(socket),
                 true <- address == endpoint.address and port == endpoint.port,
                 :ok <- send_request(socket, key, body, deadline) do
              normalize(read_response(socket, deadline))
            else
              {:error, reason} when reason in [:unknown, :deadline_expired] -> {:error, reason}
              _ -> {:error, :unavailable}
            end
          rescue
            _ -> {:error, :unknown}
          catch
            _, _ -> {:error, :unknown}
          after
            :ssl.close(socket)
          end

        {:error, :timeout} ->
          {:error, :deadline_expired}

        _ ->
          {:error, :unavailable}
      end
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp send_request(socket, key, body, deadline) do
    if remaining(deadline) == 0 do
      {:error, :deadline_expired}
    else
      request = [
        "POST /v1/responses HTTP/1.1\r\nHost: api.openai.com\r\n",
        "Authorization: Bearer ",
        key,
        "\r\nContent-Type: application/json\r\n",
        "Accept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ]

      with :ok <-
             :ssl.setopts(socket, send_timeout: remaining(deadline), send_timeout_close: true),
           :ok <- :ssl.send(socket, request) do
        :ok
      else
        {:error, :timeout} -> {:error, :deadline_expired}
        _ -> {:error, :unknown}
      end
    end
  end

  defp read_response(socket, deadline) do
    with {:ok, line} <- line(socket, deadline, 8192),
         {:ok, status} <- status(line) do
      if status == 200 do
        with {:ok, fields} <- headers(socket, deadline, [], byte_size(line), 0),
             {:ok, framing} <- framing(fields),
             :ok <- :ssl.setopts(socket, packet: :raw),
             do: body(socket, framing, deadline),
             else: (
               {:error, reason} when reason in [:unknown, :deadline_expired] -> {:error, reason}
               _ -> invalid()
             )
      else
        if status >= 200, do: {:error, :unavailable}, else: invalid()
      end
    else
      {:error, reason} when reason in [:unknown, :deadline_expired] -> {:error, reason}
      _ -> invalid()
    end
  end

  defp status(line) do
    case Regex.run(~r/\AHTTP\/1\.[01] ([1-5][0-9]{2}) [\x20-\x7e]*\r\n\z/, line) do
      [_, value] -> {:ok, String.to_integer(value)}
      _ -> invalid()
    end
  end

  defp headers(socket, deadline, fields, size, count, maximum \\ 32768)
  defp headers(_, _, _, size, count, maximum) when size > maximum or count > 64, do: invalid()

  defp headers(socket, deadline, fields, size, count, maximum) do
    with {:ok, line} <- line(socket, deadline, 8192),
         true <- size + byte_size(line) <= maximum do
      if line == "\r\n" do
        {:ok, Enum.reverse(fields)}
      else
        with {:ok, field} <- field(line),
             do:
               headers(
                 socket,
                 deadline,
                 [field | fields],
                 size + byte_size(line),
                 count + 1,
                 maximum
               ),
             else: (_ -> invalid())
      end
    else
      {:error, reason} when reason in [:unknown, :deadline_expired] -> {:error, reason}
      _ -> invalid()
    end
  end

  defp field(line) do
    case Regex.run(~r/\A([!#$%&'*+.^_`|~A-Za-z0-9-]+):([\x09\x20-\x7e]*)\r\n\z/, line) do
      [_, name, value] -> {:ok, {String.downcase(name), String.trim(value)}}
      _ -> invalid()
    end
  end

  defp framing(fields) do
    protected = ~w(content-length transfer-encoding content-type content-encoding)
    valid = Enum.all?(protected, fn key -> Enum.count(fields, &(elem(&1, 0) == key)) <= 1 end)
    map = Map.new(fields)
    media = map["content-type"]

    with true <- valid and is_binary(media),
         true <-
           Regex.match?(
             ~r/\Aapplication\/json(?:\s*;\s*charset\s*=\s*(?:"utf-8"|utf-8))?\z/,
             String.downcase(media)
           ),
         true <- Map.get(map, "content-encoding", "identity") |> String.downcase() == "identity" do
      case {map["content-length"], map["transfer-encoding"]} do
        {nil, nil} ->
          {:ok, :closed}

        {nil, value} when is_binary(value) ->
          if String.downcase(value) == "chunked", do: {:ok, :chunked}, else: invalid()

        {value, nil} when is_binary(value) ->
          with true <- Regex.match?(~r/\A[0-9]{1,10}\z/, value),
               size = String.to_integer(value),
               true <- size <= @body_max,
               do: {:ok, {:length, size}},
               else: (_ -> invalid())

        _ ->
          invalid()
      end
    else
      _ -> invalid()
    end
  end

  defp body(socket, {:length, size}, deadline), do: exact(socket, size, deadline, [])
  defp body(socket, :closed, deadline), do: closed(socket, deadline, [], 0)
  defp body(socket, :chunked, deadline), do: chunks(socket, deadline, [], 0, 0, 0)

  defp exact(_, 0, _, parts), do: {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}

  defp exact(socket, size, deadline, parts) do
    count = min(size, 16384)

    with {:ok, bytes} <- recv(socket, count, deadline),
         true <- byte_size(bytes) == count,
         do: exact(socket, size - count, deadline, [bytes | parts]),
         else: (
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp closed(socket, deadline, parts, size) do
    case recv(socket, 0, deadline) do
      {:ok, bytes} when byte_size(bytes) > 0 and size + byte_size(bytes) <= @body_max ->
        closed(socket, deadline, [bytes | parts], size + byte_size(bytes))

      {:error, :unknown} ->
        # A close is the body delimiter only in this explicitly selected framing.
        {:error, :unknown}

      {:error, :closed} ->
        {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, :deadline_expired} = error ->
        error

      _ ->
        invalid()
    end
  end

  defp chunks(_, _, _, _, count, _) when count > 4096, do: invalid()

  defp chunks(socket, deadline, parts, size, count, metadata) do
    with :ok <- :ssl.setopts(socket, packet: :line, packet_size: 1024),
         {:ok, header} <- line(socket, deadline, 1024),
         true <- Regex.match?(~r/\A[0-9A-Fa-f]{1,16}(?:;[\x20-\x7e]*)?\r\n\z/, header),
         total = metadata + byte_size(header),
         true <- total <= @chunk_meta_max,
         [hex | _] = String.split(String.trim_trailing(header, "\r\n"), ";", parts: 2),
         true <-
           Regex.match?(~r/\A[0-9A-Fa-f]{1,16}\z/, hex) and String.ends_with?(header, "\r\n"),
         amount = String.to_integer(hex, 16),
         true <- amount <= @body_max - size do
      if amount == 0 do
        with :ok <- :ssl.setopts(socket, packet: :line, packet_size: 8192),
             {:ok, trailers} <- headers(socket, deadline, [], total, 0, @chunk_meta_max),
             true <-
               Enum.all?(
                 trailers,
                 &(elem(&1, 0) not in ~w(content-length transfer-encoding content-type content-encoding))
               ),
             do: {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()},
             else: (_ -> invalid())
      else
        with true <- count < 4096,
             :ok <- :ssl.setopts(socket, packet: :raw),
             {:ok, bytes} <- exact(socket, amount, deadline, []),
             {:ok, "\r\n"} <- recv(socket, 2, deadline),
             do: chunks(socket, deadline, [bytes | parts], size + amount, count + 1, total),
             else: (
               {:error, reason} when reason in [:unknown, :deadline_expired, :closed] ->
                 failure(reason)

               _ ->
                 invalid()
             )
      end
    else
      {:error, reason} when reason in [:unknown, :deadline_expired, :closed] -> failure(reason)
      _ -> invalid()
    end
  end

  defp line(socket, deadline, maximum) do
    with {:ok, bytes} <- recv(socket, 0, deadline),
         true <- byte_size(bytes) <= maximum and String.ends_with?(bytes, "\r\n"),
         do: {:ok, bytes},
         else: (
           {:error, reason} -> failure(reason)
           _ -> invalid()
         )
  end

  defp recv(socket, length, deadline) do
    if remaining(deadline) == 0 do
      {:error, :deadline_expired}
    else
      case :ssl.recv(socket, length, remaining(deadline)) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :timeout} -> {:error, :deadline_expired}
        {:error, :closed} -> {:error, :closed}
        {:error, :emsgsize} -> invalid()
        {:error, :invalid_packet} -> invalid()
        {:error, {:invalid_packet, _}} -> invalid()
        _ -> {:error, :unknown}
      end
    end
  end

  defp failure(:closed), do: {:error, :unknown}
  defp failure(reason) when reason in [:unknown, :deadline_expired], do: {:error, reason}
  defp failure(_), do: invalid()
  defp normalize({:ok, bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp normalize({:error, :closed}), do: {:error, :unknown}

  defp normalize({:error, reason})
       when reason in [:unavailable, :unknown, :invalid_response, :deadline_expired],
       do: {:error, reason}

  defp normalize(_), do: invalid()
  defp remaining(deadline), do: max(0, deadline - mono())
  defp mono, do: System.monotonic_time(:millisecond)
  defp invalid, do: {:error, :invalid_response}
end
