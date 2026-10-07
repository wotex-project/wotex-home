defmodule WotexHome.Profiles.Archive do
  @moduledoc "Bounded historical byte correspondence and binary archive framing; no admission."
  alias WotexHome.Profiles.{Artifact, Bindings, Codec}
  @max_database 33_554_432
  @max_objects 64
  @record_overhead 196
  @max_bytes 4 + @max_database + 2 + @max_objects * (@record_overhead + 32_768)

  def max_bytes, do: @max_bytes

  def encode(database, objects)
      when is_binary(database) and byte_size(database) in 1..@max_database do
    with :ok <- validate(commitments(objects), objects) do
      records =
        Enum.map(objects, fn object ->
          <<object.artifact_digest::binary-size(64), object.projection_digest::binary-size(64),
            object.registry_digest::binary-size(64), byte_size(object.bytes)::unsigned-big-32,
            object.bytes::binary>>
        end)

      {:ok,
       IO.iodata_to_binary([
         <<byte_size(database)::unsigned-big-32>>,
         database,
         <<length(objects)::unsigned-big-16>>,
         records
       ])}
    end
  end

  def encode(_, _), do: {:error, :invalid_profile_archive}

  def decode(<<size::unsigned-big-32, rest::binary>> = plain)
      when size in 1..@max_database and byte_size(plain) <= @max_bytes and
             byte_size(rest) >= size + 2 do
    <<database::binary-size(^size), count::unsigned-big-16, records::binary>> = rest

    with true <- count <= @max_objects,
         {:ok, objects} <- records(records, count, []),
         :ok <- validate(commitments(objects), objects) do
      {:ok, database, objects}
    else
      _ -> {:error, :invalid_profile_archive}
    end
  end

  def decode(_), do: {:error, :invalid_profile_archive}

  def validate(expected, objects) when is_list(expected) and is_list(objects) do
    with :ok <- validate_commitments(expected),
         true <- length(objects) == length(expected),
         true <- Enum.all?(objects, &object?/1),
         true <- commitments(objects) == expected,
         true <- Enum.all?(objects, &corresponds?/1) do
      :ok
    else
      _ -> {:error, :invalid_profile_archive}
    end
  end

  def validate(_, _), do: {:error, :invalid_profile_archive}

  def validate_commitments(expected) when is_list(expected) do
    if length(expected) <= @max_objects and Enum.all?(expected, &commitment?/1) and
         expected == Enum.sort_by(expected, & &1.artifact_digest) and
         Enum.uniq_by(expected, & &1.artifact_digest) == expected,
       do: :ok,
       else: {:error, :invalid_profile_archive}
  end

  def validate_commitments(_), do: {:error, :invalid_profile_archive}

  defp records(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp records(
         <<raw::binary-size(64), projection::binary-size(64), registry::binary-size(64),
           size::unsigned-big-32, rest::binary>>,
         count,
         acc
       )
       when count > 0 and size in 1..32_768 and byte_size(rest) >= size do
    <<bytes::binary-size(^size), tail::binary>> = rest

    records(tail, count - 1, [
      %{
        artifact_digest: raw,
        projection_digest: projection,
        registry_digest: registry,
        bytes: bytes
      }
      | acc
    ])
  end

  defp records(_, _, _), do: {:error, :invalid_profile_archive}

  defp commitments(objects) when is_list(objects),
    do:
      Enum.map(objects, fn object ->
        if is_map(object),
          do:
            Map.take(
              object,
              [:artifact_digest, :projection_digest, :registry_digest]
            ),
          else: nil
      end)

  defp commitments(_), do: nil

  defp commitment?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.sort(Map.keys(value)) == [:artifact_digest, :projection_digest, :registry_digest] and
        Enum.all?(Map.values(value), &Codec.digest?/1)

  defp commitment?(_), do: false

  defp object?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.sort(Map.keys(value)) == [
        :artifact_digest,
        :bytes,
        :projection_digest,
        :registry_digest
      ] and
        is_binary(value.bytes) and byte_size(value.bytes) in 1..32_768

  defp object?(_), do: false

  defp corresponds?(object) do
    with true <- Artifact.digest(object.bytes) == object.artifact_digest,
         {:ok, data} <- Codec.decode(object.bytes),
         {:ok, projection} <- Bindings.historical_projection(data),
         true <- Artifact.digest(projection) == object.projection_digest,
         true <- hd(data["dependencies"])["sha256"] == object.registry_digest do
      true
    else
      _ -> false
    end
  end
end
