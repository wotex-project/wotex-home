defmodule WotexHome.Profiles.Codec do
  @moduledoc """
  Closed, allocation-bounded parser for portable profile v1 data.

  Container depth and member counts are checked as the JSON decoder enters
  and fills each container. Numeric conversion, duplicate keys and oversized
  strings fail before a profile can be constructed. No author value becomes
  an atom, module, path, expression or executable dependency.
  """

  @max_bytes 32_768
  @max_depth 8
  @max_string 256
  @keys ~w(binding dependencies fingerprint format id provenance version)
  @fingerprint_keys ~w(firmware_versions manufacturer model transport)
  @provenance_keys ~w(license publisher source)

  def max_bytes, do: @max_bytes

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max_bytes do
    with true <- String.valid?(bytes),
         {data, {0, 0, nil}, ""} <- JSON.decode(bytes, {0, 0, nil}, decoders()),
         :ok <- shape(data) do
      {:ok, data}
    else
      _ -> {:error, :invalid_profile_data}
    end
  catch
    :throw, :invalid_profile_data -> {:error, :invalid_profile_data}
  end

  def decode(_), do: {:error, :invalid_profile_data}

  defp decoders do
    [
      object_start: &start_object/1,
      object_push: &push_object/3,
      object_finish: fn {_depth, _count, object}, parent -> {object, parent} end,
      array_start: &start_array/1,
      array_push: &push_array/2,
      array_finish: fn {_depth, _count, values}, parent -> {Enum.reverse(values), parent} end,
      string: &string/1,
      integer: fn _ -> invalid() end,
      float: fn _ -> invalid() end
    ]
  end

  defp start_object({depth, _, _}) when depth < @max_depth, do: {depth + 1, 0, %{}}
  defp start_object(_), do: invalid()
  defp start_array({depth, _, _}) when depth < @max_depth, do: {depth + 1, 0, []}
  defp start_array(_), do: invalid()

  defp push_object(key, value, {depth, count, object})
       when count < 8 and not is_map_key(object, key),
       do: {depth, count + 1, Map.put(object, key, value)}

  defp push_object(_, _, _), do: invalid()

  defp push_array(value, {depth, count, values}) when count < 32,
    do: {depth, count + 1, [value | values]}

  defp push_array(_, _), do: invalid()

  defp string(value) when byte_size(value) <= @max_string, do: value
  defp string(_), do: invalid()

  defp shape(data) when is_map(data) do
    with true <- Enum.sort(Map.keys(data)) == @keys,
         "wotex-home.portable-profile.v1" <- data["format"],
         true <- WotexHome.Id.valid?(data["id"]) and WotexHome.Id.valid?(data["version"]),
         "lifx-direct-power-v1" <- data["binding"],
         fingerprint when is_map(fingerprint) <- data["fingerprint"],
         true <- Enum.sort(Map.keys(fingerprint)) == @fingerprint_keys,
         [dependency] when is_map(dependency) <- data["dependencies"],
         true <- Enum.sort(Map.keys(dependency)) == ~w(kind sha256),
         "registry" <- dependency["kind"],
         true <- digest?(dependency["sha256"]),
         provenance when is_map(provenance) <- data["provenance"],
         true <- Enum.sort(Map.keys(provenance)) == @provenance_keys,
         true <- Enum.all?(Map.values(provenance), &provenance_text?/1) do
      :ok
    else
      _ -> {:error, :invalid_profile_data}
    end
  end

  defp shape(_), do: {:error, :invalid_profile_data}

  def digest?(value) when is_binary(value),
    do: byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  def digest?(_), do: false

  defp provenance_text?(value) when is_binary(value) and byte_size(value) in 1..@max_string,
    do: not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value)

  defp provenance_text?(_), do: false
  defp invalid, do: throw(:invalid_profile_data)
end
