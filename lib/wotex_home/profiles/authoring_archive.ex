defmodule WotexHome.Profiles.AuthoringArchive do
  @moduledoc """
  Frames a recovery database with legacy profiles and tagged authoring objects.

  `encode/3` embeds the legacy archive and a sorted, unique tagged-object set.
  Tagged objects are revalidated as complete `WotexHome.Profiles.AuthoringObject`
  frames, with at most 128 objects and 4,194,304 total framed bytes. `decode/1`
  returns the database and inert byte records for quarantined restoration.

  This is bounded framing, not encryption or activation. Archive authentication,
  database integrity, private publication and reviewed recovery acceptance belong
  to the recovery boundary.
  """

  alias WotexHome.Profiles.{Archive, AuthoringObject}
  @tagged_maximum 4_194_304

  def max_bytes, do: Archive.max_bytes() + 4 + 2 + 128 * 4 + @tagged_maximum

  def encode(database, profiles, tagged) do
    with {:ok, legacy} <- Archive.encode(database, profiles),
         :ok <- validate_tagged(tagged) do
      frames =
        Enum.map(tagged, fn object ->
          <<byte_size(object["bytes"])::unsigned-big-32, object["bytes"]::binary>>
        end)

      {:ok,
       IO.iodata_to_binary([
         <<byte_size(legacy)::unsigned-big-32>>,
         legacy,
         <<length(tagged)::unsigned-big-16>>,
         frames
       ])}
    end
  end

  def decode(bytes) when is_binary(bytes) do
    if byte_size(bytes) <= max_bytes() do
      decode_bounded(bytes)
    else
      {:error, :invalid_authoring_archive}
    end
  end

  def decode(_), do: {:error, :invalid_authoring_archive}

  defp decode_bounded(<<length::unsigned-big-32, rest::binary>>) do
    if length <= Archive.max_bytes() and byte_size(rest) >= length + 2 do
      <<legacy::binary-size(^length), count::unsigned-big-16, frames::binary>> = rest

      with true <- count <= 128,
           {:ok, database, profiles} <- Archive.decode(legacy),
           {:ok, tagged} <- frames(frames, count, [], 0),
           :ok <- validate_tagged(tagged) do
        {:ok, database, profiles ++ Enum.map(tagged, &restored/1)}
      else
        _ -> {:error, :invalid_authoring_archive}
      end
    else
      {:error, :invalid_authoring_archive}
    end
  end

  defp decode_bounded(_), do: {:error, :invalid_authoring_archive}

  def validate_tagged(data) when is_list(data) and length(data) <= 128 do
    case Enum.reduce_while(data, {:ok, [], 0}, fn item, {:ok, ids, bytes} ->
           with true <- is_map(item) and not is_struct(item) and map_size(item) == 5,
                true <-
                  Enum.sort(Map.keys(item)) ==
                    ~w(bytes kind object_digest payload_bytes payload_sha256),
                {:ok, object} <- AuthoringObject.parse(item["bytes"]),
                {:ok, summary} <- AuthoringObject.summary(object),
                true <- Map.delete(item, "bytes") == summary,
                total = bytes + byte_size(object.bytes),
                true <- total <= @tagged_maximum do
             {:cont, {:ok, [object.digest | ids], total}}
           else
             _ -> {:halt, {:error, :invalid_authoring_archive}}
           end
         end) do
      {:ok, ids, _} ->
        if Enum.reverse(ids) == Enum.sort(Enum.uniq(ids)),
          do: :ok,
          else: {:error, :invalid_authoring_archive}

      error ->
        error
    end
  end

  def validate_tagged(_), do: {:error, :invalid_authoring_archive}

  def tagged?(item), do: is_map(item) and Map.has_key?(item, :authoring_summary)
  def summary(item), do: item.authoring_summary

  def restored(item),
    do: %{
      artifact_digest: item["object_digest"],
      bytes: item["bytes"],
      authoring_summary: Map.delete(item, "bytes")
    }

  defp frames("", 0, values, _), do: {:ok, Enum.reverse(values)}

  defp frames(<<length::unsigned-big-32, rest::binary>>, count, values, total)
       when count > 0 and length in 43..262_186 and byte_size(rest) >= length and
              total + length <= @tagged_maximum do
    <<bytes::binary-size(^length), tail::binary>> = rest

    with {:ok, object} <- AuthoringObject.parse(bytes),
         {:ok, summary} <- AuthoringObject.summary(object) do
      frames(tail, count - 1, [Map.put(summary, "bytes", bytes) | values], total + length)
    end
  end

  defp frames(_, _, _, _), do: {:error, :invalid_authoring_archive}
end
