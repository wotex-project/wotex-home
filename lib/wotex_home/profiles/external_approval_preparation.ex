defmodule WotexHome.Profiles.ExternalApprovalPreparation do
  @moduledoc """
  Builds an inspection and exact closure manifest for a proposed local approval.

  `build/3` consumes explicitly selected typed records and the checked reader,
  rebuilds the inspection, and joins the envelope, profile and definition object
  summaries into a content-addressed `WotexHome.Profiles.ExternalArtifact`.

  The function is pure. Store must establish ownership of every record, current
  reader policy and the operation's revision basis before recording approval.
  Building this value does not approve or select a target.
  """

  alias WotexHome.Profiles.{EnvelopeCodec, ExternalArtifact, InspectionPreparation}

  def build(input, records, reader) do
    with {:ok, inspection} <- InspectionPreparation.build(input, records, reader),
         i = input["inspection"],
         indexed = Map.new(records, &{&1["object"]["object_digest"], &1}),
         {:ok, envelope} <-
           EnvelopeCodec.decode(indexed[i["envelope_ref"]["object_digest"]]["payload"]),
         objects =
           [
             object(indexed, i["envelope_ref"], nil),
             object(indexed, i["profile"]["object_ref"], i["profile"]["reference"])
           ] ++ Enum.map(i["definitions"], &object(indexed, &1["object_ref"], &1["reference"])),
         artifact = %{
           "format" => "wotex-home.external-artifact@1",
           "id" => envelope["id"],
           "version" => envelope["version"],
           "objects" => objects
         },
         {:ok, digest} <- ExternalArtifact.identity(artifact),
         do:
           {:ok,
            %{"artifact" => artifact, "artifact_digest" => digest, "inspection" => inspection}}
  end

  defp object(indexed, handle, reference),
    do: Map.put(indexed[handle["object_digest"]]["object"], "reference", reference)
end
