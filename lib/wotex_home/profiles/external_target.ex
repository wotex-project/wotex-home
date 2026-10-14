defmodule WotexHome.Profiles.ExternalTarget do
  @moduledoc "Closed durable target originals, private outcomes and public receipts."
  alias WotexHome.{Id, Profiles.EnvelopeCodec}
  alias WotexHome.Durable.Registry

  alias WotexHome.Profiles.{
    AuthoringWire,
    DocumentChunks,
    ExternalArtifact,
    ExternalInspection,
    ReadDeclarationCodec,
    RetainedSource
  }

  @maximum 9_223_372_036_854_775_807
  @format "wotex-home.external-target.v1"
  @outcome "wotex-home.external-target-result@1"
  @input ~w(authority_epoch operation_id expected_revision action target_id artifact_digest expected_trust_revision expected_policy_generation expected_selection_revision expected_resource_revision source_ref source_owner_epoch source_selection_sha256 objects acknowledgement)
  @receipt ~w(authority_epoch operation_id revision input_sha256 action target_id artifact_digest previous_selection_revision selection_generation resource_revision binding_revision trust_revision policy_generation source_selection_sha256 outcome_sha256 withdrawn_grants)
  @documents [
    {"artifact_document", 32768},
    {"inspection_document", 32768},
    {"thing_document", 65536},
    {"source_document", 600_000}
  ]
  @outcome_keys ~w(action artifact_document format inspection_document source_document target_id thing_document)

  def encode(input) do
    with true <- EnvelopeCodec.keys?(input, Enum.sort(@input)),
         true <-
           int?(input["authority_epoch"], 1) and Id.valid?(input["operation_id"]) and
             Id.valid?(input["target_id"]),
         true <-
           Enum.all?(
             ~w(expected_revision expected_trust_revision expected_policy_generation expected_selection_revision expected_resource_revision),
             &int?(input[&1], 0)
           ),
         true <- EnvelopeCodec.digest?(input["artifact_digest"]),
         {:ok, objects} <- objects(input),
         values = Enum.map(@input, &input[&1]) |> List.replace_at(13, objects),
         do: sized(JSON.encode!([@format, values]), 32768),
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def decode(bytes) do
    with {:ok, [@format, values]} <- wire(bytes, 32768),
         true <- is_list(values) and length(values) == 15,
         {:ok, objects} <- native_objects(Enum.at(values, 13)),
         input = Map.new(Enum.zip(@input, List.replace_at(values, 13, objects))),
         {:ok, ^bytes} <- encode(input),
         do: {:ok, input},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def encode_outcome(data) do
    with true <- EnvelopeCodec.keys?(data, @outcome_keys),
         true <-
           data["format"] == @outcome and data["action"] in ~w(select revoke) and
             Id.valid?(data["target_id"]),
         {:ok, chunks} <- document_chunks(data),
         :ok <- correspondence(data),
         do:
           sized(JSON.encode!([@outcome, data["action"], data["target_id"] | chunks]), 1_048_576),
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def decode_outcome(bytes) do
    with {:ok, [@outcome, action, target, a, i, t, s]} <- wire(bytes, 1_048_576),
         {:ok, documents} <- native_documents([a, i, t, s]),
         data =
           Map.merge(documents, %{"format" => @outcome, "action" => action, "target_id" => target}),
         {:ok, ^bytes} <- encode_outcome(data),
         do: {:ok, data},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def encode_receipt(r) do
    valid =
      EnvelopeCodec.keys?(r, Enum.sort(@receipt)) and
        Id.valid?(r["operation_id"]) and Id.valid?(r["target_id"]) and
        r["action"] in ~w(select revoke) and
        Enum.all?(
          ~w(authority_epoch revision selection_generation binding_revision trust_revision policy_generation),
          &int?(r[&1], 1)
        ) and
        Enum.all?(
          ~w(previous_selection_revision resource_revision withdrawn_grants),
          &int?(r[&1], 0)
        ) and
        r["withdrawn_grants"] <= 4096 and r["previous_selection_revision"] < r["revision"] and
        r["binding_revision"] <= r["revision"] and r["trust_revision"] < r["revision"] and
        Enum.all?(
          ~w(input_sha256 artifact_digest source_selection_sha256 outcome_sha256),
          &EnvelopeCodec.digest?(r[&1])
        ) and
        ((r["selection_generation"] == 1 and r["action"] == "select" and
            r["previous_selection_revision"] == 0 and r["resource_revision"] == 0 and
            r["binding_revision"] == r["revision"] and r["withdrawn_grants"] == 0) or
           (r["selection_generation"] > 1 and r["previous_selection_revision"] > 0 and
              r["resource_revision"] == r["selection_generation"] - 1 and
              ((r["action"] == "select" and r["binding_revision"] == r["revision"]) or
                 (r["action"] == "revoke" and
                    r["binding_revision"] <= r["previous_selection_revision"]))))

    if valid, do: sized(JSON.encode!(Enum.map(@receipt, &r[&1])), 4096), else: invalid()
  end

  def decode_receipt(bytes) do
    with {:ok, values} <- wire(bytes, 4096),
         true <- is_list(values) and length(values) == 16,
         r = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(r),
         do: {:ok, r},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  defp objects(%{"action" => "select"} = i) do
    with true <-
           Id.valid?(i["source_ref"]) and epoch?(i["source_owner_epoch"]) and
             EnvelopeCodec.digest?(i["source_selection_sha256"]) and
             i["acknowledgement"] == "operator_external_selection",
         do: ExternalInspection.encode_objects(i["objects"]),
         else: (_ -> invalid())
  end

  defp objects(%{"action" => "revoke"} = i) do
    if Enum.all?(
         ~w(source_ref source_owner_epoch source_selection_sha256 objects acknowledgement),
         &is_nil(i[&1])
       ), do: {:ok, nil}, else: invalid()
  end

  defp objects(_), do: invalid()
  defp native_objects(nil), do: {:ok, nil}
  defp native_objects(value), do: ExternalInspection.decode_objects(value)

  defp document_chunks(data) do
    Enum.reduce_while(@documents, {:ok, []}, fn {key, maximum}, {:ok, acc} ->
      case DocumentChunks.encode(data[key], maximum) do
        {:ok, chunks} -> {:cont, {:ok, acc ++ [chunks]}}
        error -> {:halt, error}
      end
    end)
  end

  defp native_documents(values) do
    Enum.zip(@documents, values)
    |> Enum.reduce_while({:ok, %{}}, fn {{key, maximum}, chunks}, {:ok, acc} ->
      case DocumentChunks.decode(chunks, maximum) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, key, bytes)}}
        error -> {:halt, error}
      end
    end)
  end

  defp correspondence(d) do
    with {:ok, artifact} <- ExternalArtifact.decode(d["artifact_document"]),
         {:ok, digest} <- ExternalArtifact.identity(artifact),
         {:ok, inspection} <- ExternalInspection.decode_result(d["inspection_document"]),
         {:ok, thing} <- Registry.decode_thing(d["thing_document"]),
         {:ok, source} <- RetainedSource.decode(d["source_document"]),
         true <-
           thing.id == d["target_id"] and thing.role == "EnvironmentalSensor" and
             thing.profile_ref == "external:" <> digest,
         true <-
           inspection["reader_basis_sha256"] == source.reader_basis_sha256 and
             inspection["capture_digest"] == source.inputs["reader"]["capture"]["digest"],
         [envelope | documents] = artifact["objects"],
         summary = inspection["envelope"],
         true <-
           summary["envelope_sha256"] == envelope["payload_sha256"] and
             summary["producer"] == source.inputs["reader"]["installed"]["producer"],
         true <-
           summary["document_identities"] ==
             Enum.map(
               documents,
               &%{"reference" => &1["reference"], "raw_sha256" => &1["payload_sha256"]}
             ),
         channels = source.inputs["channels"],
         true <-
           Enum.map(channels, & &1["channel_id"]) ==
             Enum.map(summary["home_contracts"], & &1["channel_id"]),
         true <- map_size(thing.capabilities) == length(channels),
         true <- Enum.all?(channels, &channel?(&1, thing, summary, digest)),
         do: :ok,
         else: (_ -> invalid())
  end

  defp channel?(channel, thing, summary, digest) do
    c = channel["consumer"]
    p = channel["policy"]
    capability = thing.capabilities[p["capability_key"]]

    with %{record: record} <- capability,
         {:ok, %{"data" => data}} <- ReadDeclarationCodec.decode(record),
         true <-
           record["artifact_digest"] == digest and data["channel_id"] == channel["channel_id"] and
             data["thing_id"] == thing.id,
         true <- Enum.all?(p, fn {key, value} -> data[key] == value end),
         true <-
           Enum.all?(~w(contract_ref semantic_ref value_kind constraints), fn key ->
             data[key] == c[if(key == "contract_ref", do: "reference", else: key)]
           end),
         true <- c["value_kind"] == "external" or data["unit"] == c["unit"],
         true <-
           Enum.all?(
             ~w(envelope_sha256 projection_sha256 consumption_sha256 producer),
             &(data[&1] == summary[&1])
           ),
         true <-
           Enum.any?(
             summary["home_contracts"],
             &(&1["channel_id"] == channel["channel_id"] and &1["contract_ref"] == c["reference"])
           ),
         do: true,
         else: (_ -> false)
  end

  defp wire(bytes, max) do
    case AuthoringWire.decode(bytes, max) do
      {:ok, _} = result -> result
      {:error, :authoring_limit} -> {:error, :external_profile_limit}
      _ -> invalid()
    end
  end

  defp sized(bytes, max),
    do: if(byte_size(bytes) <= max, do: {:ok, bytes}, else: {:error, :external_profile_limit})

  defp int?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp epoch?(value),
    do: is_binary(value) and byte_size(value) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp invalid, do: {:error, :invalid_external_target}
end
