defmodule WotexHome.Profiles.AuthoredEnvelope do
  @moduledoc """
  Joins a finalized profile bundle with a Home envelope and explicit capture.

  `compile/3` first rechecks a compatible validated assessment, then reconstructs
  canonical profile and definition documents from its exact bundle. It delegates
  the selected envelope, installed registrations, capture and limits to
  `WotexHome.Profiles.ExternalEnvelope`.

  The result is a checked consumption proposal. It creates no durable approval,
  source lease, enrolled target or physical qualification.
  """

  alias WotexHome.Profiles.{AuthoringAssessment, AuthoringProducer, ExternalEnvelope}

  def compile(assessment, bytes, capture) do
    with {:ok, summary} <- AuthoringAssessment.to_map(assessment, contract(assessment)),
         true <- summary["disposition"] == "compatible" and summary["phase"] == "validate",
         limits = assessment.contract.inputs["limits"]["reader"],
         {:ok, bundle} <-
           producer(Wotex.JSON, :decode, [
             assessment.bundle_bytes,
             [
               max_bytes: 262_144,
               max_depth: 8,
               max_nodes: 4096,
               max_collection_size: 256,
               max_string_bytes: 4096
             ]
           ]),
         {:ok, profile} <- record(bundle["profile"], Wotex.Profiles.Profile, limits),
         {:ok, definitions} <- definitions(bundle["definitions"], limits),
         documents = %{"profile" => profile, "definitions" => definitions},
         do:
           ExternalEnvelope.compile(
             bytes,
             documents,
             assessment.contract.inputs["installed"],
             capture,
             limits
           ),
         else: (
           false -> {:error, :candidate_incompatible}
           error -> error
         )
  end

  defp contract(%AuthoringAssessment{contract: c}), do: c
  defp contract(_), do: nil

  defp record(data, module, limits) do
    with {:ok, bytes} <- producer(Wotex.JSON, :encode, [data]),
         {:ok, reference} <- producer(module, :reference, [data, limits]),
         do:
           {:ok,
            %{
              "bytes" => bytes,
              "raw_sha256" => AuthoringProducer.sha(bytes),
              "reference" => reference
            }}
  end

  defp definitions(data, limits) do
    Enum.reduce_while(data, {:ok, []}, fn value, {:ok, records} ->
      case record(value, Wotex.Profiles.Definition, limits) do
        {:ok, value} -> {:cont, {:ok, [value | records]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp producer(module, function, args),
    do: AuthoringProducer.call(module, function, args, :invalid_authoring_review)
end
