defmodule ExMaude.Download do
  @moduledoc false

  @doc false
  @spec fetch(String.t(), Path.t(), keyword()) :: :ok | {:redirect, String.t()} | {:error, term()}
  # The installer provides a path inside its private temporary directory.
  # Exclusive creation prevents overwriting or following an existing file.
  # sobelow_skip ["Traversal.FileModule"]
  def fetch(url, destination, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout)

    case File.open(destination, [:write, :binary, :exclusive], fn file ->
           request(URI.parse(url), file, deadline, Keyword.fetch!(opts, :max_bytes))
         end) do
      {:ok, :ok} ->
        :ok

      {:ok, result} ->
        File.rm(destination)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(uri, file, deadline, limit) do
    scheme = if uri.scheme == "https", do: :https, else: :http

    transport_opts = [timeout: remaining(deadline)]

    transport_opts =
      if scheme == :https,
        do: Keyword.put(transport_opts, :cacerts, :public_key.cacerts_get()),
        else: transport_opts

    opts = [
      mode: :passive,
      protocols: [:http1],
      transport_opts: transport_opts
    ]

    case Mint.HTTP.connect(scheme, uri.host, uri.port, opts) do
      {:ok, conn} ->
        try do
          path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

          case Mint.HTTP.request(conn, "GET", path, [], nil) do
            {:ok, conn, _} -> receive_body(conn, file, deadline, limit, {0, nil})
            {:error, _, reason} -> {:error, reason}
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_body(conn, file, deadline, limit, {size, status}) do
    with remaining when remaining > 0 <- remaining(deadline),
         {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, remaining),
         {:continue, size, status} <- consume(responses, file, limit, size, status) do
      receive_body(conn, file, deadline, limit, {size, status})
    else
      0 -> {:error, :timeout}
      {:error, _, reason, _} -> {:error, reason}
      result -> result
    end
  end

  defp consume([], _, _, size, status), do: {:continue, size, status}

  defp consume([{:status, _, status} | rest], file, limit, size, _) do
    consume(rest, file, limit, size, status)
  end

  defp consume([{:headers, _, headers} | rest], file, limit, size, status) do
    cond do
      status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, "location", 0) do
          {_, location} -> {:redirect, location}
          nil -> {:error, :missing_redirect_location}
        end

      status != 200 ->
        {:error, {:http_status, status}}

      true ->
        consume(rest, file, limit, size, status)
    end
  end

  defp consume([{:data, _, chunk} | rest], file, limit, size, status) do
    if size + byte_size(chunk) > limit do
      {:error, :too_large}
    else
      with :ok <- IO.binwrite(file, chunk) do
        consume(rest, file, limit, size + byte_size(chunk), status)
      end
    end
  end

  defp consume([{:done, _} | _], _, _, _, 200), do: :ok
  defp consume([{:done, _} | _], _, _, _, status), do: {:error, {:http_status, status}}
  defp consume([{:error, _, reason} | _], _, _, _, _), do: {:error, reason}

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
