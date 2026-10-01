defmodule WotexHome.Durable.Store.EnrollmentWriter do
  @moduledoc """
  Enrollment identity and declaration transactions for the single Store writer.

  The Store validates public inputs and owns the surrounding transaction. This
  module binds reviewed identities, preserves immutable review history, narrows
  declarations and revokes Things with current-report and request invalidation
  in the same transaction. It retains no database or process state.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, Journal, OverrideWriter, RequestInvalidator}
  alias WotexHome.Semantics.Thing

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  import Journal, only: [authority_event: 4, next_revision: 1]
  import Access, only: [authenticate: 2, enrolled_thing: 2]
  import OverrideWriter, only: [clear_override_for_target: 2]

  import RequestInvalidator,
    only: [held_for_thing: 2, invalidate_execution_for: 3, reject_held_batch: 3]

  @max_i64 9_223_372_036_854_775_807

  @spec enroll_thing_tx(term(), Thing.t(), String.t()) :: tuple()
  def enroll_thing_tx(db, thing, document) do
    case query(
           db,
           "SELECT document, resource_revision, status FROM enrolled_things WHERE thing_id = ?",
           [thing.id]
         ) do
      {:ok, []} ->
        with {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "INSERT INTO enrolled_things VALUES (?, ?, ?, 0, 'active')", [
                 thing.id,
                 thing.profile_ref,
                 document
               ]),
             :ok <- authority_event(db, revision, "thing_enrolled", thing.id) do
          {:commit, {:ok, revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, [[_document, _resource_revision, _status]]} ->
        {:rollback, {:policy, :enrollment_conflict}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  @spec commit_enrollment_tx(term(), binary(), map(), map(), Thing.t(), String.t()) :: tuple()
  def commit_enrollment_tx(db, hash, review, interview, thing, document) do
    with {:ok, operator_id, permissions} <- authenticate(db, hash),
         :ok <- review_permission(operator_id, permissions, review.operator_id),
         {:ok, prior} <-
           query(
             db,
             "SELECT h.thing_id, h.stable_id, h.identity_digest, h.candidate_ref, h.method, h.qualification_ref, h.operator_id, h.profile_ref, h.revision, h.manufacturer, h.model, h.firmware, b.review_ref, b.revision, b.digest_version, t.document, t.status, a.event_type FROM enrollment_review_history h LEFT JOIN enrollment_bindings b ON b.thing_id = h.thing_id LEFT JOIN enrolled_things t ON t.thing_id = h.thing_id LEFT JOIN authority_journal a ON a.revision = h.revision AND a.entity_id = h.thing_id WHERE h.review_ref = ?",
             [review.review_ref]
           ) do
      case prior do
        [] ->
          commit_new_enrollment_tx(db, operator_id, review, interview, thing, document)

        [row] ->
          current_enrollment_retry(
            row,
            review,
            interview,
            thing,
            document,
            "thing_enrolled_reviewed"
          )

        _ ->
          {:rollback, :corrupt_enrollment}
      end
    else
      {:error, reason} when reason in [:unauthorized, :corrupt_principal] ->
        {:rollback, {:policy, reason}}

      {:error, :permission_denied} ->
        {:rollback, {:policy, :permission_denied}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp current_enrollment_retry(
         [
           thing_id,
           stable_id,
           identity_digest,
           candidate_ref,
           method,
           qualification_ref,
           operator_id,
           profile_ref,
           revision,
           manufacturer,
           model,
           firmware,
           review_ref,
           binding_revision,
           digest_version,
           stored_document,
           status,
           event_type
         ],
         review,
         interview,
         thing,
         document,
         expected_event_type
       ) do
    if {thing_id, stable_id, identity_digest, candidate_ref, method, qualification_ref,
        operator_id, profile_ref, manufacturer, model, firmware, review_ref, binding_revision,
        digest_version, stored_document, status, event_type} ==
         {thing.id, review.stable_id, review.identity_digest, review.candidate_ref, review.method,
          review.qualification_ref, review.operator_id, review.profile_ref,
          interview.manufacturer, interview.model, interview.firmware, review.review_ref,
          revision, 2, document, "active", expected_event_type} and
         valid_stored_integer?(revision) and revision >= 1 do
      {:rollback, {:unchanged, {:ok, revision}}}
    else
      {:rollback, {:policy, :enrollment_conflict}}
    end
  end

  defp current_enrollment_retry(_row, _review, _interview, _thing, _document, _event_type),
    do: {:rollback, :corrupt_enrollment}

  @spec enrollment_review_status_result(term(), binary(), String.t()) :: tuple() | :not_found
  def enrollment_review_status_result(db, credential, review_ref) do
    with true <- Id.valid?(review_ref),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         :ok <- review_permission(principal_id, permissions, principal_id),
         {:ok, rows} <-
           query(
             db,
             "SELECT h.thing_id, h.revision, h.digest_version, b.review_ref, b.revision, t.status FROM enrollment_review_history h LEFT JOIN enrollment_bindings b ON b.thing_id = h.thing_id LEFT JOIN enrolled_things t ON t.thing_id = h.thing_id WHERE h.review_ref = ? AND h.operator_id = ?",
             [review_ref, principal_id]
           ) do
      case rows do
        [] ->
          :not_found

        [[thing_id, revision, digest_version, current_ref, binding_revision, thing_status]] ->
          cond do
            not Id.valid?(thing_id) or not valid_stored_integer?(revision) or revision < 1 or
              not valid_stored_integer?(binding_revision) or binding_revision < revision or
              digest_version not in [1, 2] or not Id.valid?(current_ref) or
                thing_status not in ["active", "revoked"] ->
              {:error, :corrupt_enrollment}

            true ->
              state =
                cond do
                  thing_status == "revoked" -> :revoked
                  current_ref == review_ref -> :current
                  true -> :superseded
                end

              {:ok,
               %{
                 review_ref: review_ref,
                 thing_id: thing_id,
                 review_revision: revision,
                 binding_revision: binding_revision,
                 digest_version: digest_version,
                 state: state
               }}
          end

        _ ->
          {:error, :corrupt_enrollment}
      end
    else
      false -> {:error, :invalid_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_new_enrollment_tx(db, operator_id, review, interview, thing, document) do
    with {:ok, []} <-
           query(
             db,
             "SELECT thing_id FROM enrollment_bindings WHERE stable_id = ? OR identity_digest = ? LIMIT 1",
             [review.stable_id, review.identity_digest]
           ),
         {:ok, []} <-
           query(
             db,
             "SELECT thing_id FROM enrollment_review_history WHERE review_ref = ? LIMIT 1",
             [review.review_ref]
           ),
         {:ok, []} <-
           query(db, "SELECT thing_id FROM enrolled_things WHERE thing_id = ?", [thing.id]),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "INSERT INTO enrolled_things VALUES (?, ?, ?, 0, 'active')", [
             thing.id,
             thing.profile_ref,
             document
           ]),
         {:ok, []} <-
           query(db, "INSERT INTO enrollment_bindings VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 2)", [
             thing.id,
             review.stable_id,
             review.identity_digest,
             review.candidate_ref,
             review.review_ref,
             review.method,
             review.qualification_ref,
             operator_id,
             review.profile_ref,
             revision
           ]),
         :ok <- insert_enrollment_review_history(db, revision, review, interview, operator_id),
         :ok <- authority_event(db, revision, "thing_enrolled_reviewed", thing.id) do
      {:commit, {:ok, revision}}
    else
      {:ok, _} ->
        {:rollback, {:policy, :enrollment_conflict}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  @spec rereview_enrollment_tx(term(), binary(), map(), map(), Thing.t(), String.t()) :: tuple()
  def rereview_enrollment_tx(db, hash, review, interview, thing, document) do
    with {:ok, operator_id, permissions} <- authenticate(db, hash),
         :ok <- review_permission(operator_id, permissions, review.operator_id),
         {:ok, ^thing, _resource_revision} <- enrolled_thing(db, thing.id),
         {:ok, [[stable_id, method, qualification_ref, ^operator_id, profile_ref]]} <-
           query(
             db,
             "SELECT stable_id, method, qualification_ref, operator_id, profile_ref FROM enrollment_bindings WHERE thing_id = ?",
             [thing.id]
           ),
         :ok <-
           review_binding_matches(
             {stable_id, method, qualification_ref, profile_ref},
             review
           ),
         {:ok, prior} <-
           query(
             db,
             "SELECT h.thing_id, h.stable_id, h.identity_digest, h.candidate_ref, h.method, h.qualification_ref, h.operator_id, h.profile_ref, h.revision, h.manufacturer, h.model, h.firmware, b.review_ref, b.revision, b.digest_version, t.document, t.status, a.event_type FROM enrollment_review_history h LEFT JOIN enrollment_bindings b ON b.thing_id = h.thing_id LEFT JOIN enrolled_things t ON t.thing_id = h.thing_id LEFT JOIN authority_journal a ON a.revision = h.revision AND a.entity_id = h.thing_id WHERE h.review_ref = ?",
             [
               review.review_ref
             ]
           ) do
      case prior do
        [] -> rereview_new_enrollment_tx(db, operator_id, review, interview, thing)
        [row] -> current_rereview_retry(row, review, interview, thing, document)
        _ -> {:rollback, :corrupt_enrollment}
      end
    else
      {:error, reason}
      when reason in [
             :unauthorized,
             :target_unavailable,
             :permission_denied,
             :review_binding_mismatch
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, {:policy, :review_binding_mismatch}}
    end
  end

  defp current_rereview_retry(row, review, interview, thing, document) do
    case current_enrollment_retry(
           row,
           review,
           interview,
           thing,
           document,
           "thing_enrollment_rereviewed"
         ) do
      {:rollback, {:unchanged, {:ok, revision}}} ->
        {:rollback, {:unchanged, {:ok, revision}}}

      {:rollback, {:policy, :enrollment_conflict}} ->
        {:rollback, {:policy, :review_conflict}}

      other ->
        other
    end
  end

  defp rereview_new_enrollment_tx(db, operator_id, review, interview, thing) do
    with :ok <- review_capacity(db, thing.id),
         {:ok, held} <- held_for_thing(db, thing.id),
         {:ok, revision} <- next_revision(db),
         :ok <- insert_enrollment_review_history(db, revision, review, interview, operator_id),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrollment_bindings SET identity_digest = ?, digest_version = 2, candidate_ref = ?, review_ref = ?, revision = ? WHERE thing_id = ?",
             [review.identity_digest, review.candidate_ref, review.review_ref, revision, thing.id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing.id]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id = ?", [thing.id]),
         {:ok, []} <-
           query(db, "UPDATE profile_qualifications SET status = 'revoked' WHERE thing_id = ?", [
             thing.id
           ]),
         :ok <- authority_event(db, revision, "thing_enrollment_rereviewed", thing.id),
         {:ok, _held_revision} <- reject_held_batch(db, held, "identity_rechecked"),
         {:ok, _final_revision} <-
           invalidate_execution_for(db, {:thing, thing.id}, "identity_rechecked") do
      {:commit, {:ok, revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :review_binding_unavailable}}

      {:ok, _rows} ->
        {:rollback, {:policy, :review_conflict}}

      {:error, reason}
      when reason in [
             :unauthorized,
             :target_unavailable,
             :permission_denied,
             :review_binding_mismatch,
             :review_capacity
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, {:policy, :review_binding_mismatch}}
    end
  end

  defp review_permission(operator_id, permissions, selected_operator) do
    if operator_id == selected_operator and "enroll:review" in permissions,
      do: :ok,
      else: {:error, :permission_denied}
  end

  defp review_binding_matches({stable_id, method, qualification_ref, profile_ref}, review) do
    if {stable_id, method, qualification_ref, profile_ref} ==
         {review.stable_id, review.method, review.qualification_ref, review.profile_ref},
       do: :ok,
       else: {:error, :review_binding_mismatch}
  end

  defp review_capacity(db, thing_id) do
    case query(db, "SELECT COUNT(*) FROM enrollment_review_history WHERE thing_id = ?", [thing_id]) do
      {:ok, [[count]]} when is_integer(count) and count < 32 -> :ok
      {:ok, [[_count]]} -> {:error, :review_capacity}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp insert_enrollment_review_history(db, revision, review, interview, operator_id) do
    case query(
           db,
           "INSERT INTO enrollment_review_history VALUES (?, ?, ?, ?, 2, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
           [
             revision,
             review.thing_id,
             review.stable_id,
             review.identity_digest,
             review.candidate_ref,
             review.review_ref,
             review.method,
             review.qualification_ref,
             operator_id,
             review.profile_ref,
             interview.manufacturer,
             interview.model,
             interview.firmware
           ]
         ) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec narrow_thing_tx(term(), Thing.t(), String.t(), non_neg_integer()) :: tuple()
  def narrow_thing_tx(db, thing, document, expected_revision) do
    with {:ok, current, ^expected_revision} <- enrolled_thing(db, thing.id),
         true <- narrower_declaration?(current, thing),
         false <- current == thing,
         {:ok, held} <- held_for_thing(db, thing.id),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_target(db, thing.id),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing.id]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id = ?", [thing.id]),
         {:ok, []} <-
           query(db, "UPDATE profile_qualifications SET status = 'revoked' WHERE thing_id = ?", [
             thing.id
           ]),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrolled_things SET document = ?, resource_revision = ? WHERE thing_id = ? AND resource_revision = ? AND status = 'active'",
             [document, expected_revision + 1, thing.id, expected_revision]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "thing_narrowed", thing.id),
         {:ok, _held_revision} <- reject_held_batch(db, held, "declaration_changed"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, {:thing, thing.id}, "declaration_changed") do
      {:commit, {:ok, final_revision}}
    else
      {:ok, _current, _revision} -> {:rollback, {:policy, :stale_resource_revision}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      false -> {:rollback, {:policy, :declaration_widening}}
      true -> {:rollback, {:policy, :unchanged_declaration}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_enrollment}
    end
  end

  defp narrower_declaration?(current, next) do
    current.id == next.id and current.role == next.role and
      current.profile_ref == next.profile_ref and
      MapSet.new(Map.keys(current.capabilities)) == MapSet.new(Map.keys(next.capabilities)) and
      Enum.all?(current.capabilities, fn {key, old} ->
        new = Map.fetch!(next.capabilities, key)

        old.thing_id == new.thing_id and old.role == new.role and old.key == new.key and
          old.value_kind == new.value_kind and old.unit == new.unit and
          old.risk_class == new.risk_class and old.profile_ref == new.profile_ref and
          old.extensions == new.extensions and new.freshness_ms <= old.freshness_ms and
          Enum.all?(new.operations, &(&1 in old.operations)) and
          narrower_constraints?(old.constraints, new.constraints)
      end)
  end

  defp narrower_constraints?(
         %{"min" => old_min, "max" => old_max},
         %{"min" => new_min, "max" => new_max}
       ),
       do: new_min >= old_min and new_max <= old_max

  defp narrower_constraints?(old, new), do: old == new

  @spec revoke_thing_tx(term(), String.t()) :: tuple()
  def revoke_thing_tx(db, thing_id) do
    case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [thing_id]) do
      {:ok, [["active"]]} ->
        with {:ok, held} <- held_for_thing(db, thing_id),
             {:ok, revision} <- next_revision(db),
             :ok <- clear_override_for_target(db, thing_id),
             {:ok, []} <-
               query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing_id]),
             {:ok, []} <-
               query(
                 db,
                 "UPDATE profile_qualifications SET status = 'revoked' WHERE thing_id = ?",
                 [
                   thing_id
                 ]
               ),
             {:ok, []} <-
               query(db, "UPDATE enrolled_things SET status = 'revoked' WHERE thing_id = ?", [
                 thing_id
               ]),
             :ok <- authority_event(db, revision, "thing_revoked", thing_id),
             {:ok, _held_revision} <- reject_held_batch(db, held, "target_revoked"),
             {:ok, final_revision} <-
               invalidate_execution_for(db, {:thing, thing_id}, "target_revoked") do
          {:commit, {:ok, final_revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :target_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64
end
