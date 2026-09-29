defmodule WotexHome.Qualification.Artifacts do
  @moduledoc """
  Check content-addressed private evidence bytes cited by sanitized receipts.

  Files are named by lowercase SHA-256, held directly in one private 0700
  directory, and never copied into a report. Matching bytes are custody
  evidence, not proof of their physical origin or the assertions in a receipt.

  `verify/2` checks every digest cited by a sanitized receipt against the
  private artifact directory, with file and total-size limits. Keep raw
  captures there for the authorized reviewer; do not place them in generated
  reports or source control.
  """

  import Bitwise

  alias WotexHome.Qualification.Evidence

  @max_files 4_096
  @max_file_bytes 33_554_432
  @max_total_bytes 1_073_741_824

  @spec verify(String.t(), [map()]) :: {:ok, map()} | {:error, atom()}
  def verify(root, receipts)
      when is_binary(root) and is_list(receipts) and length(receipts) <= 512 do
    with true <- Path.type(root) == :absolute,
         {:ok, %{type: :directory, mode: mode, uid: uid}} <- File.lstat(root),
         true <- (mode &&& 0o777) == 0o700,
         {:ok, digests} <- required_digests(receipts),
         true <- length(digests) <= @max_files do
      Enum.reduce_while(digests, {:ok, 0}, fn digest, {:ok, total} ->
        case verify_one(root, digest, uid, total) do
          {:ok, next_total} -> {:cont, {:ok, next_total}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, total} -> {:ok, %{artifact_count: length(digests), total_bytes: total}}
        error -> error
      end
    else
      _ -> {:error, :invalid_artifact_store}
    end
  end

  def verify(_, _), do: {:error, :invalid_artifact_store}

  defp required_digests(receipts) do
    Enum.reduce_while(receipts, {:ok, MapSet.new()}, fn receipt, {:ok, digests} ->
      case Evidence.receipt(receipt) do
        {:ok, validated} ->
          {:cont, {:ok, Enum.reduce(validated["artifact_digests"], digests, &MapSet.put(&2, &1))}}

        _ ->
          {:halt, {:error, :invalid_artifact_store}}
      end
    end)
    |> case do
      {:ok, digests} -> {:ok, Enum.sort(digests)}
      error -> error
    end
  end

  defp verify_one(root, digest, uid, total) do
    path = Path.join(root, digest)

    with {:ok, %{type: :regular, mode: mode, uid: ^uid, size: size}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o600 and size <= @max_file_bytes and size >= 0,
         true <- total + size <= @max_total_bytes,
         {:ok, actual} <- sha256(path, size),
         true <- actual == digest do
      {:ok, total + size}
    else
      _ -> {:error, :artifact_missing_or_changed}
    end
  end

  defp sha256(path, expected_size) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, stream} ->
        try do
          hash_stream(stream, :crypto.hash_init(:sha256), 0, expected_size)
        after
          File.close(stream)
        end

      _ ->
        {:error, :artifact_missing_or_changed}
    end
  end

  defp hash_stream(stream, context, read, expected_size) do
    case IO.binread(stream, 1_048_576) do
      :eof when read == expected_size ->
        {:ok, :crypto.hash_final(context) |> Base.encode16(case: :lower)}

      bytes when is_binary(bytes) and read + byte_size(bytes) <= expected_size ->
        hash_stream(
          stream,
          :crypto.hash_update(context, bytes),
          read + byte_size(bytes),
          expected_size
        )

      _ ->
        {:error, :artifact_missing_or_changed}
    end
  end
end
