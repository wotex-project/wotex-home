defmodule WotexHome.Profiles.ExternalObservationPreparation do
  @moduledoc """
  Reconstructs one original transport report under its selected native profile.

  `WotexHome.Profiles.ExternalObservationPreparation.build/6` takes the target
  input, checked immutable profile records, host-held source selection, original
  report document, retained target outcome and selection revision. It rebuilds
  the actual envelope, requires exact equality with the retained target outcome,
  and projects through the report channel's explicit Home consumer policy.

  Success returns `{:ok, prepared}` with atom keys `:outcome`, `:value` and
  `:capability`. The outcome preserves the original report document, canonical
  value document, digests and selection/declaration/source correspondence.
  Refusals return `{:error, reason}`; a mismatched target is
  `{:error, :stale_external_basis}`. Missing channel or unsupported value
  correspondence refuses instead of inventing a replacement observation.

  The internal
  `WotexHome.Profiles.ExternalObservationPreparation.build_native/6` performs
  the same reconstruction and also returns `:native_value`, `:envelope`,
  `:consumer` and `:reader_limits`. The Store collector uses these actual native
  objects to repeat interpretation and project a qualified external Fact.
  `WotexHome.Profiles.ExternalObservationPreparation.build/6` keeps its original
  three-key result shape.

  This computation reads no owner and commits nothing. `WotexHome.Durable.Store`
  must check live source/report witnesses, selected target, current grants,
  clocks and revision basis before publishing an observation or snapshot.
  Reconstruction alone establishes no current authorization or physical proof.
  """

  alias WotexHome.Profiles.{
    ExternalObservation,
    ExternalTargetPreparation,
    ExternalValue,
    ReadDeclarationCodec
  }

  alias WotexHome.Durable.Registry

  def build(target_input, records, source, report_document, retained_target, selection_revision) do
    with {:ok, prepared} <-
           build_native(
             target_input,
             records,
             source,
             report_document,
             retained_target,
             selection_revision
           ),
         do: {:ok, Map.take(prepared, [:outcome, :value, :capability])}
  end

  @doc false
  def build_native(
        target_input,
        records,
        source,
        report_document,
        retained_target,
        selection_revision
      ) do
    with {:ok, prepared} <-
           ExternalTargetPreparation.build_with_envelope(
             target_input,
             records,
             source,
             retained_target["artifact_document"]
           ),
         true <- prepared.outcome == retained_target,
         {:ok, report} <- WotexHome.Profiles.RetainedJSON.decode(report_document),
         channel when is_map(channel) <-
           Enum.find(source.inputs["channels"], &(&1["channel_id"] == report["channel_id"])),
         {:ok, value} <-
           ExternalValue.project(
             prepared.envelope,
             report,
             channel["consumer"],
             source.inputs["reader"].inputs["reader_limits"]
           ),
         {:ok, exported} <-
           ExternalValue.to_map(
             value,
             prepared.envelope,
             channel["consumer"],
             source.inputs["reader"].inputs["reader_limits"]
           ),
         {:ok, value_document} <- canonical(exported["data"]),
         {:ok, thing} <- Registry.decode_thing(retained_target["thing_document"]),
         {:ok, capability} <-
           WotexHome.Semantics.Thing.capability(thing, channel["policy"]["capability_key"]),
         {:ok, _} <- ReadDeclarationCodec.decode(capability.record),
         outcome = %{
           "format" => "wotex-home.external-observation-result@1",
           "report_document" => report_document,
           "value_document" => value_document,
           "value_sha256" => exported["sha256"],
           "target_selection_revision" => selection_revision,
           "declaration_sha256" => capability.record["declaration_sha256"],
           "source_selection_sha256" => source.sha256
         },
         {:ok, _} <- ExternalObservation.encode_outcome(outcome),
         do:
           {:ok,
            %{
              outcome: outcome,
              value: exported["data"],
              capability: capability,
              native_value: value,
              envelope: prepared.envelope,
              consumer: channel["consumer"],
              reader_limits: source.inputs["reader"].inputs["reader_limits"]
            }},
         else: (
           false -> {:error, :stale_external_basis}
           nil -> {:error, :unsupported_external_value}
           :error -> {:error, :unsupported_external_value}
           error -> error
         )
  end

  defp canonical(data) do
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
      {:ok, bytes} when byte_size(bytes) <= 65536 -> {:ok, bytes}
      _ -> {:error, :external_profile_limit}
    end
  rescue
    e in UndefinedFunctionError ->
      if e.module == Wotex.JSON and e.function == :encode and e.arity == 2,
        do: {:error, :profiles_producer_unavailable},
        else: {:error, :invalid_external_observation}
  end
end
