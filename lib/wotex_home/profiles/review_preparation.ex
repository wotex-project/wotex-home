defmodule WotexHome.Profiles.ReviewPreparation do
  @moduledoc "Pure recomputation of one retained candidate's attribution and optional complete envelope/fixture review."
  alias WotexHome.Profiles.{
    AuthoringAssessment,
    AuthoredEnvelope,
    AuthoringFixtures,
    AuthoringProducer,
    SourceReview,
    ExternalEnvelope
  }

  def build(context, records, review, contract, capture) do
    request = context.candidate_input["request"]
    draft = records[request["base_draft_ref"]["object_digest"]]

    with {:ok, assessment} <- AuthoringAssessment.assess(draft["payload"], contract, nil),
         true <- assessment.data == context.assessment,
         true <- bundle_matches?(assessment, context.candidate_receipt, records),
         sources = Enum.map(request["source_refs"], &records[&1["object_digest"]]),
         {:ok, source} <-
           SourceReview.check(assessment, sources, review["evidence"], review["unresolved_paths"]),
         {:ok, source} <- SourceReview.to_map(source, assessment),
         {:ok, envelope, fixtures} <- complete(review, request, assessment, records, capture) do
      {:ok,
       %{
         "format" => "wotex-home.authoring-review-result@1",
         "source" => source,
         "envelope" => envelope,
         "fixtures" => fixtures
       }}
    else
      false -> {:error, :stale_authoring_basis}
      error -> error
    end
  end

  defp bundle_matches?(assessment, %{"bundle" => nil}, _), do: assessment.bundle_bytes == nil

  defp bundle_matches?(assessment, %{"bundle" => bundle}, records),
    do: records[bundle["object_digest"]]["payload"] == assessment.bundle_bytes

  defp complete(%{"mode" => "source"}, _, _, _, _), do: {:ok, nil, nil}
  defp complete(_, _, _, _, nil), do: {:error, :authoring_capture_unavailable}

  defp complete(review, request, assessment, records, capture) do
    envelope = records[review["envelope_ref"]["object_digest"]]
    limits = assessment.contract.inputs["limits"]["reader"]

    with {:ok, envelope} <- AuthoredEnvelope.compile(assessment, envelope["payload"], capture),
         {:ok, fixtures} <- fixtures(request["fixture_refs"], records),
         {:ok, checked} <- AuthoringFixtures.check(envelope, fixtures, limits),
         {:ok, fixture_summary} <- AuthoringFixtures.to_map(checked, envelope, limits),
         {:ok, envelope_summary} <- ExternalEnvelope.to_map(envelope, limits),
         do: {:ok, envelope_summary, fixture_summary}
  end

  defp fixtures(refs, records) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, items} ->
      case AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [
               records[ref["object_digest"]]["payload"],
               [
                 max_bytes: 65536,
                 max_depth: 8,
                 max_nodes: 4096,
                 max_collection_size: 256,
                 max_string_bytes: 256
               ]
             ],
             :invalid_authoring_fixture
           ) do
        {:ok, value} when is_map(value) and not is_struct(value) ->
          {:cont, {:ok, [value | items]}}

        {:ok, _} ->
          {:halt, {:error, :invalid_authoring_fixture}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.sort_by(items, & &1["id"])}
      error -> error
    end
  end
end
