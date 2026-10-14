defmodule WotexHome.Profiles.EnvelopeCodec do
  @moduledoc """
  Decodes Home's bounded inert profile reference and attribution envelope.

  `decode/1` checks a closed JSON shape before any external producer is invoked.
  The envelope has a 65,536-byte ceiling and bounded nodes, text and collections;
  its references name exact IDs, versions and lowercase SHA-256 digests. Shared
  predicates check the same closed representations used by profile codecs.

  A syntactically valid reference causes no network fetch or executable loading.
  The caller must separately establish exact document bytes, installed bindings,
  consumer policy and actor ownership.
  """

  @maximum_bytes 65_536
  @maximum_nodes 4096
  @fields ~w(definitions format home_contracts id profile provenance version)

  @doc "Decodes the closed reference envelope before an external profile reader is invoked."
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum_bytes do
    with true <- String.valid?(bytes),
         {data, {0, nodes, nil}, ""} when nodes <= @maximum_nodes <-
           JSON.decode(bytes, {0, 0, nil}, decoders()),
         :ok <- shape(data) do
      {:ok, data}
    else
      _ -> {:error, :invalid_external_envelope}
    end
  catch
    :throw, code when code in [:invalid_external_envelope, :external_profile_limit] ->
      {:error, code}
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > @maximum_bytes,
    do: {:error, :external_profile_limit}

  def decode(_), do: {:error, :invalid_external_envelope}

  @doc "Checks one exact external reference without fetching it."
  def reference?(data) do
    keys?(data, ~w(id sha256 version)) and uri?(data["id"]) and version?(data["version"]) and
      digest?(data["sha256"])
  end

  @doc "Checks sorted unique references by ID/version, rejecting aliases of one ID."
  def references?(data) when is_list(data) and length(data) <= 32 do
    ids = Enum.map(data, fn value -> if is_map(value), do: value["id"], else: nil end)

    Enum.all?(data, &reference?/1) and length(Enum.uniq(ids)) == length(ids) and
      data == Enum.sort_by(data, &{&1["id"], &1["version"]})
  end

  def references?(_), do: false

  @doc "Checks a complete field set, without accepting structs or unknown members."
  def keys?(data, fields),
    do:
      is_map(data) and not is_struct(data) and map_size(data) == length(fields) and
        Enum.sort(Map.keys(data)) == fields

  @doc "Checks a proper selected collection before traversal."
  def bounded_list?(data) when is_list(data) and length(data) <= 32, do: true
  def bounded_list?(_), do: false

  @doc "Checks lower-hex SHA-256 syntax."
  def digest?(data),
    do: is_binary(data) and byte_size(data) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, data)

  @doc "Checks a nonempty bounded string without control characters."
  def text?(data, maximum) do
    is_binary(data) and byte_size(data) in 1..maximum and String.valid?(data) and
      not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, data)
  end

  @doc "Checks the external local-key grammar."
  def key?(data), do: text?(data, 128) and Regex.match?(~r/\A[a-zA-Z0-9._-]+\z/, data)

  @doc "Checks the bounded canonical external x.y.z version grammar."
  def version?(data) do
    is_binary(data) and byte_size(data) <= 17 and
      Regex.match?(~r/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/, data) and
      Enum.all?(String.split(data, "."), &(String.to_integer(&1) <= 65_535))
  end

  defp uri?(data) do
    if text?(data, 256) do
      case URI.new(data) do
        {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> true
        _ -> false
      end
    else
      false
    end
  end

  defp shape(data) do
    if keys?(data, @fields) and data["format"] == "wotex-home.portable-profile.v2" and
         WotexHome.Id.valid?(data["id"]) and version?(data["version"]) and
         reference?(data["profile"]) and references?(data["definitions"]) and
         channel_contracts?(data["home_contracts"]) and provenance?(data["provenance"]),
       do: :ok,
       else: {:error, :invalid_external_envelope}
  end

  defp channel_contracts?(data) when is_list(data) and length(data) <= 32 do
    valid =
      Enum.all?(data, fn entry ->
        keys?(entry, ~w(channel_id contract_ref)) and key?(entry["channel_id"]) and
          reference?(entry["contract_ref"])
      end)

    if valid do
      ids = Enum.map(data, & &1["channel_id"])
      ids == Enum.sort(Enum.uniq(ids))
    else
      false
    end
  end

  defp channel_contracts?(_), do: false

  defp provenance?(data) do
    keys?(data, ~w(license publisher source)) and Enum.all?(Map.values(data), &text?(&1, 256))
  end

  defp decoders do
    [
      object_start: &start_object/1,
      object_push: &push_object/3,
      object_finish: &finish/2,
      array_start: &start_array/1,
      array_push: &push_array/2,
      array_finish: &finish_array/2,
      string: &string/1,
      integer: fn _ -> invalid() end,
      float: fn _ -> invalid() end
    ]
  end

  defp start_object({depth, nodes, _}) when depth < 8 and nodes < @maximum_nodes,
    do: {depth + 1, nodes + 1, %{}}

  defp start_object(_), do: limit()

  defp start_array({depth, nodes, _}) when depth < 8 and nodes < @maximum_nodes,
    do: {depth + 1, nodes + 1, []}

  defp start_array(_), do: limit()
  defp finish({_, nodes, data}, {depth, _, parent}), do: {data, {depth, nodes, parent}}
  defp finish_array({_, nodes, data}, parent), do: finish({0, nodes, Enum.reverse(data)}, parent)

  defp push_object(key, value, {depth, nodes, data})
       when map_size(data) < 32 and not is_map_key(data, key) do
    nodes = nodes + 1 + leaf(value)
    if nodes <= @maximum_nodes, do: {depth, nodes, Map.put(data, key, value)}, else: limit()
  end

  defp push_object(key, _, {_, _, data}) when is_map_key(data, key), do: invalid()
  defp push_object(_, _, _), do: limit()

  defp push_array(value, {depth, nodes, data}) when length(data) < 32 do
    nodes = nodes + leaf(value)
    if nodes <= @maximum_nodes, do: {depth, nodes, [value | data]}, else: limit()
  end

  defp push_array(_, _), do: limit()
  defp leaf(value) when is_map(value) or is_list(value), do: 0
  defp leaf(_), do: 1
  defp string(value) when byte_size(value) <= 256, do: value
  defp string(_), do: limit()
  defp invalid, do: throw(:invalid_external_envelope)
  defp limit, do: throw(:external_profile_limit)
end
