defmodule WotexHome.Rules.AdmissionArtifact do
  @moduledoc """
  Closed admission package for one explicitly invoked ordinary Light power rule.

  The supported profile has one unconditional Boolean effect, ownership of one
  millisecond, no cooldown and a single effect per authenticated request root.
  The durable whole-Thing serialization and 250 ms attempt spacing exceed that
  ownership interval. No scheduler, edge, timer or composed temporal semantics
  is admitted. Physical qualification remains a separate dispatch obligation.

  History decodes without treating old runtime bytes as current evidence.
  Current use repeats the independent proposal correspondence and compares
  exact compiler, declaration, invariant and complete runtime commitments.
  """

  alias WotexHome.Rules.{CandidateArtifact, Codec, Compiler, RestrictedBasis}
  alias WotexHome.Lifx.DirectPowerSafety

  @profile "home-explicit-light-admission-v1"
  @max_bytes 4_194_304
  @guards ~w(current_principal target_grant authority_epoch active_generation exact_declaration current_invariant operator_override fresh_report profile_qualification effect_serialization attempt_budget causal_reservation durable_handoff)
  @hex64 ~r/\A[0-9a-f]{64}\z/

  def build(source, resources, invariant) do
    with {:ok, [rule]} <- Codec.decode(source),
         true <- rule.ownership_ms == 1,
         {:ok, things} <- CandidateArtifact.things(resources),
         [{target, thing}] <- Map.to_list(things),
         true <- DirectPowerSafety.decision(thing) == :allow,
         :ok <- invariant_pin(invariant, target),
         {:ok, basis} <- RestrictedBasis.qualify([rule], things) do
      document =
        JSON.encode!(%{
          "profile" => @profile,
          "scope" => "explicit_single_effect_runtime",
          "source_document" => source,
          "resources" => resources,
          "invariant" => invariant,
          "proposal_basis" => encode_basis(basis),
          "mandatory_guards" => @guards,
          "physical_qualification" => "required_at_dispatch"
        })

      if byte_size(document) <= @max_bytes,
        do: {:ok, document},
        else: {:error, :invalid_admission_artifact}
    else
      _ -> {:error, :unsupported_admission_profile}
    end
  end

  def decode(document) when is_binary(document) and byte_size(document) <= @max_bytes do
    with {:ok,
          %{
            "profile" => @profile,
            "scope" => "explicit_single_effect_runtime",
            "source_document" => source,
            "resources" => resources,
            "invariant" => invariant,
            "proposal_basis" => encoded_basis,
            "mandatory_guards" => @guards,
            "physical_qualification" => "required_at_dispatch"
          } = data} <- JSON.decode(document),
         true <- map_size(data) == 8 and JSON.encode!(data) == document,
         {:ok, [rule]} <- Codec.decode(source),
         true <- rule.ownership_ms == 1 and rule.cooldown_ms == 0 and rule.causal_budget == 1,
         {:ok, things} <- CandidateArtifact.things(resources),
         [{target, thing}] <- Map.to_list(things),
         true <- elem(rule.effect, 0) == target and DirectPowerSafety.decision(thing) == :allow,
         :ok <- invariant_pin(invariant, target),
         {:ok, basis} <- decode_basis(encoded_basis),
         {:ok, program} <- Compiler.compile([rule]),
         true <-
           basis.target_id == target and basis.source_digest == program.source_digest and
             basis.ir_digest == program.ir_digest and basis.compiler_profile == program.profile do
      {:ok,
       %{
         document: data,
         source: source,
         rule: rule,
         resources: resources,
         things: things,
         invariant: invariant,
         proposal_basis: basis
       }}
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  def decode(_document), do: {:error, :corrupt_rule_admission}

  def current(document) do
    with {:ok, artifact} <- decode(document),
         {:ok, current} <- build(artifact.source, artifact.resources, artifact.invariant),
         true <- current == document do
      {:ok, artifact}
    else
      false -> {:error, :stale_rule_admission}
      error -> error
    end
  end

  def digest(document), do: CandidateArtifact.digest(document)

  defp invariant_pin(
         %{"target_id" => target, "revision" => revision, "digest" => hash} = pin,
         target
       )
       when map_size(pin) == 3 and is_integer(revision) and revision >= 0 and
              revision <= 9_223_372_036_854_775_807 do
    if (revision == 0 and hash == nil) or (revision > 0 and is_binary(hash) and hash =~ @hex64),
      do: :ok,
      else: :error
  end

  defp invariant_pin(_pin, _target), do: :error

  defp encode_basis(basis) do
    Map.new(basis, fn {key, value} ->
      value =
        cond do
          is_atom(value) -> Atom.to_string(value)
          is_list(value) -> Enum.map(value, &Atom.to_string/1)
          true -> value
        end

      {Atom.to_string(key), value}
    end)
  end

  # Conversion uses only keys/values from a fresh known receipt; no input atoms.
  defp decode_basis(encoded) when is_map(encoded) do
    obligations =
      ~w(closed_rule closed_source_bound_ir compiler_correspondence ordinary_light_power single_explicit_trigger literal_predicate one_writer no_feedback one_effect_per_root runtime_correspondence pure_gate_precedence blocked_root_preservation)a

    basis = %{
      result: :basis_complete,
      profile: encoded["profile"],
      target_id: encoded["target_id"],
      obligations: obligations,
      rule_digest: encoded["rule_digest"],
      registry_digest: encoded["registry_digest"],
      compiler_profile: encoded["compiler_profile"],
      source_digest: encoded["source_digest"],
      ir_digest: encoded["ir_digest"],
      runtime_digest: encoded["runtime_digest"],
      scope: :proposal_generation_only,
      basis_digest: encoded["basis_digest"]
    }

    if RestrictedBasis.valid?(basis) and encode_basis(basis) == encoded,
      do: {:ok, basis},
      else: :error
  end

  defp decode_basis(_encoded), do: :error
end
