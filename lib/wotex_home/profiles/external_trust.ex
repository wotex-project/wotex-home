defmodule WotexHome.Profiles.ExternalTrust do
  @moduledoc "Closed producer-independent local trust request/outcome/receipt encodings."
  alias WotexHome.{Id, Profiles.AuthoringWire, Profiles.EnvelopeCodec}
  alias WotexHome.Profiles.{ExternalArtifact, ExternalInspection}
  @maximum 9_223_372_036_854_775_807
  @format "wotex-home.external-trust.v1"
  @input ~w(authority_epoch operation_id expected_revision action artifact_digest expected_trust_revision expected_policy_generation inspection_ref acknowledgement)
  @receipt ~w(authority_epoch operation_id revision input_sha256 action artifact_digest previous_trust_revision trust_generation policy_generation artifact_first_approval_revision reader_basis_sha256 outcome_sha256)
  @ref ~w(authority_epoch operation_id revision input_sha256 result_sha256)
  @outcome "wotex-home.external-trust-result@1"

  def encode(input) do
    with true <- EnvelopeCodec.keys?(input, Enum.sort(@input)),
         true <-
           int?(input["authority_epoch"], 1) and Id.valid?(input["operation_id"]) and
             Enum.all?(
               ~w(expected_revision expected_trust_revision expected_policy_generation),
               &int?(input[&1], 0)
             ) and EnvelopeCodec.digest?(input["artifact_digest"]),
         true <-
           (input["action"] == "approve" and ref?(input["inspection_ref"]) and
              input["acknowledgement"] == "operator_digest_approval") or
             (input["action"] == "revoke" and input["inspection_ref"] == nil and
                input["acknowledgement"] == nil),
         values =
           Enum.map(@input, &input[&1]) |> List.replace_at(7, ref_values(input["inspection_ref"])),
         do: sized(JSON.encode!([@format, values]), 4096),
         else: (_ -> invalid())
  end

  def decode(bytes) do
    with {:ok, [@format, values]} <- wire(bytes, 4096),
         true <- match?([_, _, _, _, _, _, _, _, _], values),
         {:ok, ref} <- native_ref(Enum.at(values, 7)),
         input = Map.new(Enum.zip(@input, List.replace_at(values, 7, ref))),
         {:ok, ^bytes} <- encode(input),
         do: {:ok, input},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def encode_outcome(data) do
    with true <-
           EnvelopeCodec.keys?(
             data,
             ~w(action artifact_digest artifact_document format inspection_document inspection_ref)
           ),
         true <- data["format"] == @outcome and EnvelopeCodec.digest?(data["artifact_digest"]),
         {:ok, artifact, inspection} <- outcome_documents(data),
         do:
           sized(
             JSON.encode!([
               @outcome,
               data["action"],
               data["artifact_digest"],
               ref_values(data["inspection_ref"]),
               artifact,
               inspection
             ]),
             65536
           ),
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  def decode_outcome(bytes) do
    with {:ok, [@outcome, action, digest, ref, artifact, inspection]} <- wire(bytes, 65536),
         {:ok, ref} <- native_ref(ref),
         data = %{
           "format" => @outcome,
           "action" => action,
           "artifact_digest" => digest,
           "inspection_ref" => ref,
           "artifact_document" => if(artifact == nil, do: nil, else: JSON.encode!(artifact)),
           "inspection_document" => if(inspection == nil, do: nil, else: JSON.encode!(inspection))
         },
         {:ok, ^bytes} <- encode_outcome(data),
         do: {:ok, data},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  defp outcome_documents(%{
         "action" => "revoke",
         "inspection_ref" => nil,
         "artifact_document" => nil,
         "inspection_document" => nil
       }),
       do: {:ok, nil, nil}

  defp outcome_documents(%{"action" => "approve"} = data) do
    with true <- ref?(data["inspection_ref"]),
         {:ok, artifact} <- ExternalArtifact.decode(data["artifact_document"]),
         {:ok, digest} <- ExternalArtifact.identity(artifact),
         true <- digest == data["artifact_digest"],
         {:ok, inspection} <- ExternalInspection.decode_result(data["inspection_document"]),
         true <- sha(data["inspection_document"]) == data["inspection_ref"]["result_sha256"],
         [envelope | documents] = artifact["objects"],
         true <- inspection["envelope"]["envelope_sha256"] == envelope["payload_sha256"],
         true <-
           inspection["envelope"]["document_identities"] ==
             Enum.map(
               documents,
               &(Map.take(&1, ~w(reference payload_sha256))
                 |> Map.put("raw_sha256", &1["payload_sha256"])
                 |> Map.delete("payload_sha256"))
             ),
         do:
           {:ok, JSON.decode!(data["artifact_document"]),
            JSON.decode!(data["inspection_document"])},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  defp outcome_documents(_), do: invalid()

  def encode_receipt(data) do
    valid =
      EnvelopeCodec.keys?(data, Enum.sort(@receipt)) and Id.valid?(data["operation_id"]) and
        Enum.all?(
          ~w(authority_epoch revision trust_generation policy_generation artifact_first_approval_revision),
          &int?(data[&1], 1)
        ) and
        int?(data["previous_trust_revision"], 0) and
        data["previous_trust_revision"] < data["revision"] and
        data["artifact_first_approval_revision"] <= data["revision"] and
        data["trust_generation"] <= data["policy_generation"] and
        Enum.all?(
          ~w(input_sha256 artifact_digest outcome_sha256),
          &EnvelopeCodec.digest?(data[&1])
        ) and
        ((data["action"] == "approve" and EnvelopeCodec.digest?(data["reader_basis_sha256"])) or
           (data["action"] == "revoke" and data["reader_basis_sha256"] == nil)) and
        ((data["trust_generation"] == 1 and data["action"] == "approve" and
            data["previous_trust_revision"] == 0 and
            data["artifact_first_approval_revision"] == data["revision"]) or
           (data["trust_generation"] > 1 and data["previous_trust_revision"] > 0 and
              data["artifact_first_approval_revision"] < data["revision"]))

    if valid, do: {:ok, JSON.encode!(Enum.map(@receipt, &data[&1]))}, else: invalid()
  end

  def decode_receipt(bytes) do
    with {:ok, values} <- wire(bytes, 4096),
         true <- match?([_, _, _, _, _, _, _, _, _, _, _, _], values),
         data = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(data),
         do: {:ok, data},
         else: (
           {:error, :external_profile_limit} = error -> error
           _ -> invalid()
         )
  end

  defp ref?(ref),
    do:
      EnvelopeCodec.keys?(ref, Enum.sort(@ref)) and int?(ref["authority_epoch"], 1) and
        int?(ref["revision"], 1) and Id.valid?(ref["operation_id"]) and
        Enum.all?(~w(input_sha256 result_sha256), &EnvelopeCodec.digest?(ref[&1]))

  defp ref_values(nil), do: nil
  defp ref_values(ref), do: Enum.map(@ref, &ref[&1])
  defp native_ref(nil), do: {:ok, nil}

  defp native_ref([epoch, op, revision, input, result]),
    do: {:ok, Map.new(Enum.zip(@ref, [epoch, op, revision, input, result]))}

  defp native_ref(_), do: invalid()
  defp int?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp wire(bytes, maximum) do
    case AuthoringWire.decode(bytes, maximum) do
      {:ok, _} = result -> result
      {:error, :authoring_limit} -> {:error, :external_profile_limit}
      _ -> invalid()
    end
  end

  defp sized(bytes, maximum),
    do: if(byte_size(bytes) <= maximum, do: {:ok, bytes}, else: {:error, :external_profile_limit})

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_external_trust}
end
