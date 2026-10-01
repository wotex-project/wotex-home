defmodule WotexHome.Rules.CandidateArtifact do
  @moduledoc """
  Immutable draft-review content, deliberately not an admitted rule artifact.

  Retains exact canonical rule data, declaration/resource snapshots and a closed
  rejected/pending summary. Native receipt and proposal-basis digests commit to
  the checked attempt but do not retain proof packages or grant runtime authority.
  Historical decoding never invokes a verifier or trusts today's runtime as the
  runtime that produced an earlier result.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.Rules.{CandidateReview, Codec, RestrictedBasis}
  alias WotexHome.Semantics.Thing

  @max_bytes 4_194_304
  @max_i64 9_223_372_036_854_775_807
  @summary_keys ~w(decision reason profile rule_digest registry_digest checker_receipt_digest proposal_basis_digest)
  @rejected ~w(duplicate_rule_id unknown_thing unsupported_effect invalid_registry incompatible_predicate invalid_rule_set state_conflict)
  @positive ~w(positive_basis_missing no_matching_conflict checker_unavailable_or_failed checker_incomplete_or_untrusted legacy_model_unsupported)
  @composed ~w(multiple_writers feedback_not_supported proof_required_or_unsupported_input)

  def build(rules, resources, review) do
    with {:ok, rules_document} <- Codec.encode(rules),
         {:ok, things} <- things(resources),
         {:ok, bindings} <- CandidateReview.bindings(rules, things),
         {:ok, summary} <- summary(review),
         true <- bound?(summary, bindings),
         {:ok, document} <- encode(rules_document, resources, summary) do
      {:ok, document}
    else
      _ -> {:error, :invalid_candidate_artifact}
    end
  end

  def decode(document) when is_binary(document) and byte_size(document) <= @max_bytes do
    with {:ok,
          %{
            "version" => 1,
            "rules_document" => rules_document,
            "resources" => resources,
            "review" => review
          } = input} <- JSON.decode(document),
         true <- map_size(input) == 4,
         {:ok, rules} <- Codec.decode(rules_document),
         {:ok, things} <- things(resources),
         {:ok, bindings} <- CandidateReview.bindings(rules, things),
         true <- valid_summary?(review) and bound?(review, bindings),
         {:ok, ^document} <- encode(rules_document, resources, review) do
      {:ok, %{rules_document: rules_document, resources: resources, review: review}}
    else
      _ -> {:error, :corrupt_rule_review}
    end
  end

  def decode(_document), do: {:error, :corrupt_rule_review}

  def digest(document) when is_binary(document),
    do: Base.encode16(:crypto.hash(:sha256, document), case: :lower)

  def things(resources) when is_list(resources) and length(resources) in 1..32 do
    Enum.reduce_while(resources, {:ok, %{}, ""}, fn
      %{"thing_id" => id, "resource_revision" => revision, "document" => document} = row,
      {:ok, things, previous}
      when map_size(row) == 3 ->
        with true <- Id.valid?(id) and id > previous and integer?(revision),
             {:ok, %Thing{id: ^id} = thing} <- Registry.decode_thing(document) do
          {:cont, {:ok, Map.put(things, id, thing), id}}
        else
          _ -> {:halt, {:error, :invalid_candidate_resources}}
        end

      _, _ ->
        {:halt, {:error, :invalid_candidate_resources}}
    end)
    |> case do
      {:ok, things, _} -> {:ok, things}
      error -> error
    end
  end

  def things(_resources), do: {:error, :invalid_candidate_resources}

  defp summary(
         %{
           decision: decision,
           reason: reason,
           profile: profile,
           rule_digest: rules,
           registry_digest: registry,
           checker_receipt: checker,
           proposal_basis: proposal
         } = review
       )
       when map_size(review) == 7 and is_atom(decision) and is_atom(reason) do
    with {:ok, checker_digest} <- checker_digest(checker),
         {:ok, proposal_digest} <- proposal_digest(proposal) do
      summary = %{
        "decision" => Atom.to_string(decision),
        "reason" => Atom.to_string(reason),
        "profile" => profile,
        "rule_digest" => rules,
        "registry_digest" => registry,
        "checker_receipt_digest" => checker_digest,
        "proposal_basis_digest" => proposal_digest
      }

      if valid_summary?(summary), do: {:ok, summary}, else: {:error, :invalid_review_summary}
    end
  end

  defp summary(_review), do: {:error, :invalid_review_summary}

  defp checker_digest(nil), do: {:ok, nil}
  defp checker_digest(%ExMaude.Verification.Receipt{} = receipt), do: bounded_term_digest(receipt)
  defp checker_digest(_receipt), do: {:error, :invalid_checker_receipt}

  defp proposal_digest(nil), do: {:ok, nil}

  defp proposal_digest(%{} = proposal) do
    if RestrictedBasis.valid?(proposal),
      do: bounded_term_digest(proposal),
      else: {:error, :invalid_proposal_basis}
  end

  defp proposal_digest(_proposal), do: {:error, :invalid_proposal_basis}

  defp bounded_term_digest(term) do
    bytes = :erlang.term_to_binary(term, [:deterministic])
    if byte_size(bytes) <= 2_097_152, do: {:ok, digest(bytes)}, else: {:error, :review_too_large}
  end

  defp encode(rules_document, resources, review) do
    document =
      JSON.encode!(%{
        "version" => 1,
        "rules_document" => rules_document,
        "resources" => resources,
        "review" => review
      })

    if byte_size(document) <= @max_bytes,
      do: {:ok, document},
      else: {:error, :candidate_too_large}
  end

  defp valid_summary?(summary) when is_map(summary) do
    Enum.sort(Map.keys(summary)) == Enum.sort(@summary_keys) and
      summary["profile"] == "home-draft-review-v1" and
      hash?(summary["rule_digest"]) and hash?(summary["registry_digest"]) and
      optional_hash?(summary["checker_receipt_digest"]) and
      optional_hash?(summary["proposal_basis_digest"]) and
      valid_decision?(summary["decision"], summary["reason"]) and
      (is_nil(summary["proposal_basis_digest"]) or summary["decision"] == "pending_positive_basis")
  end

  defp valid_summary?(_summary), do: false

  defp valid_decision?("rejected", reason), do: reason in @rejected
  defp valid_decision?("pending_positive_basis", reason), do: reason in @positive
  defp valid_decision?("pending_composed_proof", reason), do: reason in @composed
  defp valid_decision?(_decision, _reason), do: false

  defp bound?(summary, bindings),
    do:
      summary["profile"] == bindings.profile and summary["rule_digest"] == bindings.rule_digest and
        summary["registry_digest"] == bindings.registry_digest

  defp integer?(n), do: is_integer(n) and n >= 0 and n <= @max_i64
  defp optional_hash?(nil), do: true
  defp optional_hash?(value), do: hash?(value)

  defp hash?(value),
    do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/
end
