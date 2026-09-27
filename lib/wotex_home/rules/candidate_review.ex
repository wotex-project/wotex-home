defmodule WotexHome.Rules.CandidateReview do
  @moduledoc """
  Immutable, credential-free screening result for a closed draft rule set.

  This combines structural checks with the narrow negative ex_maude screen.
  Every non-rejected result remains pending positive qualification. A review
  has no Store, active pointer, scheduler, outbox or device handle.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Rules.{Analyzer, RestrictedBasis, Rule}
  alias WotexHome.Semantics.Thing
  alias WotexHome.Verification.LegacyConflict

  @profile "home-draft-review-v1"
  @composed_reasons [
    :multiple_writers,
    :feedback_not_supported,
    :proof_required_or_unsupported_input
  ]

  @type decision :: :rejected | :pending_positive_basis | :pending_composed_proof
  @type result :: %{
          decision: decision(),
          reason: atom(),
          profile: String.t(),
          rule_digest: String.t(),
          registry_digest: String.t(),
          checker_receipt: ExMaude.Verification.Receipt.t() | nil,
          proposal_basis: map() | nil
        }

  @spec review([Rule.t()], %{String.t() => Thing.t()}) :: {:ok, result()} | {:error, atom()}
  def review(rules, things)
      when is_list(rules) and length(rules) > 0 and length(rules) <= 64 and is_map(things) and
             map_size(things) > 0 and map_size(things) <= 128 do
    with true <- Enum.all?(rules, &Rule.valid?/1),
         {:ok, registry_digest} <- registry_digest(things) do
      rule_digest = digest({@profile, rules})
      decide(rules, things, rule_digest, registry_digest)
    else
      false -> {:error, :invalid_rule_set}
      {:error, reason} -> {:error, reason}
    end
  end

  def review(_rules, _things), do: {:error, :invalid_rule_set}

  defp decide(rules, things, rule_digest, registry_digest) do
    case Analyzer.restricted(rules, things) do
      {:ok, :structurally_restricted} ->
        negative_screen(
          rules,
          rule_digest,
          registry_digest,
          :pending_positive_basis,
          :positive_basis_missing
        )
        |> maybe_proposal_basis(rules, things)

      {:error, reason} when reason in @composed_reasons ->
        negative_screen(rules, rule_digest, registry_digest, :pending_composed_proof, reason)

      {:error, reason} ->
        {:ok, result(:rejected, reason, rule_digest, registry_digest, nil)}
    end
  end

  defp maybe_proposal_basis({:ok, %{decision: :pending_positive_basis} = review}, [rule], things) do
    {target_id, _key, _value} = rule.effect

    case Map.fetch(things, target_id) do
      {:ok, thing} ->
        case RestrictedBasis.qualify([rule], %{target_id => thing}) do
          {:ok, basis} -> {:ok, %{review | proposal_basis: basis}}
          {:error, _reason} -> {:ok, review}
        end

      :error ->
        {:ok, review}
    end
  end

  defp maybe_proposal_basis(result, _rules, _things), do: result

  defp negative_screen(rules, rule_digest, registry_digest, pending_decision, pending_reason) do
    case LegacyConflict.translate_rules(rules) do
      {:ok, _translated} ->
        case LegacyConflict.screen(rules) do
          {:ok, %{decision: :rejected, reason: reason, checker_receipt: receipt}} ->
            {:ok, result(:rejected, reason, rule_digest, registry_digest, receipt)}

          {:ok, %{reason: reason, checker_receipt: receipt}} ->
            pending_reason =
              if pending_decision == :pending_positive_basis, do: reason, else: pending_reason

            {:ok, result(pending_decision, pending_reason, rule_digest, registry_digest, receipt)}

          {:error, _reason} ->
            {:ok, result(pending_decision, pending_reason, rule_digest, registry_digest, nil)}
        end

      {:error, :unsupported_model_semantics} ->
        reason =
          if pending_decision == :pending_positive_basis,
            do: :legacy_model_unsupported,
            else: pending_reason

        {:ok, result(pending_decision, reason, rule_digest, registry_digest, nil)}

      {:error, reason} ->
        {:ok, result(:rejected, reason, rule_digest, registry_digest, nil)}
    end
  end

  defp result(decision, reason, rule_digest, registry_digest, receipt) do
    %{
      decision: decision,
      reason: reason,
      profile: @profile,
      rule_digest: rule_digest,
      registry_digest: registry_digest,
      checker_receipt: receipt,
      proposal_basis: nil
    }
  end

  defp registry_digest(things) do
    things
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {id, thing}, {:ok, documents} ->
      if is_binary(id) and match?(%Thing{id: ^id}, thing) do
        case Registry.encode_thing(thing) do
          {:ok, document} -> {:cont, {:ok, [{id, document} | documents]}}
          _ -> {:halt, {:error, :invalid_registry}}
        end
      else
        {:halt, {:error, :invalid_registry}}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, digest(Enum.reverse(documents))}
      error -> error
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
