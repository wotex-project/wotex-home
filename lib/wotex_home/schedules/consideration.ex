defmodule WotexHome.Schedules.Consideration do
  @moduledoc "Bounded original occurrence consumption and missed-range calculation. No effect admission, causal spend or transport authority."
  alias WotexHome.Schedules.{ActivationClock, Codec, Occurrence, Planner, Recurrence}

  @fields ~w(activation_revision previous_watermark watermark clock_document decision occurrence_document occurrence_id causal_id missed_lower missed_upper reason)a

  def fields, do: @fields

  def build(activation, artifact, snapshot, watermark) do
    with true <- Codec.integer?(activation.revision, 1, Codec.maximum()),
         true <- Codec.integer?(watermark, activation.watermark, Codec.maximum()),
         :ok <- qualified(snapshot),
         {:ok, _} <- ActivationClock.encode(snapshot, watermark),
         {:ok, original, _} <- ActivationClock.decode(activation.clock_document),
         true <-
           Map.take(snapshot.scope, scope_fields()) == Map.take(original.scope, scope_fields()),
         {:ok, plan} <-
           Planner.plan(
             artifact.source,
             watermark,
             snapshot.sample,
             snapshot.scope["store_boot_epoch"],
             snapshot.scope["clock_generation"],
             snapshot.now_ms,
             artifact.timezone
           ),
         {:ok, retain?} <- retained_work?(artifact, watermark, plan),
         do:
           if(retain?,
             do: record(activation, artifact.source, snapshot, watermark, plan),
             else: {:ok, :idle}
           ),
         else: (
           false -> {:error, :schedule_basis_changed}
           error -> error
         )
  rescue
    _ -> {:error, :invalid_schedule_consideration}
  end

  def valid?(record, activation, artifact) do
    with true <- Codec.exact?(record, @fields),
         {:ok, snapshot, watermark} <- ActivationClock.decode(record.clock_document),
         true <- watermark == record.watermark,
         {:ok, ^record} <- build(activation, artifact, snapshot, record.previous_watermark),
         do: true,
         else: (_ -> false)
  end

  defp retained_work?(_artifact, _, %{coordinate: coordinate}) when not is_nil(coordinate),
    do: {:ok, true}

  defp retained_work?(_artifact, _, %{missed_range: nil}), do: {:ok, false}

  defp retained_work?(artifact, watermark, %{missed_range: [watermark, cutoff]}) do
    with {:ok, next} <- Recurrence.next(artifact.source, watermark, artifact.timezone),
         do: {:ok, next != nil and next <= cutoff}
  end

  defp record(activation, source, snapshot, previous, plan) do
    with true <- plan.watermark > previous,
         {:ok, clock} <- ActivationClock.encode(snapshot, plan.watermark),
         {:ok, identity} <- identity(source, activation, plan.coordinate) do
      [missed_lower, missed_upper] = plan.missed_range || [nil, nil]

      {:ok,
       %{
         activation_revision: activation.revision,
         previous_watermark: previous,
         watermark: plan.watermark,
         clock_document: clock,
         decision: Atom.to_string(plan.decision),
         occurrence_document: if(identity, do: identity.document),
         occurrence_id: if(identity, do: identity.id),
         causal_id: if(identity, do: identity.root_id),
         missed_lower: missed_lower,
         missed_upper: missed_upper,
         reason: reason(plan.decision)
       }}
    else
      false -> {:error, :invalid_schedule_cursor}
      error -> error
    end
  end

  defp identity(_, _, nil), do: {:ok, nil}

  defp identity(source, activation, coordinate) do
    with {:ok, occurrence} <-
           Occurrence.build(source, activation.epoch, activation.generation, coordinate),
         do: Occurrence.identity(occurrence)
  end

  defp reason(:idle), do: "missed_range"
  defp reason(:eligible), do: "temporal_execution_unavailable"
  defp reason(:uncertain), do: "clock_uncertain"
  defp reason(:expired), do: "occurrence_expired"
  defp scope_fields, do: ~w(deployment_id owner_id authority_epoch runtime_digest)

  defp qualified(%{reason: nil, sample: %{"wall_confidence" => "qualified"}}), do: :ok
  defp qualified(_), do: {:error, :temporal_clock_unavailable}
end
