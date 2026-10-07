defmodule WotexHome.Schedules.AdmissionArtifact do
  @moduledoc "Closed single-schedule admission content; only the Store can admit or activate it after current owned-state checks."
  alias WotexHome.Durable.Registry
  alias WotexHome.Lifx.DirectPowerSafety
  alias WotexHome.Rules.CandidateArtifact
  alias WotexHome.Schedules.{Codec, OperationInput, Planner, TemporalBasis, Tzif}

  @profile "home-single-schedule-light-admission-v1"
  @scope "single_schedule_absolute_effect"
  @maximum_bytes 262_144
  @fields ~w(profile scope source_document rule_document resources invariant profile_pin timezone temporal_basis mandatory_guards physical_qualification)
  @guards ~w(current_original_author original_target_grant authority_epoch active_generation exact_declaration profile_selection current_invariant operator_override fresh_report profile_qualification single_active_schedule capacity_reservation considered_watermark qualified_host_clock original_boot_generation whole_interval_window final_temporal_handoff causal_reservation effect_serialization attempt_budget durable_handoff)
  @pin_fields ~w(target_id artifact_digest projection_digest selection_revision selection_generation trust_revision resource_revision)
  @hash ~r/\A[0-9a-f]{64}\z/

  def build(source_document, rule_document, resources, invariant, profile_pin, zone \\ nil) do
    with {:ok, source, rule, things} <- content(source_document, rule_document, resources),
         :ok <- pins(source, invariant, profile_pin),
         :ok <- Planner.cadence(source, zone),
         {:ok, basis} <- TemporalBasis.qualify(source_document, rule_document, things, zone),
         data = %{
           "profile" => @profile,
           "scope" => @scope,
           "source_document" => source_document,
           "rule_document" => rule_document,
           "resources" => resources,
           "invariant" => invariant,
           "profile_pin" => profile_pin,
           "timezone" => timezone(source, zone),
           "temporal_basis" => basis,
           "mandatory_guards" => @guards,
           "physical_qualification" => "required_at_dispatch"
         },
         document = JSON.encode!(data),
         true <- byte_size(document) <= @maximum_bytes,
         true <- elem(rule.effect, 0) == source["target_id"],
         do: {:ok, document},
         else: (_ -> {:error, :unsupported_schedule_admission})
  end

  # Historical decode validates complete content without treating retained
  # runtime bytes as today's compiled/runtime evidence or invoking a verifier.
  def decode(document) when is_binary(document) and byte_size(document) in 1..@maximum_bytes do
    with {:ok, data} <- JSON.decode(document),
         true <- Codec.exact?(data, @fields),
         true <- data["profile"] == @profile and data["scope"] == @scope,
         true <- data["mandatory_guards"] == @guards,
         true <- data["physical_qualification"] == "required_at_dispatch",
         true <- JSON.encode!(data) == document,
         {:ok, source, rule, things} <-
           content(data["source_document"], data["rule_document"], data["resources"]),
         :ok <- pins(source, data["invariant"], data["profile_pin"]),
         {:ok, zone} <- decode_timezone(source, data["timezone"]),
         :ok <- Planner.cadence(source, zone),
         true <- TemporalBasis.valid?(data["temporal_basis"]),
         basis = data["temporal_basis"],
         true <-
           basis["source_digest"] == Codec.hash(data["source_document"]) and
             basis["rule_document_digest"] == Codec.hash(data["rule_document"]) and
             basis["declaration_digest"] == Codec.hash(hd(data["resources"])["document"]) and
             basis["timezone_digest"] == TemporalBasis.timezone_digest(source) do
      {:ok,
       %{
         source: source,
         source_document: data["source_document"],
         rule: rule,
         rule_document: data["rule_document"],
         resources: data["resources"],
         things: things,
         invariant: data["invariant"],
         profile_pin: data["profile_pin"],
         timezone: zone,
         temporal_basis: basis
       }}
    else
      _ -> {:error, :corrupt_schedule_admission}
    end
  end

  def decode(_), do: {:error, :corrupt_schedule_admission}

  def current(document) do
    with {:ok, decoded} <- decode(document),
         {:ok, current} <-
           build(
             decoded.source_document,
             decoded.rule_document,
             decoded.resources,
             decoded.invariant,
             decoded.profile_pin,
             decoded.timezone
           ),
         true <- current == document,
         do: {:ok, decoded},
         else: (_ -> {:error, :stale_schedule_admission})
  end

  def digest(document), do: Codec.hash(document)

  defp content(source_document, rule_document, resources) do
    input = %{
      "authority_epoch" => 1,
      "operation_id" => "schedule:artifact",
      "expected_revision" => 0,
      "source_document" => source_document,
      "rule_document" => rule_document
    }

    with {:ok, source, rule} <- OperationInput.source("admit", input),
         [%{"thing_id" => target, "resource_revision" => revision, "document" => document}] <-
           resources,
         true <- target == source["target_id"] and revision == source["resource_revision"],
         {:ok, %{^target => thing} = things} <- CandidateArtifact.things(resources),
         {:ok, ^document} <- Registry.encode_thing(thing),
         true <- DirectPowerSafety.decision(thing) == :allow,
         do: {:ok, source, rule, things},
         else: (_ -> {:error, :unsupported_schedule_content})
  end

  defp pins(source, invariant, profile_pin) do
    target = source["target_id"]

    if Codec.exact?(invariant, ~w(target_id revision digest)) and
         invariant["target_id"] == target and
         Codec.integer?(invariant["revision"], 0, Codec.maximum()) and
         ((invariant["revision"] == 0 and invariant["digest"] == nil) or
            (invariant["revision"] > 0 and hash?(invariant["digest"]))) and
         profile_pin?(profile_pin, source), do: :ok, else: {:error, :invalid_schedule_pins}
  end

  defp profile_pin?(nil, _), do: true

  defp profile_pin?(pin, source),
    do:
      Codec.exact?(pin, @pin_fields) and pin["target_id"] == source["target_id"] and
        pin["resource_revision"] == source["resource_revision"] and
        hash?(pin["artifact_digest"]) and hash?(pin["projection_digest"]) and
        Enum.all?(
          ~w(selection_revision selection_generation trust_revision),
          &Codec.integer?(pin[&1], 1, Codec.maximum())
        ) and
        pin["selection_revision"] <= pin["resource_revision"]

  defp hash?(value), do: is_binary(value) and byte_size(value) == 64 and value =~ @hash

  defp timezone(source, zone) do
    if TemporalBasis.timezone_digest(source) do
      %{"name" => zone.name, "digest" => zone.digest, "data_base64" => Base.encode64(zone.bytes)}
    end
  end

  defp decode_timezone(source, data) do
    case {TemporalBasis.timezone_digest(source), data} do
      {nil, nil} ->
        {:ok, nil}

      {digest, %{"name" => name, "digest" => digest, "data_base64" => encoded} = record}
      when is_binary(encoded) and byte_size(encoded) <= 87_384 ->
        with true <- map_size(record) == 3,
             {:ok, bytes} <- Base.decode64(encoded),
             true <- Base.encode64(bytes) == encoded,
             {:ok, %Tzif{digest: ^digest} = zone} <- Tzif.decode(name, bytes),
             do: {:ok, zone},
             else: (_ -> {:error, :corrupt_schedule_timezone})

      _ ->
        {:error, :corrupt_schedule_timezone}
    end
  end
end
