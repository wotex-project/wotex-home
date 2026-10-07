defmodule WotexHome.Profiles.Review do
  @moduledoc """
  A closed portable-profile selection proposal from consumed host evidence.

  Revalidates bytes and the current identity snapshot, derives the declaration,
  and refuses grant widening. This pure value cannot select, qualify, persist
  an observation or authorize an effect. Authority supplies the authenticated
  Store basis and consumes its operator-bound capture before calling new/5.
  """

  alias WotexHome.Discovery.{EnrollmentReview, Interview}
  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.Profiles.{Artifact, Bindings, Codec, LedgerCodec, Operation}
  alias WotexHome.Semantics.Thing

  @format "wotex-home.profile-selection-review.v1"
  @format_v2 "wotex-home.profile-selection-review.v2"
  @capture_fields ~w(stable_id manufacturer model firmware)
  @basis_fields ~w(principal_id authority_epoch store_revision profile_policy_generation rule_generation maintenance_revision target_id resource_revision binding_revision selection_revision selection_generation trust_revision trust_generation artifact_digest projection_digest registry_digest profile_ref stable_id manufacturer model firmware current_thing_document)
  @integer_fields ~w(authority_epoch store_revision profile_policy_generation rule_generation maintenance_revision resource_revision binding_revision selection_revision selection_generation trust_revision trust_generation)
  @digest_fields ~w(artifact_digest projection_digest registry_digest)
  @max_i64 9_223_372_036_854_775_807
  @enforce_keys [
    :basis,
    :input_document,
    :artifact,
    :thing,
    :candidates,
    :capture_deadline,
    :interview,
    :enrollment,
    :runtime_digest,
    :document,
    :digest,
    :summary
  ]
  defstruct @enforce_keys

  def new(basis, %Artifact{bytes: bytes}, evidence, input, runtime_digest) do
    with {:ok, input_document} <- Operation.encode(input),
         "select" <- input["action"],
         :ok <- valid_basis(basis),
         true <- Codec.digest?(runtime_digest),
         :ok <- request_pins(basis, input),
         {:ok, artifact} <- Artifact.parse(bytes),
         true <-
           artifact.digest == basis["artifact_digest"] and
             artifact.projection_digest == basis["projection_digest"] and
             artifact.profile_ref == basis["profile_ref"] and
             hd(artifact.data["dependencies"])["sha256"] == basis["registry_digest"],
         {:ok, current} <- current_thing(basis),
         {:ok, thing} <- Artifact.declaration(artifact, basis["target_id"]),
         :ok <- declaration_scope(current, thing),
         {:ok, candidates, interview, deadline} <- evidence(evidence, input, basis),
         selection = selection(basis, input, artifact, interview),
         {:ok, enrollment} <-
           EnrollmentReview.new(candidates, interview, [artifact.profile], thing, selection),
         {:ok, thing_document} <- Registry.encode_thing(thing),
         summary = diff(current, thing),
         document =
           review_document(
             basis,
             input_document,
             runtime_digest,
             interview,
             enrollment.identity_digest,
             thing_document
           ),
         :ok <- bounded_document(document) do
      {:ok,
       %__MODULE__{
         basis: basis,
         input_document: input_document,
         artifact: artifact,
         thing: thing,
         candidates: candidates,
         capture_deadline: deadline,
         interview: interview,
         enrollment: enrollment,
         runtime_digest: runtime_digest,
         document: document,
         digest: Artifact.digest(document),
         summary: summary
       }}
    else
      false -> {:error, :profile_review_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_profile_review}
    end
  end

  def new(_, _, _, _, _), do: {:error, :invalid_profile_review}

  @doc "Reconstruct all proposal fields from bounded bytes/evidence before custody accepts them."
  def valid?(%__MODULE__{input_document: document} = review) do
    with {:ok, input} <- Operation.decode(document),
         evidence = %{
           ref: input["session_ref"],
           candidates: review.candidates,
           expires_at: review.capture_deadline,
           selected_candidate_ref: input["candidate_ref"],
           interview: review.interview
         },
         {:ok, ^review} <-
           new(review.basis, review.artifact, evidence, input, review.runtime_digest) do
      true
    else
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc "Validate retained correspondence without granting live capture authority."
  def decode_history(document, artifact_row)
      when is_binary(document) and byte_size(document) <= 65_536 and is_map(artifact_row) do
    with {:ok, _} <- LedgerCodec.encode("artifact", artifact_row),
         {:ok, decoded} <- JSON.decode(document),
         true <- JSON.encode!(decoded) == document,
         {:ok, version, mode, input_document, values, runtime, capture_values, identity,
          thing_document} <- history_fields(decoded),
         true <- is_list(values) and length(values) == length(@basis_fields),
         {:ok, input} <- Operation.decode(input_document),
         "select" <- input["action"],
         basis = Map.new(Enum.zip(@basis_fields, values)),
         :ok <- valid_basis(basis),
         :ok <- request_pins(basis, input),
         capture_values =
           if(version == 1, do: Enum.map(@capture_fields, &basis[&1]), else: capture_values),
         {:ok, captured} <- captured_identity(capture_values),
         :ok <- historical_scope(version, mode, basis, captured),
         true <- Codec.digest?(runtime) and Codec.digest?(identity),
         true <-
           Enum.all?(
             ~w(artifact_digest projection_digest registry_digest),
             &(basis[&1] == artifact_row[&1])
           ),
         true <- basis["profile_ref"] == artifact_row["id"] <> ":" <> artifact_row["version"],
         {:ok, data} <- Codec.decode(artifact_row["metadata_document"]),
         fingerprint = data["fingerprint"],
         true <-
           captured["manufacturer"] == fingerprint["manufacturer"] and
             captured["model"] == fingerprint["model"] and
             captured["firmware"] in fingerprint["firmware_versions"],
         {:ok, current} <- current_thing(basis),
         {:ok, thing} <-
           Bindings.historical_declaration(data, basis["artifact_digest"], basis["target_id"]),
         {:ok, ^thing_document} <- Registry.encode_thing(thing),
         :ok <- declaration_scope(current, thing),
         expected_identity = historical_identity(basis, captured, input, thing, thing_document),
         true <- identity == expected_identity do
      {:ok,
       %{
         input: input,
         basis: basis,
         captured_identity: captured,
         mode: if(is_nil(current), do: :initial, else: :replacement),
         version: version,
         runtime_digest: runtime,
         identity_digest: identity,
         thing_document: thing_document,
         thing: thing,
         current_thing: current,
         document: document,
         digest: Artifact.digest(document)
       }}
    else
      _ -> {:error, :invalid_profile_review_history}
    end
  end

  def decode_history(_, _), do: {:error, :invalid_profile_review_history}

  defp history_fields([@format, input, values, runtime, identity, declaration]),
    do: {:ok, 1, "replacement", input, values, runtime, nil, identity, declaration}

  defp history_fields([@format_v2, mode, input, values, runtime, captured, identity, declaration])
       when mode in ["initial", "replacement"],
       do: {:ok, 2, mode, input, values, runtime, captured, identity, declaration}

  defp history_fields(_), do: {:error, :invalid_profile_review_history}

  defp captured_identity(values) when is_list(values) and length(values) == 4 do
    captured = Map.new(Enum.zip(@capture_fields, values))

    if Enum.all?(values, &Id.valid?/1) and
         Regex.match?(~r/\Alifx:[0-9a-f]{12}\z/, captured["stable_id"]),
       do: {:ok, captured},
       else: {:error, :invalid_profile_review_history}
  end

  defp captured_identity(_), do: {:error, :invalid_profile_review_history}

  defp historical_scope(1, "replacement", basis, captured) do
    if not is_nil(basis["current_thing_document"]) and
         Enum.all?(@capture_fields, &(basis[&1] == captured[&1])),
       do: :ok,
       else: {:error, :invalid_profile_review_history}
  end

  defp historical_scope(2, "initial", basis, _captured),
    do:
      if(is_nil(basis["current_thing_document"]),
        do: :ok,
        else: {:error, :invalid_profile_review_history}
      )

  defp historical_scope(2, "replacement", basis, captured) do
    if not is_nil(basis["current_thing_document"]) and
         Enum.all?(~w(stable_id manufacturer model), &(basis[&1] == captured[&1])),
       do: :ok,
       else: {:error, :invalid_profile_review_history}
  end

  defp historical_scope(_, _, _, _), do: {:error, :invalid_profile_review_history}

  defp historical_identity(basis, captured, input, thing, document) do
    {"reviewed-identity-v2", basis["principal_id"], input["candidate_ref"], "udp",
     captured["manufacturer"], captured["model"], captured["firmware"], captured["stable_id"],
     basis["profile_ref"], thing.capabilities["power"].evidence_ref, thing.id, document,
     "legacy_tofu"}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp current_thing(%{"current_thing_document" => nil}), do: {:ok, nil}
  defp current_thing(basis), do: Registry.decode_thing(basis["current_thing_document"])
  defp declaration_scope(nil, _thing), do: :ok
  defp declaration_scope(current, thing), do: no_widening(current, thing)

  defp review_document(basis, input, runtime, interview, identity, declaration) do
    values = Enum.map(@basis_fields, &basis[&1])

    if not is_nil(basis["current_thing_document"]) and interview.firmware == basis["firmware"] do
      JSON.encode!([@format, input, values, runtime, identity, declaration])
    else
      captured = [
        interview.stable_id,
        interview.manufacturer,
        interview.model,
        interview.firmware
      ]

      mode = if is_nil(basis["current_thing_document"]), do: "initial", else: "replacement"
      JSON.encode!([@format_v2, mode, input, values, runtime, captured, identity, declaration])
    end
  end

  defp bounded_document(document) when byte_size(document) <= 65_536, do: :ok
  defp bounded_document(_), do: {:error, :profile_review_too_large}

  @doc "Validate the bounded authenticated snapshot shape without granting current authority."
  def valid_basis(basis) when is_map(basis) and not is_struct(basis) do
    if Enum.sort(Map.keys(basis)) == Enum.sort(@basis_fields) and
         Enum.all?(@integer_fields, &(is_integer(basis[&1]) and basis[&1] in 0..@max_i64)) and
         Enum.all?(@digest_fields, &Codec.digest?(basis[&1])) and
         Enum.all?(~w(principal_id target_id profile_ref), &Id.valid?(basis[&1])) and
         Enum.all?(
           ~w(authority_epoch maintenance_revision trust_revision trust_generation),
           &(basis[&1] > 0)
         ) and
         basis["binding_revision"] <= basis["store_revision"] and
         basis["trust_revision"] <= basis["store_revision"] and basis_identity?(basis) do
      :ok
    else
      {:error, :invalid_profile_review_basis}
    end
  end

  def valid_basis(_), do: {:error, :invalid_profile_review_basis}

  defp basis_identity?(%{"current_thing_document" => nil} = basis) do
    Enum.all?(
      ~w(resource_revision binding_revision selection_revision selection_generation),
      &(basis[&1] == 0)
    ) and
      Enum.all?(@capture_fields, &is_nil(basis[&1]))
  end

  defp basis_identity?(basis) do
    Enum.all?(@capture_fields, &Id.valid?(basis[&1])) and basis["binding_revision"] > 0 and
      is_binary(basis["current_thing_document"]) and
      byte_size(basis["current_thing_document"]) <= 65_536 and
      match?({:ok, %Thing{}}, Registry.decode_thing(basis["current_thing_document"]))
  end

  defp request_pins(basis, input) do
    pins = [
      {"authority_epoch", "authority_epoch"},
      {"store_revision", "expected_revision"},
      {"artifact_digest", "artifact_digest"},
      {"trust_revision", "expected_trust_revision"},
      {"target_id", "target_id"},
      {"resource_revision", "expected_resource_revision"},
      {"binding_revision", "expected_binding_revision"},
      {"selection_generation", "expected_selection_generation"},
      {"profile_policy_generation", "expected_policy_generation"},
      {"rule_generation", "expected_rule_generation"}
    ]

    if Enum.all?(pins, fn {key, request} -> basis[key] == input[request] end),
      do: :ok,
      else: {:error, :stale_profile_review_basis}
  end

  defp evidence(
         %{
           ref: ref,
           candidates: candidates,
           selected_candidate_ref: candidate,
           expires_at: deadline,
           interview: %Interview{} = interview
         },
         input,
         basis
       ) do
    if is_integer(deadline) and ref == input["session_ref"] and
         candidate == input["candidate_ref"] and
         interview.candidate_ref == candidate and capture_scope?(basis, interview) and
         interview.transport == "udp" do
      {:ok, candidates, interview, deadline}
    else
      {:error, :profile_capture_mismatch}
    end
  end

  defp evidence(_, _, _), do: {:error, :invalid_capture_evidence}

  defp capture_scope?(%{"current_thing_document" => nil}, interview),
    do:
      is_binary(interview.stable_id) and
        Regex.match?(~r/\Alifx:[0-9a-f]{12}\z/, interview.stable_id)

  defp capture_scope?(basis, interview) do
    interview.stable_id == basis["stable_id"] and interview.manufacturer == basis["manufacturer"] and
      interview.model == basis["model"] and is_binary(interview.firmware) and
      Regex.match?(~r/\A[0-9]+\.[0-9]+\z/, interview.firmware)
  end

  defp selection(basis, input, artifact, interview) do
    %{
      "operator_id" => basis["principal_id"],
      "candidate_ref" => input["candidate_ref"],
      "stable_id" => interview.stable_id,
      "profile_ref" => artifact.profile_ref,
      "qualification_ref" => artifact.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => input["review_ref"]
    }
  end

  @doc "Profile/evidence identity may change; existing executable semantics may only narrow."
  def no_widening(%Thing{} = current, %Thing{} = proposed) do
    allowed =
      current.id == proposed.id and current.role == proposed.role and
        Enum.all?(proposed.capabilities, fn {key, next} ->
          case current.capabilities[key] do
            nil ->
              false

            old ->
              old.thing_id == next.thing_id and old.role == next.role and old.key == next.key and
                old.value_kind == next.value_kind and old.unit == next.unit and
                old.risk_class == next.risk_class and old.extensions == next.extensions and
                next.freshness_ms <= old.freshness_ms and
                Enum.all?(next.operations, &(&1 in old.operations)) and
                narrower_constraints?(old.constraints, next.constraints)
          end
        end)

    if allowed, do: :ok, else: {:error, :declaration_widening}
  end

  def no_widening(_, _), do: {:error, :declaration_widening}

  defp narrower_constraints?(%{"min" => a, "max" => b}, %{"min" => c, "max" => d}),
    do: c >= a and d <= b

  defp narrower_constraints?(old, next), do: old == next

  defp diff(current, proposed) do
    %{
      status: :pending_authenticated_selection,
      identity_method: :legacy_tofu,
      qualification_status: :pending_physical_evidence,
      current_profile_ref: if(current, do: current.profile_ref, else: nil),
      proposed_profile_ref: proposed.profile_ref,
      removed_capabilities:
        if(current,
          do: Enum.sort(Map.keys(current.capabilities) -- Map.keys(proposed.capabilities)),
          else: []
        ),
      capabilities:
        proposed.capabilities
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {key, next} ->
          old = if(current, do: current.capabilities[key], else: nil)

          %{
            key: key,
            previous_operations: if(old, do: old.operations, else: []),
            proposed_operations: next.operations,
            previous_freshness_ms: if(old, do: old.freshness_ms, else: nil),
            proposed_freshness_ms: next.freshness_ms,
            value_kind: next.value_kind,
            unit: next.unit,
            risk_class: next.risk_class
          }
        end),
      new_control_grants: false,
      invalidation: [
        :qualification,
        :current_reports,
        :source_grants,
        :unsent_requests,
        :rule_policy
      ],
      handed_off_outcomes: :preserve_uncertainty
    }
  end
end
