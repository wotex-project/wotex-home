defmodule WotexHome.Durable.Store.CandidateWriter do
  @moduledoc """
  Candidate-history operations called synchronously by the single Store owner.

  The checker runs in Authority outside SQLite transactions. Commit compares
  its immutable artifact with the exact current scoped declarations and expected
  revision. This module owns no connection, process, checker or device session.
  All retained outcomes are rejected/pending; none can authorize execution.
  """

  alias WotexHome.Durable.Store.{Journal, ReviewReadModel}
  alias WotexHome.Id
  alias WotexHome.Rules.{CandidateArtifact, Codec}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807
  @capacity 1_024

  def prepare(db, credential, epoch, operation_id, expected, rules_document) do
    with :ok <- valid_input(epoch, operation_id, expected, rules_document),
         {:ok, principal_id} <- ReviewReadModel.principal(db, credential),
         {:ok, rows} <- select(db, principal_id, epoch, operation_id) do
      case rows do
        [row] ->
          with :ok <- same_content(row, expected, rules_document),
               {:ok, receipt} <- receipt(row, principal_id, epoch, operation_id) do
            {:ok, :existing, receipt}
          end

        [] ->
          with :ok <- capacity(db),
               {:ok, things, resources} <- current_basis(db, credential, epoch, expected) do
            {:ok, :new, things, resources}
          end

        _ ->
          {:error, :corrupt_rule_review}
      end
    end
  end

  def commit(db, credential, epoch, operation_id, expected, rules_document, artifact_document) do
    result =
      with :ok <- valid_input(epoch, operation_id, expected, rules_document),
           {:ok, principal_id} <- ReviewReadModel.principal(db, credential),
           {:ok, rows} <- select(db, principal_id, epoch, operation_id) do
        case rows do
          [row] ->
            with :ok <- same_content(row, expected, rules_document),
                 {:ok, receipt} <- receipt(row, principal_id, epoch, operation_id) do
              {:rollback, {:unchanged, {:ok, receipt}}}
            end

          [] ->
            with :ok <- capacity(db),
                 {:ok, _things, resources} <- current_basis(db, credential, epoch, expected),
                 {:ok, artifact} <- CandidateArtifact.decode(artifact_document),
                 true <-
                   artifact.rules_document == rules_document and artifact.resources == resources,
                 {:ok, revision} <- Journal.next_revision(db),
                 digest = CandidateArtifact.digest(artifact_document),
                 {:ok, []} <-
                   query(
                     db,
                     "INSERT INTO rule_candidate_reviews VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                     [
                       principal_id,
                       epoch,
                       operation_id,
                       expected,
                       rules_document,
                       artifact_document,
                       digest,
                       revision
                     ]
                   ),
                 :ok <-
                   Journal.authority_event(db, revision, "rule_candidate_reviewed", operation_id),
                 {:ok, receipt} <-
                   receipt(
                     [expected, rules_document, artifact_document, digest, revision],
                     principal_id,
                     epoch,
                     operation_id
                   ) do
              {:commit, {:ok, receipt}}
            else
              false -> {:error, :review_basis_changed}
              error -> error
            end

          _ ->
            {:error, :corrupt_rule_review}
        end
      end

    case result do
      {:error, reason}
      when reason in [:corrupt_rule_review, :corrupt_enrollment, :corrupt_principal] ->
        {:rollback, reason}

      {:error, reason}
      when reason in [
             :invalid_rule_review_operation,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :stale_authority_epoch,
             :resnapshot_required,
             :review_scope_unavailable,
             :review_basis_changed,
             :rule_review_capacity,
             :rule_review_operation_conflict
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      other ->
        other
    end
  end

  def status(db, credential, epoch, operation_id) do
    with true <- valid_identity?(epoch, operation_id),
         {:ok, principal_id} <- ReviewReadModel.principal(db, credential),
         {:ok, rows} <- select(db, principal_id, epoch, operation_id) do
      case rows do
        [row] -> receipt(row, principal_id, epoch, operation_id)
        [] -> {:error, :rule_review_not_found}
        _ -> {:error, :corrupt_rule_review}
      end
    else
      false -> {:error, :invalid_rule_review_operation}
      error -> error
    end
  end

  defp valid_input(epoch, operation_id, expected, document) do
    with true <- valid_identity?(epoch, operation_id) and integer?(expected),
         {:ok, _rules} <- Codec.decode(document) do
      :ok
    else
      _ -> {:error, :invalid_rule_review_operation}
    end
  end

  defp current_basis(db, credential, epoch, expected) do
    with {:ok, [[current_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key='authority_epoch'"),
         true <- epoch == current_epoch,
         {:ok, things, resources, revision} <- ReviewReadModel.basis(db, credential),
         :ok <- matching_revision(expected, revision) do
      {:ok, things, resources}
    else
      false -> {:error, :stale_authority_epoch}
      {:error, _} = error -> error
      _ -> {:error, :store_unavailable}
    end
  end

  defp select(db, principal, epoch, operation) do
    query(
      db,
      "SELECT expected_revision, rules_document, artifact_document, artifact_digest, revision FROM rule_candidate_reviews WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
      [principal, epoch, operation]
    )
  end

  defp same_content([expected, document, _, _, _], expected, document), do: :ok

  defp same_content([_, _, _, _, _], _expected, _document),
    do: {:error, :rule_review_operation_conflict}

  defp same_content(_row, _expected, _document), do: {:error, :corrupt_rule_review}

  defp receipt([expected, rules, document, digest, revision], principal, epoch, operation) do
    with true <- integer?(expected) and integer?(revision) and revision == expected + 1,
         true <- is_binary(document) and CandidateArtifact.digest(document) == digest,
         {:ok, artifact} <- CandidateArtifact.decode(document),
         true <-
           artifact.rules_document == rules and
             Enum.all?(artifact.resources, &(&1["resource_revision"] <= expected)) do
      {:ok,
       %{
         principal_id: principal,
         authority_epoch: epoch,
         operation_id: operation,
         expected_revision: expected,
         revision: revision,
         artifact_digest: digest,
         decision: artifact.review["decision"],
         reason: artifact.review["reason"],
         profile: artifact.review["profile"],
         rule_digest: artifact.review["rule_digest"],
         registry_digest: artifact.review["registry_digest"],
         checker_receipt_digest: artifact.review["checker_receipt_digest"],
         proposal_basis_digest: artifact.review["proposal_basis_digest"]
       }}
    else
      _ -> {:error, :corrupt_rule_review}
    end
  end

  defp receipt(_row, _principal, _epoch, _operation), do: {:error, :corrupt_rule_review}

  defp capacity(db) do
    case query(db, "SELECT COUNT(*) FROM rule_candidate_reviews") do
      {:ok, [[count]]} when is_integer(count) and count >= 0 and count < @capacity -> :ok
      {:ok, [[@capacity]]} -> {:error, :rule_review_capacity}
      {:ok, _} -> {:error, :corrupt_rule_review}
      error -> error
    end
  end

  defp matching_revision(revision, revision), do: :ok
  defp matching_revision(_expected, _revision), do: {:error, :resnapshot_required}

  defp valid_identity?(epoch, operation),
    do: integer?(epoch) and epoch >= 1 and Id.valid?(operation)

  defp integer?(value), do: is_integer(value) and value >= 0 and value <= @max_i64
end
