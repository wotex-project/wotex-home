defmodule WotexHome.Profiles.DocumentChunks do
  @moduledoc """
  Splits retained UTF-8 documents into one canonical bounded chunk sequence.

  `encode/2` uses maximal chunks of at most 4,096 bytes without splitting a
  UTF-8 codepoint or changing the original bytes. The caller supplies the total
  document ceiling; empty or invalid UTF-8 documents refuse.

  `decode/2` accepts at most 256 chunks and requires the exact encoder boundaries.
  The result preserves byte identity for historical witnesses, but it does not
  validate the document's schema or establish custody.
  """

  @doc "Splits without changing bytes or splitting a UTF-8 codepoint."
  def encode(bytes, maximum)
      when is_binary(bytes) and is_integer(maximum) and maximum > 0 do
    cond do
      byte_size(bytes) > maximum -> {:error, :external_profile_limit}
      bytes == "" or not String.valid?(bytes) -> invalid()
      true -> split(bytes, [])
    end
  end

  def encode(_, _), do: invalid()

  @doc "Accepts only the encoder's exact chunk boundaries."
  def decode(chunks, maximum) when is_list(chunks) and length(chunks) in 1..256 do
    if Enum.all?(chunks, &(is_binary(&1) and byte_size(&1) in 1..4096)) do
      bytes = IO.iodata_to_binary(chunks)

      case encode(bytes, maximum) do
        {:ok, ^chunks} -> {:ok, bytes}
        {:error, _} = error -> error
        _ -> invalid()
      end
    else
      invalid()
    end
  end

  def decode(chunks, _) when is_list(chunks) and length(chunks) > 256,
    do: {:error, :external_profile_limit}

  def decode(_, _), do: invalid()

  defp split("", chunks), do: {:ok, Enum.reverse(chunks)}
  defp split(_, chunks) when length(chunks) == 256, do: {:error, :external_profile_limit}

  defp split(bytes, chunks) do
    size = boundary(bytes, min(4096, byte_size(bytes)))
    <<chunk::binary-size(size), rest::binary>> = bytes
    split(rest, [chunk | chunks])
  end

  defp boundary(bytes, size) do
    if String.valid?(binary_part(bytes, 0, size)), do: size, else: boundary(bytes, size - 1)
  end

  defp invalid, do: {:error, :invalid_document_chunks}
end
