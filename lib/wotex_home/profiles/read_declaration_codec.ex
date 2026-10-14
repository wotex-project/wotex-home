defmodule WotexHome.Profiles.ReadDeclarationCodec do
  @moduledoc """
  Retained generic read metadata, independent of installed producer availability.

  Decoding preserves exact bytes and checks their closed Home representation.
  It does not revalidate opaque producer units/schemas or grant current authority.
  """
  alias WotexHome.Id
  alias WotexHome.LocalAPI.Frame

  alias WotexHome.Profiles.{
    AuthoringObject,
    EnvelopeCodec,
    ExternalArtifact,
    ExternalReadDeclaration
  }

  @record ~w(artifact_digest declaration_document declaration_sha256 format)
  @data ~w(capability_key channel_id constraints consumption_sha256 contract_ref contract_sha256 envelope_sha256 evidence_ref format freshness_ms operations producer projection_sha256 risk_class semantic_ref thing_id unit value_kind value_schema)
  @minimum -9_223_372_036_854_775_808
  @maximum 9_223_372_036_854_775_807

  @doc "Rebuilds a live original and retains its exact canonical output document."
  @spec encode(term(), term()) :: {:ok, map()} | {:error, atom()}
  def encode(%ExternalReadDeclaration{inputs: i} = value, artifact) when is_map(i) do
    with true <- EnvelopeCodec.digest?(artifact),
         {:ok, exported} <-
           ExternalReadDeclaration.to_map(
             value,
             i["envelope"],
             i["contract"],
             i["policy"],
             i["reader_limits"]
           ),
         :ok <- artifact_identity(i["envelope"], artifact),
         {:ok, document} <- producer_document(exported["data"]),
         record = %{
           "format" => "wotex-home.retained-read-declaration@1",
           "artifact_digest" => artifact,
           "declaration_document" => document,
           "declaration_sha256" => exported["sha256"]
         },
         {:ok, _} <- decode(record),
         do: {:ok, record},
         else: (
           false -> invalid()
           error -> error
         )
  end

  def encode(_, _), do: invalid()

  defp artifact_identity(envelope, expected) do
    documents =
      [
        {"envelope", envelope.bytes, nil},
        {"profile", envelope.documents["profile"]["bytes"],
         envelope.documents["profile"]["reference"]}
      ] ++
        Enum.map(envelope.documents["definitions"], &{"definition", &1["bytes"], &1["reference"]})

    with {:ok, objects} <-
           Enum.reduce_while(documents, {:ok, []}, fn {kind, bytes, ref}, {:ok, records} ->
             with {:ok, object} <- AuthoringObject.new(kind, bytes),
                  {:ok, summary} <- AuthoringObject.summary(object),
                  do: {:cont, {:ok, [Map.put(summary, "reference", ref) | records]}},
                  else: (error -> {:halt, error})
           end),
         {:ok, actual} <-
           ExternalArtifact.identity(%{
             "format" => "wotex-home.external-artifact@1",
             "id" => envelope.data["id"],
             "version" => envelope.data["version"],
             "objects" => Enum.reverse(objects)
           }) do
      if actual == expected, do: :ok, else: {:error, :external_artifact_mismatch}
    end
  end

  @doc "Decodes bounded exact historical bytes without consulting a producer or filesystem."
  @spec decode(term()) :: {:ok, map()} | {:error, atom()}
  def decode(record) do
    with true <- EnvelopeCodec.keys?(record, @record),
         true <- record["format"] == "wotex-home.retained-read-declaration@1",
         true <-
           EnvelopeCodec.digest?(record["artifact_digest"]) and
             EnvelopeCodec.digest?(record["declaration_sha256"]),
         :ok <- document_size(record["declaration_document"]),
         {:ok, data} <- Frame.decode_request(record["declaration_document"]),
         {:ok, _} <- bounded(data, 1, 0),
         true <- shape?(data),
         true <- identity(record["declaration_document"]) == record["declaration_sha256"] do
      {:ok, %{"data" => data, "record" => record}}
    else
      {:error, code} when code in [:request_too_large, :too_deep, :external_profile_limit] ->
        {:error, :external_profile_limit}

      _ ->
        invalid()
    end
  end

  defp shape?(d) do
    EnvelopeCodec.keys?(d, @data) and d["format"] == "wotex-home.external-read-declaration@1" and
      Enum.all?(~w(thing_id capability_key channel_id evidence_ref), &Id.valid?(d[&1])) and
      d["operations"] == ["read"] and d["risk_class"] in ~w(ordinary sensitive) and
      is_integer(d["freshness_ms"]) and d["freshness_ms"] in 1..86_400_000 and
      EnvelopeCodec.reference?(d["semantic_ref"]) and EnvelopeCodec.reference?(d["contract_ref"]) and
      Enum.all?(
        ~w(contract_sha256 envelope_sha256 projection_sha256 consumption_sha256),
        &EnvelopeCodec.digest?(d[&1])
      ) and
      WotexHome.Profiles.ProducerIdentity.valid?(d["producer"]) and
      is_map(d["value_schema"]) and not is_struct(d["value_schema"]) and consumer_shape?(d)
  end

  defp consumer_shape?(%{"value_kind" => "integer", "unit" => unit, "constraints" => c}) do
    is_map(unit) and not is_struct(unit) and EnvelopeCodec.keys?(c, ~w(max min)) and
      is_integer(c["min"]) and is_integer(c["max"]) and c["min"] in @minimum..@maximum and
      c["max"] in @minimum..@maximum and c["min"] <= c["max"]
  end

  defp consumer_shape?(%{
         "value_kind" => "boolean",
         "unit" => nil,
         "constraints" => nil,
         "value_schema" => schema
       }),
       do: schema["type"] == "boolean"

  defp consumer_shape?(%{"value_kind" => "external", "constraints" => nil, "unit" => unit}),
    do: is_nil(unit) or (is_map(unit) and not is_struct(unit))

  defp consumer_shape?(_), do: false

  defp document_size(bytes) when is_binary(bytes) and byte_size(bytes) in 1..65536, do: :ok

  defp document_size(bytes) when is_binary(bytes) and byte_size(bytes) > 65536,
    do: {:error, :external_profile_limit}

  defp document_size(_), do: invalid()

  defp bounded(_, depth, count) when depth > 8 or count >= 4096,
    do: {:error, :external_profile_limit}

  defp bounded(data, depth, count) when is_map(data) and not is_struct(data) do
    if map_size(data) <= 256 and
         Enum.all?(Map.keys(data), &(is_binary(&1) and byte_size(&1) <= 4096)),
       do: children(Map.values(data), depth, count + 1),
       else: {:error, :external_profile_limit}
  end

  defp bounded(data, depth, count) when is_list(data) do
    if length(data) <= 256,
      do: children(data, depth, count + 1),
      else: {:error, :external_profile_limit}
  end

  defp bounded(data, _, count) when is_binary(data) do
    if byte_size(data) <= 4096, do: {:ok, count + 1}, else: {:error, :external_profile_limit}
  end

  defp bounded(_, _, count), do: {:ok, count + 1}

  defp children(data, depth, count) do
    Enum.reduce_while(data, {:ok, count}, fn value, {:ok, n} ->
      case bounded(value, depth + 1, n) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp producer_document(data) do
    case apply(Wotex.JSON, :encode, [
           data,
           [
             max_bytes: 65536,
             max_depth: 8,
             max_nodes: 4096,
             max_collection_size: 256,
             max_string_bytes: 4096
           ]
         ]) do
      {:ok, _} = result -> result
      _ -> {:error, :external_profile_limit}
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == Wotex.JSON and error.function == :encode and error.arity == 2,
        do: {:error, :profiles_producer_unavailable},
        else: invalid()
  end

  defp identity(bytes),
    do:
      Base.encode16(:crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> bytes),
        case: :lower
      )

  defp invalid, do: {:error, :invalid_read_declaration_record}
end
