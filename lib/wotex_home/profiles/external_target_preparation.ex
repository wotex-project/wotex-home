defmodule WotexHome.Profiles.ExternalTargetPreparation do
  @moduledoc "Pure preparation of exact host-held read targets; Store owns selection authority."
  alias WotexHome.Durable.Registry
  alias WotexHome.Semantics.Thing

  alias WotexHome.Profiles.{
    ExternalApprovalPreparation,
    ExternalArtifact,
    ExternalEnvelope,
    ExternalInspection,
    ExternalReadDeclaration,
    ExternalSourceSelection,
    ExternalTarget,
    ReadDeclarationCodec,
    ReaderSelection,
    RetainedSource
  }

  @doc "Rebuilds the source, exact raw approval and actual target projection and read declarations."
  def build(input, records, source, approved_document) do
    with {:ok, _} <- ExternalTarget.encode(input),
         true <- input["action"] == "select",
         {:ok, _} <- ExternalSourceSelection.to_map(source),
         true <-
           input["source_ref"] == source.inputs["source"]["source_ref"] and
             input["source_selection_sha256"] == source.sha256,
         reader = source.inputs["reader"],
         {:ok, inspected_input} <- inspection_input(input, reader),
         {:ok, approval} <- ExternalApprovalPreparation.build(inspected_input, records, reader),
         {:ok, artifact_document} <- ExternalArtifact.encode(approval["artifact"]),
         true <-
           approval["artifact_digest"] == input["artifact_digest"] and
             artifact_document == approved_document,
         {:ok, inspection_document} <- ExternalInspection.encode_result(approval["inspection"]),
         {:ok, envelope} <- envelope(input["objects"], records, reader),
         channels = source.inputs["channels"],
         true <-
           Enum.map(channels, & &1["channel_id"]) ==
             Enum.map(approval["inspection"]["envelope"]["home_contracts"], & &1["channel_id"]),
         {:ok, capabilities} <- declarations(channels, envelope, input, reader),
         {:ok, thing} <-
           Thing.new(%{
             "id" => input["target_id"],
             "role" => "EnvironmentalSensor",
             "profile_ref" => "external:" <> input["artifact_digest"],
             "capabilities" => capabilities
           }),
         {:ok, thing_document} <- Registry.encode_thing(thing),
         {:ok, source_document} <- RetainedSource.encode(source, input["source_owner_epoch"]),
         outcome = %{
           "format" => "wotex-home.external-target-result@1",
           "action" => "select",
           "target_id" => input["target_id"],
           "artifact_document" => artifact_document,
           "inspection_document" => inspection_document,
           "thing_document" => thing_document,
           "source_document" => source_document
         },
         {:ok, _} <- ExternalTarget.encode_outcome(outcome),
         do: {:ok, outcome},
         else: (
           false -> {:error, :external_artifact_mismatch}
           error -> error
         )
  end

  @doc "Builds the existing inspection owner's input from the actual checked source reader."
  def inspection_input(input, reader) do
    with {:ok, data} <- ReaderSelection.to_map(reader) do
      {:ok,
       %{
         "authority_epoch" => input["authority_epoch"],
         "operation_id" => input["operation_id"],
         "expected_revision" => input["expected_revision"],
         "inspection" => Map.put(input["objects"], "reader_basis_sha256", data["basis_sha256"])
       }}
    end
  end

  defp envelope(objects, records, reader) do
    indexed = Map.new(records, &{&1["object"]["object_digest"], &1})

    document = fn d ->
      r = indexed[d["object_ref"]["object_digest"]]

      %{
        "reference" => d["reference"],
        "raw_sha256" => r["object"]["payload_sha256"],
        "bytes" => r["payload"]
      }
    end

    ExternalEnvelope.compile(
      indexed[objects["envelope_ref"]["object_digest"]]["payload"],
      %{
        "profile" => document.(objects["profile"]),
        "definitions" => Enum.map(objects["definitions"], document)
      },
      reader.inputs["installed"],
      reader.inputs["capture"],
      reader.inputs["reader_limits"]
    )
  end

  defp declarations(channels, envelope, input, reader) do
    Enum.reduce_while(channels, {:ok, []}, fn c, {:ok, records} ->
      with {:ok, declaration} <-
             ExternalReadDeclaration.new(
               envelope,
               c["consumer"],
               Map.put(c["policy"], "thing_id", input["target_id"]),
               c["channel_id"],
               reader.inputs["reader_limits"]
             ),
           {:ok, record} <- ReadDeclarationCodec.encode(declaration, input["artifact_digest"]),
           do: {:cont, {:ok, [record | records]}},
           else: (error -> {:halt, error})
    end)
    |> case do
      {:ok, records} ->
        {:ok,
         Enum.sort_by(records, fn r ->
           {:ok, d} = ReadDeclarationCodec.decode(r)
           d["data"]["capability_key"]
         end)}

      error ->
        error
    end
  end
end
