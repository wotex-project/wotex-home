defmodule WotexHome.Rules.ExternalFact do
  @moduledoc """
  Reconstructs an original external reader proposal before joining a routine Fact.

  `project/4` takes a native `WotexHome.Profiles.ExternalValue`, an installed
  Mapping map or `Wotex.Routines.InputMapping`, plain observation metadata and a
  context containing exactly `"consumer"`, `"envelope"`, `"limits"`, `"reader_limits"`
  and `"registry"`. All selections are explicit. The envelope, consumer contract
  and reader limits must match the retained value; the Mapping and its complete
  Basis/correspondence must be installed in the supplied registry.

  The value is first regenerated through
  `WotexHome.Profiles.ExternalValue.to_map/4`. The original WPF proposal is then
  reconstructed from the checked envelope projection and retained raw report.
  Home's consumed value may already use different units, so its converted
  coordinate is never passed off as the original reader value. Public routine
  input APIs perform the separate exact conversion into the requested Fact unit.

  Success is `{:ok, result}` with format `wotex-home.external-routine-fact@1`
  and scope `external_fact_projection_only`. The plain `"fact"` and complete
  `"binding_basis"` retain the external profile identity and embedded Mapping,
  distinct from the installed Basis digest. Separate `"external_value_sha256"`
  and `"source_proposal_sha256"` witnesses bind the checked Home value and
  original proposal; exact Mapping/correspondence references accompany them.

  Metadata must explicitly set `"received_at"` to `nil`: the decoded report
  supplies no receipt UTC witness. Omission or a non-null timestamp refuses.
  Source UTC, processing time and an epoch cannot fill that field. Explicit
  receipt coordinates must satisfy the Mapping's selected exact or
  `floor_millisecond` clock relation. The floor alternative also caps expiry at
  projected receipt plus installed freshness; expiry remains exclusive. This
  helper neither samples a clock nor qualifies that correspondence or source trust.

  Selected routine limits may narrow ceilings of 262,144 bytes, depth 32,
  20,000 nodes, 8192 string bytes, 128 collection members and signed-64 maximum
  integer magnitude. Reader and native-input limits apply separately. The entire
  result, including every embedded Mapping occurrence, must fit; no truncation
  or partial result is returned.

  Failures are payload-free `{:error, code}` tuples: `:invalid_external_fact`,
  `:external_fact_limit`, `:external_fact_unavailable`, `:stale_external_fact`,
  `:unsupported_external_fact`, `:inexact_external_fact` or
  `:external_fact_refused`. Producer errors and caught failures are reduced to
  those codes, without a fallback or echoed exception text.

  Revalidating the value's runtime producer assertions may invoke
  `WotexHome.RuntimeArtifacts` file reads and bounded temporary readers, with
  cleanup owned there. Historical archive assertions do not prove the installed
  runtime. This helper supplies no Store connection, current observation read,
  custody or authorization. Its inert result does not qualify a household source,
  establish current freshness or authorize an effect.
  """

  alias WotexHome.Profiles.{EnvelopeCodec, ExternalEnvelope, ExternalValue}
  alias Wotex.Routines.{Fact, Input, InputMapping, Limits}

  @context ~w(consumer envelope limits reader_limits registry)
  @metadata Enum.sort(
              ~w(id thing_id affordance_type affordance_name source_class source_id source_epoch sequence
                source_time source_time_trust source_time_basis source_uncertainty_ms received_at
                receipt_epoch receipt_ms profile_digest replay continuity expires_ms derivation_digest contributors)
            )
  @ceilings %{
    "max_bytes" => 262_144,
    "max_depth" => 32,
    "max_nodes" => 20_000,
    "max_string_bytes" => 8192,
    "max_collection_size" => 128,
    "max_integer" => 9_223_372_036_854_775_807
  }
  @api [
    {Wotex.JSON, :encode, 2},
    {Wotex.Profiles.Interpreter, :project, 3},
    {Wotex.Profiles.Proposal, :to_map, 2},
    {Limits, :new, 1},
    {Fact, :to_map, 2},
    {InputMapping, :to_map, 3},
    {Input, :project, 4},
    {Input, :binding_basis, 3}
  ]
  @errors ~w(invalid_external_fact external_fact_limit external_fact_unavailable stale_external_fact
    unsupported_external_fact inexact_external_fact external_fact_refused)a
  @limit_codes ~w(external_profile_limit input_limit numeric_limit output_limit integer_overflow
    invalid_limits limit_or_json_error byte_limit_exceeded depth_limit_exceeded node_limit_exceeded
    string_limit_exceeded collection_limit_exceeded)a
  @unavailable_codes ~w(missing_producer profiles_producer_unavailable profile_runtime_source_unavailable
    runtime_artifact_unavailable)a
  @stale_codes ~w(stale_basis reference_conflict stale_external_basis stale_profile_runtime)a
  @unsupported_codes ~w(unsupported_mapping unsupported_representation incompatible_dimension
    unsupported_semantics unsupported_binding unsupported_schema missing_reference cyclic_reference
    unknown_required_contract unsupported_external_profile unsupported_external_value)a
  @invalid_codes ~w(invalid_input invalid_type invalid_struct missing_field unknown_field invalid_string
    invalid_digest invalid_timestamp unsupported_value invalid_external_value invalid_external_closure
    invalid_external_envelope)a

  @doc "Returns a closed inert Fact/binding result from the checked original report and explicit inputs."
  @spec project(term(), term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def project(value, mapping, metadata, context) do
    guarded(fn ->
      with :ok <- shape(metadata, context),
           :ok <- available(),
           :ok <- ExternalEnvelope.check_reader_limits(context["reader_limits"]),
           {:ok, limits} <- selected_limits(context["limits"]),
           {:ok, exported} <-
             ExternalValue.to_map(
               value,
               context["envelope"],
               context["consumer"],
               context["reader_limits"]
             ),
           {:ok, proposal} <-
             Wotex.Profiles.Interpreter.project(
               context["envelope"].projection,
               value.inputs["report"],
               context["reader_limits"]
             ),
           {:ok, proposal} <- Wotex.Profiles.Proposal.to_map(proposal, context["reader_limits"]),
           {:ok, mapping} <- InputMapping.to_map(mapping, context["registry"], limits),
           {:ok, result} <-
             Input.project(proposal, mapping, metadata, %{
               "registry" => context["registry"],
               "limits" => limits,
               "reader_limits" => context["reader_limits"]
             }),
           :ok <- input_result(result, mapping),
           {:ok, fact} <- Fact.to_map(result["fact"], limits),
           {:ok, binding} <- binding(mapping, context["registry"], limits),
           output = %{
             "format" => "wotex-home.external-routine-fact@1",
             "scope" => "external_fact_projection_only",
             "external_value_sha256" => exported["sha256"],
             "source_proposal_sha256" => result["source_proposal_sha256"],
             "mapping_ref" => result["mapping_ref"],
             "correspondence_ref" => result["correspondence_ref"],
             "fact" => fact,
             "binding_basis" => binding
           },
           {:ok, _} <- Wotex.JSON.encode(output, json_options(limits)) do
        {:ok, output}
      end
    end)
  end

  defp shape(metadata, context) do
    if EnvelopeCodec.keys?(context, @context) and EnvelopeCodec.keys?(metadata, @metadata) and
         metadata["received_at"] == nil,
       do: :ok,
       else: {:error, :invalid_external_fact}
  end

  defp available do
    if Enum.all?(@api, fn {module, function, arity} ->
         Code.ensure_loaded?(module) and function_exported?(module, function, arity)
       end),
       do: :ok,
       else: {:error, :external_fact_unavailable}
  end

  defp selected_limits(input) do
    with {:ok, limits} <- Limits.new(input) do
      if Enum.all?(@ceilings, fn {key, maximum} -> limits.data[key] in 1..maximum end),
        do: {:ok, limits},
        else: {:error, :external_fact_limit}
    end
  end

  defp input_result(result, mapping) do
    if EnvelopeCodec.keys?(result, ~w(correspondence_ref fact mapping_ref source_proposal_sha256)) and
         EnvelopeCodec.digest?(result["source_proposal_sha256"]) and
         result["mapping_ref"] == Map.take(mapping, ~w(id version sha256)) and
         result["correspondence_ref"] == mapping["correspondence_ref"],
       do: :ok,
       else: {:error, :external_fact_refused}
  end

  defp binding(mapping, registry, limits) do
    expected = %{
      "format" => "wotex.routines.external-binding@1",
      "profile_digest" => "sha256:" <> mapping["profile_sha256"],
      "source_id" => mapping["observation"]["source_ref"],
      "source_epoch" => mapping["observation"]["source_epoch"],
      "source_time_basis" => mapping["observation"]["source_time_basis"],
      "input_mapping" => mapping
    }

    with {:ok, basis} <- Input.binding_basis(mapping, registry, limits) do
      if basis == expected, do: {:ok, basis}, else: {:error, :external_fact_refused}
    end
  end

  defp json_options(limits) do
    for key <- ~w(max_bytes max_depth max_nodes max_string_bytes max_collection_size)a,
        do: {key, limits.data[Atom.to_string(key)]}
  end

  defp guarded(callback) do
    case callback.() do
      {:ok, result} when is_map(result) -> {:ok, result}
      error -> refusal(error)
    end
  rescue
    _ -> {:error, :external_fact_refused}
  catch
    _, _ -> {:error, :external_fact_refused}
  end

  defp refusal({:error, %{code: code}}), do: refusal({:error, code})
  defp refusal({:error, code}) when code in @errors, do: {:error, code}
  defp refusal({:error, code}) when code in @limit_codes, do: {:error, :external_fact_limit}

  defp refusal({:error, code}) when code in @unavailable_codes,
    do: {:error, :external_fact_unavailable}

  defp refusal({:error, code}) when code in @stale_codes, do: {:error, :stale_external_fact}

  defp refusal({:error, code}) when code in @unsupported_codes,
    do: {:error, :unsupported_external_fact}

  defp refusal({:error, code}) when code in [:inexact_conversion, :inexact_external_value],
    do: {:error, :inexact_external_fact}

  defp refusal({:error, code}) when code in @invalid_codes, do: {:error, :invalid_external_fact}
  defp refusal(_), do: {:error, :external_fact_refused}
end
