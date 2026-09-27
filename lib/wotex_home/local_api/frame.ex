defmodule WotexHome.LocalAPI.Frame do
  @moduledoc """
  Bounded length-framed JSON for Home's local API.

  `encode_request/1` and `encode_response/1` add the wire length prefix.
  The matching decoders reject oversized bodies, repeated object names and
  excessive nesting before a handler sees a map. This protects parsing;
  authorization still belongs to the Store and server.
  """

  @max_request_bytes 65_536
  @max_response_bytes 1_048_576
  @max_depth 16

  @spec decode_request(binary()) :: {:ok, map()} | {:error, atom()}
  def decode_request(body) when is_binary(body) and byte_size(body) <= @max_request_bytes do
    with :ok <- check_depth(body),
         {:ok, decoded} <- strict_decode(body),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def decode_request(_body), do: {:error, :request_too_large}

  @spec encode_request(map()) :: {:ok, binary()} | {:error, atom()}
  def encode_request(request) when is_map(request) do
    try do
      body = JSON.encode!(request)

      if byte_size(body) <= @max_request_bytes and check_depth(body) == :ok,
        do: {:ok, <<byte_size(body)::unsigned-big-32, body::binary>>},
        else: {:error, :invalid_request}
    rescue
      _ -> {:error, :invalid_request}
    end
  end

  def encode_request(_request), do: {:error, :invalid_request}

  @spec decode_response(binary()) :: {:ok, map()} | {:error, atom()}
  def decode_response(body) when is_binary(body) and byte_size(body) <= @max_response_bytes do
    with :ok <- check_depth(body),
         {:ok, %{"api_version" => 1, "outcome" => outcome} = decoded} <- strict_decode(body),
         true <- outcome in ["ok", "error", "not_found"] do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def decode_response(_body), do: {:error, :response_too_large}

  @spec encode_response(map()) :: {:ok, binary()} | {:error, :response_too_large}
  def encode_response(response) when is_map(response) do
    body = JSON.encode!(response)

    if byte_size(body) <= @max_response_bytes,
      do: {:ok, <<byte_size(body)::unsigned-big-32, body::binary>>},
      else: {:error, :response_too_large}
  end

  defp strict_decode(body) do
    try do
      case JSON.decode(body, :ok,
             object_finish: fn pairs, old_acc ->
               keys = Enum.map(pairs, &elem(&1, 0))
               if length(keys) != length(Enum.uniq(keys)), do: throw(:duplicate_member)
               {Map.new(pairs), old_acc}
             end
           ) do
        {decoded, :ok, ""} -> {:ok, decoded}
        _ -> {:error, :invalid_json}
      end
    catch
      :throw, :duplicate_member -> {:error, :duplicate_member}
    end
  end

  defp check_depth(body), do: scan(body, 0, false, false)

  defp scan(<<>>, _depth, _in_string, _escaped), do: :ok

  defp scan(<<byte, rest::binary>>, depth, true, escaped) do
    cond do
      escaped -> scan(rest, depth, true, false)
      byte == ?\\ -> scan(rest, depth, true, true)
      byte == ?\" -> scan(rest, depth, false, false)
      true -> scan(rest, depth, true, false)
    end
  end

  defp scan(<<byte, rest::binary>>, depth, false, _escaped) do
    cond do
      byte == ?\" -> scan(rest, depth, true, false)
      byte in [?{, ?[] and depth + 1 > @max_depth -> {:error, :too_deep}
      byte in [?{, ?[] -> scan(rest, depth + 1, false, false)
      byte in [?}, ?]] -> scan(rest, depth - 1, false, false)
      true -> scan(rest, depth, false, false)
    end
  end
end
