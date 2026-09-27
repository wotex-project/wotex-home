defmodule WotexHome.Qualification.Decision do
  @moduledoc """
  Verify a physical reviewer's signed, exact direct-power qualification claim.

  This binds the current mapping basis and nine separately signed case receipts.
  The signer is responsible for inspecting the cited private artifacts and
  physical outcome. Verification does not itself open those artifacts or grant
  Store authority; the reviewer's public key must be pinned by the host.

  `package_bytes/4` creates canonical signed-claim input for custody, and
  `verify/6` checks the case set, current basis and trusted signatures before
  returning a decision. Repeat verification after any profile, registry,
  runtime or cohort change; the old decision cannot silently carry forward.
  """

  alias WotexHome.Id
  alias WotexHome.Lifx.ProfileBasis
  alias WotexHome.Qualification.{Attestation, Evidence, Programme}

  @schema "wotex-home.lifx-power-decision.v1"
  @scope "lifx_direct_power_v1"
  @fields ~w(schema scope outcome thing_id profile_ref resource_revision identity_digest basis_digest registry_digest runtime_digest programme_digest cohort_digest evidence_set_digest reviewer_key_id)
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @max_i64 9_223_372_036_854_775_807
  @max_package_bytes 262_144

  @doc "Deterministic, bounded sanitized claims retained beside the Store."
  def package_bytes(signed, basis, cohort, attestations) do
    bytes =
      :erlang.term_to_binary(
        %{signed: signed, basis: basis, cohort: cohort, attestations: attestations},
        [:deterministic]
      )

    if byte_size(bytes) <= @max_package_bytes,
      do: {:ok, bytes},
      else: {:error, :invalid_qualification_decision}
  rescue
    _ -> {:error, :invalid_qualification_decision}
  end

  @doc "Domain-separated bytes for a reviewer signing a closed decision map."
  @spec signing_payload(map()) :: {:ok, binary()} | {:error, atom()}
  def signing_payload(decision) when is_map(decision) do
    if valid_decision?(decision) do
      {:ok,
       "WOH11-lifx-power-decision-v1\0" <> :erlang.term_to_binary(decision, [:deterministic])}
    else
      {:error, :invalid_qualification_decision}
    end
  end

  def signing_payload(_), do: {:error, :invalid_qualification_decision}

  @doc "Verify signed physical review and every direct-power case claim."
  @spec verify(map(), map(), map(), [map()], map(), map()) ::
          {:ok, map()} | {:error, atom()}
  def verify(signed, basis, cohort, attestations, case_keys, decision_keys)
      when is_map(signed) and is_map(basis) and is_list(attestations) and
             length(attestations) <= 32 and is_map(case_keys) and map_size(case_keys) <= 32 and
             is_map(decision_keys) and map_size(decision_keys) <= 32 do
    with true <- exact_keys?(signed, ~w(decision signature)),
         decision <- signed["decision"],
         {:ok, payload} <- signing_payload(decision),
         true <- ProfileBasis.valid?(basis),
         {:ok, current_runtime_digest} <- ProfileBasis.runtime_digest(),
         true <- basis.runtime_digest == current_runtime_digest,
         {:ok, cases, programme_digest} <- Programme.lifx_power_cases(),
         {:ok, cohort_digest} <- Evidence.cohort_digest(cohort),
         {:ok, receipts} <- verify_cases(attestations, programme_digest, case_keys),
         true <- length(receipts) == length(cases),
         {:ok, summary} <- Evidence.summarize(cases, receipts, cohort),
         true <- Enum.all?(summary, &(&1["status"] == "passed")),
         true <- decision_matches?(decision, basis, programme_digest, cohort_digest, attestations),
         true <- Enum.all?(receipts, &(&1["reviewer_ref"] != decision["reviewer_key_id"])),
         key when is_binary(key) and byte_size(key) == 32 <-
           Map.get(decision_keys, decision["reviewer_key_id"]),
         {:ok, signature} <- decode_signature(signed["signature"]),
         true <- verify_signature(payload, signature, key),
         {:ok, package_bytes} <- package_bytes(signed, basis, cohort, attestations) do
      decision_digest = digest(signed)
      package_digest = :crypto.hash(:sha256, package_bytes) |> Base.encode16(case: :lower)

      {:ok,
       %{
         evidence_ref: "qualification:" <> package_digest,
         package_bytes: package_bytes,
         decision_digest: decision_digest,
         thing_id: decision["thing_id"],
         profile_ref: decision["profile_ref"],
         resource_revision: decision["resource_revision"],
         identity_digest: decision["identity_digest"],
         basis_digest: decision["basis_digest"],
         declaration_digest: basis.declaration_digest,
         registry_digest: decision["registry_digest"],
         runtime_digest: decision["runtime_digest"]
       }}
    else
      _ -> {:error, :invalid_qualification_decision}
    end
  end

  def verify(_, _, _, _, _, _), do: {:error, :invalid_qualification_decision}

  defp verify_cases(attestations, programme_digest, keys) do
    Enum.reduce_while(attestations, {:ok, []}, fn attestation, {:ok, receipts} ->
      case Attestation.verify(attestation, programme_digest, keys) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        _ -> {:halt, {:error, :invalid_qualification_decision}}
      end
    end)
    |> case do
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      error -> error
    end
  end

  defp decision_matches?(decision, basis, programme_digest, cohort_digest, attestations) do
    decision["thing_id"] == basis.thing_id and
      decision["profile_ref"] == basis.profile_ref and
      decision["identity_digest"] == basis.identity_digest and
      decision["basis_digest"] == basis.basis_digest and
      decision["registry_digest"] == basis.registry_digest and
      decision["runtime_digest"] == basis.runtime_digest and
      decision["programme_digest"] == programme_digest and
      decision["cohort_digest"] == cohort_digest and
      decision["evidence_set_digest"] == evidence_set_digest(attestations)
  end

  @doc "Order-independent digest of the exact signed case set."
  @spec evidence_set_digest([map()]) :: String.t()
  def evidence_set_digest(attestations) do
    attestations
    |> Enum.sort_by(&get_in(&1, ["receipt", "case_id"]))
    |> digest()
  end

  defp valid_decision?(decision) do
    exact_keys?(decision, @fields) and decision["schema"] == @schema and
      decision["scope"] == @scope and decision["outcome"] == "allow_direct_power" and
      Id.valid?(decision["thing_id"]) and Id.valid?(decision["profile_ref"]) and
      Id.valid?(decision["reviewer_key_id"]) and
      is_integer(decision["resource_revision"]) and
      decision["resource_revision"] in 0..@max_i64 and
      Enum.all?(
        ~w(identity_digest basis_digest registry_digest runtime_digest programme_digest cohort_digest evidence_set_digest),
        &(is_binary(decision[&1]) and decision[&1] =~ @hex64)
      )
  end

  defp decode_signature(encoded) when is_binary(encoded) and byte_size(encoded) == 86 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, signature} when byte_size(signature) == 64 ->
        if Base.url_encode64(signature, padding: false) == encoded,
          do: {:ok, signature},
          else: {:error, :invalid_qualification_decision}

      _ ->
        {:error, :invalid_qualification_decision}
    end
  end

  defp decode_signature(_), do: {:error, :invalid_qualification_decision}

  defp verify_signature(payload, signature, public_key) do
    :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
