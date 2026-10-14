defmodule WotexHome.Profiles.SourceReview do
  @moduledoc """
  Checks explicit attribution coverage for a compatible profile draft.

  `check/4` derives required draft paths and compares supplied citations and
  unresolved paths against verified source originals. Its summary distinguishes
  covered, missing, ambiguous and unresolved paths, retaining exact source-set
  and evidence digests. `to_map/2` recomputes against the current assessment.

  Locators are operator-supplied attribution, not fetched documents or factual
  verification. Coverage does not prove that a cited source is correct, admit
  a profile or establish physical qualification.
  """

  alias WotexHome.Profiles.{AuthoringAssessment, AuthoringProducer, EnvelopeCodec, SourcePassages}
  @enforce_keys [:assessment, :sources, :evidence, :unresolved_paths, :data]
  defstruct @enforce_keys

  def check(assessment, sources, evidence, unresolved) do
    with {:ok, summary} <- AuthoringAssessment.to_map(assessment, assessment_contract(assessment)),
         :ok <- compatible(summary),
         {:ok, data} <-
           producer(Wotex.JSON, :decode, [assessment.draft_bytes, options(assessment)]),
         roots = required_roots(data),
         :ok <- source_records(sources),
         :ok <- citations(evidence, unresolved, roots, sources),
         source_bytes =
           JSON.encode!(
             Enum.map(sources, fn r ->
               Enum.map(~w(kind object_digest payload_sha256 payload_bytes), &r["object"][&1]) ++
                 [r["first_revision"]]
             end)
           ),
         evidence_bytes =
           JSON.encode!([
             Enum.map(
               evidence,
               &Enum.map(~w(instance_path source_ref locator), fn key -> &1[key] end)
             ),
             unresolved
           ]),
         counts = Enum.frequencies_by(evidence, & &1["instance_path"]),
         ambiguous = Enum.filter(roots, &(Map.get(counts, &1, 0) > 1)),
         missing = Enum.filter(roots, &(Map.get(counts, &1, 0) == 0 and &1 not in unresolved)),
         covered = Enum.filter(roots, &(Map.get(counts, &1, 0) == 1 and &1 not in unresolved)),
         result = %{
           "format" => "wotex-home.authoring-source@1",
           "basis_sha256" => summary["basis_sha256"],
           "draft_sha256" => summary["draft_sha256"],
           "sources_sha256" =>
             AuthoringProducer.sha("wotex-home.authoring-sources@1\n" <> source_bytes),
           "evidence_sha256" =>
             AuthoringProducer.sha("wotex-home.authoring-evidence@1\n" <> evidence_bytes),
           "status" => status(ambiguous, missing, unresolved),
           "required_paths" => roots,
           "covered_paths" => covered,
           "missing_paths" => missing,
           "ambiguous_paths" => ambiguous,
           "unresolved_paths" => unresolved
         },
         {:ok, encoded} <- producer(Wotex.JSON, :encode, [result]),
         :ok <- result_size(encoded) do
      {:ok,
       %__MODULE__{
         assessment: assessment,
         sources: sources,
         evidence: evidence,
         unresolved_paths: unresolved,
         data: result
       }}
    else
      error -> normalize(error)
    end
  end

  def to_map(%__MODULE__{} = value, current) when map_size(value) == 6 do
    with {:ok, old} <-
           AuthoringAssessment.to_map(value.assessment, assessment_contract(value.assessment)),
         {:ok, now} <- AuthoringAssessment.to_map(current, assessment_contract(current)),
         :ok <- same_basis(old, now),
         {:ok, rebuilt} <- check(current, value.sources, value.evidence, value.unresolved_paths),
         true <- rebuilt == value,
         do: {:ok, rebuilt.data},
         else: (
           false -> {:error, :invalid_authoring_review}
           error -> normalize(error)
         )
  end

  def to_map(_, _), do: {:error, :invalid_authoring_review}
  defp assessment_contract(%AuthoringAssessment{contract: contract}), do: contract
  defp assessment_contract(_), do: nil

  defp options(a),
    do: [
      max_bytes: a.contract.inputs["limits"]["max_bundle_bytes"],
      max_depth: 8,
      max_nodes: 4096,
      max_collection_size: 256,
      max_string_bytes: 4096
    ]

  defp required_roots(data) do
    profile = data["profile"]

    fingerprints =
      profile["fingerprint"]
      |> Enum.with_index()
      |> Enum.map(fn {_, i} -> "/profile/fingerprint/#{i}" end)

    channels =
      profile["channels"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {c, i} ->
        Enum.map(~w(selector semantic invalid_values), &"/profile/channels/#{i}/#{&1}") ++
          if(c["conversion"] == nil, do: [], else: ["/profile/channels/#{i}/conversion"])
      end)

    definitions =
      data["definitions"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {_, i} ->
        Enum.map(~w(unit value_schema), &"/definitions/#{i}/#{&1}")
      end)

    Enum.sort(["/profile/binding" | fingerprints ++ channels ++ definitions])
  end

  defp source_records(records) do
    with :ok <- bounded(records, 32),
         true <-
           Enum.all?(
             records,
             &(EnvelopeCodec.keys?(&1, ~w(first_revision object payload)) and
                 is_map(&1["object"]) and EnvelopeCodec.digest?(&1["object"]["object_digest"]))
           ),
         refs = Enum.map(records, & &1["object"]["object_digest"]),
         true <- refs == Enum.sort(Enum.uniq(refs)),
         {:ok, _} <- SourcePassages.validate_sources(records, refs),
         do: :ok,
         else: (
           {:error, :authoring_limit} = error -> error
           _ -> {:error, :invalid_authoring_review}
         )
  end

  defp citations(evidence, unresolved, roots, sources) do
    with :ok <- bounded(evidence, 256),
         :ok <- bounded(unresolved, 64),
         true <-
           Enum.all?(evidence, fn e ->
             EnvelopeCodec.keys?(e, ~w(instance_path locator source_ref)) and
               e["instance_path"] in roots and EnvelopeCodec.digest?(e["source_ref"]) and
               EnvelopeCodec.text?(e["locator"], 256) and
               Enum.any?(sources, &(&1["object"]["object_digest"] == e["source_ref"]))
           end),
         ids = Enum.map(evidence, &{&1["instance_path"], &1["source_ref"], &1["locator"]}),
         true <- ids == Enum.sort(Enum.uniq(ids)),
         true <-
           Enum.all?(unresolved, &(&1 in roots)) and
             unresolved == Enum.sort(Enum.uniq(unresolved)),
         do: :ok,
         else: (
           false -> {:error, :invalid_authoring_review}
           error -> error
         )
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | tail], remaining), do: bounded(tail, remaining - 1)
  defp bounded(_, _), do: {:error, :invalid_authoring_review}
  defp status([_ | _], _, _), do: "ambiguous"
  defp status([], [], []), do: "attributed"
  defp status(_, _, _), do: "incomplete"

  defp compatible(%{"disposition" => "compatible", "phase" => "validate"}), do: :ok
  defp compatible(_), do: {:error, :candidate_incompatible}

  defp result_size(bytes),
    do: if(byte_size(bytes) <= 24576, do: :ok, else: {:error, :authoring_limit})

  defp same_basis(%{"basis_sha256" => b, "draft_sha256" => d}, %{
         "basis_sha256" => b,
         "draft_sha256" => d
       }),
       do: :ok

  defp same_basis(_, _), do: {:error, :stale_authoring_basis}

  defp producer(module, function, args),
    do: AuthoringProducer.call(module, function, args, :invalid_authoring_review)

  defp normalize({:error, reason})
       when reason in [
              :authoring_limit,
              :profiles_producer_unavailable,
              :candidate_incompatible,
              :stale_authoring_basis,
              :invalid_authoring_review
            ],
       do: {:error, reason}

  defp normalize(_), do: {:error, :invalid_authoring_review}
end
