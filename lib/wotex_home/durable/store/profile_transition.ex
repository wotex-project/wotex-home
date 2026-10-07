defmodule WotexHome.Durable.Store.ProfileTransition do
  @moduledoc "Atomic profile-selection barriers on the borrowed Store transaction."
  alias WotexHome.Durable.Registry

  alias WotexHome.Durable.Store.{
    Journal,
    OverrideWriter,
    ProfileSelectionHistory,
    ProfileWriter,
    QualificationHistory,
    RequestInvalidator
  }

  alias WotexHome.Profiles.{Artifact, LedgerCodec, Operation, Review}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @artifact_fields ~w(artifact_digest id version metadata_document projection_document projection_digest binding registry_digest first_approval_revision)
  @operation_fields ~w(principal_id authority_epoch operation_id action input_document input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)
  @receipt_fields ~w(authority_epoch operation_id action input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)a
  @max_i64 9_223_372_036_854_775_807
  @denials ~w(unauthorized invalid_credential permission_denied stale_authority_epoch resnapshot_required maintenance_required profile_policy_changed profile_trust_changed profile_author_unavailable profile_unavailable stale_resource_revision stale_binding_revision profile_selection_changed stale_rule_generation review_capacity profile_operation_capacity profile_review_expired profile_review_mismatch profile_review_consumed profile_review_missing profile_review_unavailable profile_capacity review_conflict profile_transition_capacity revision_exhausted enrollment_conflict target_unavailable)a

  # Store owns the transient review checkout and verifies bytes/runtime before
  # starting this transaction. No filesystem or native compiler runs here.
  def select(db, credential, document, %Review{} = review, deadline, runtime) do
    result =
      with {:ok, :new, basis} <- ProfileWriter.selection_basis(db, credential, document),
           {:ok, input} <- Operation.decode(document),
           true <-
             basis == review.basis and review.input_document == document and
               runtime == review.runtime_digest and is_integer(deadline) and
               deadline <= review.capture_deadline,
           :ok <- fresh(deadline),
           :ok <- QualificationHistory.validate(db),
           {:ok, [values]} <-
             query(
               db,
               "SELECT #{Enum.join(@artifact_fields, ",")} FROM portable_profiles WHERE artifact_digest=?",
               [input["artifact_digest"]]
             ),
           artifact = Map.new(Enum.zip(@artifact_fields, values)),
           {:ok, history} <- Review.decode_history(review.document, artifact),
           true <-
             history.thing == review.thing and
               history.identity_digest == review.enrollment.identity_digest,
           :ok <- selection_capacity(db, basis),
           :ok <- unused_review(db, input["review_ref"]),
           :ok <- available_identity(db, review),
           :ok <- review_capacity(db, input["target_id"]),
           :ok <- operation_capacity(db),
           :ok <- suspended_policy(db),
           {:ok, pending} <- pending(db, input["target_id"]),
           {:ok, binding} <- Journal.next_revision(db),
           :ok <- commit_reviewed_declaration(db, review, binding),
           {:ok, selected} <- Journal.next_revision(db),
           row = selection_row(basis, input, review, binding, selected),
           :ok <-
             Journal.authority_event(db, selected, "thing_profile_selected", input["target_id"]),
           :ok <- retain_selection(db, row),
           :ok <- clear_current(db, input["target_id"]),
           {:ok, counts} <- invalidate(db, pending, "profile_selected"),
           {:ok, final} <- Journal.next_revision(db),
           parent =
             operation_row(
               basis["principal_id"],
               input,
               document,
               final,
               basis["trust_generation"],
               basis["profile_policy_generation"],
               %{counts | changed_targets: 1}
             ),
           :ok <- retain_operation(db, parent, "portable_profile_selection_committed"),
           :ok <- WotexHome.Durable.Store.NativeTargetHistory.withdraw_if_current(db),
           :ok <- ProfileWriter.validate(db),
           :ok <- WotexHome.Durable.Store.NativeTargetHistory.validate_if_current(db),
           :ok <- fresh(deadline) do
        {:commit, {:ok, receipt(parent)}}
      else
        {:ok, :existing, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
        false -> {:error, :profile_review_mismatch}
        error -> error
      end

    policy(result)
  end

  def select(_, _, _, _, _, _), do: {:rollback, {:policy, :profile_review_mismatch}}

  @doc "Revoke retained selected scopes without opening artifact or capture custody."
  def revoke_targets(db, principal, input) do
    fields = ProfileSelectionHistory.fields()
    columns = Enum.map_join(fields, ",", &("h." <> &1))

    {where, params} =
      if input["action"] == "revoke_selection",
        do:
          {"c.target_id=? AND h.artifact_digest=?",
           [input["target_id"], input["artifact_digest"]]},
        else: {"h.artifact_digest=?", [input["artifact_digest"]]}

    with :ok <- QualificationHistory.validate(db),
         :ok <- suspended_policy(db),
         {:ok, values} <-
           query(
             db,
             "SELECT #{columns} FROM profile_current c JOIN profile_selection_history h ON h.revision=c.selection_revision WHERE c.state='selected' AND " <>
               where <> " ORDER BY c.target_id LIMIT 65",
             params
           ),
         true <- length(values) <= 64,
         rows = Enum.map(values, &Map.new(Enum.zip(fields, &1))),
         :ok <- revoke_pins(input, rows) do
      Enum.reduce_while(
        rows,
        {:ok, %{changed_targets: 0, invalidated_requests: 0, unknown_outcomes: 0}},
        fn old, {:ok, counts} ->
          with {:ok, pending} <- pending(db, old["target_id"]),
               {:ok, revision} <- Journal.next_revision(db),
               row =
                 Map.merge(old, %{
                   "generation" => old["generation"] + 1,
                   "principal_id" => principal,
                   "authority_epoch" => input["authority_epoch"],
                   "operation_id" => input["operation_id"],
                   "previous_selection_revision" => old["revision"],
                   "previous_resource_revision" => old["resource_revision"],
                   "previous_binding_revision" => old["binding_revision"],
                   "state" => "revoked",
                   "resource_revision" => old["resource_revision"] + 1,
                   "review_document" => "",
                   "revision" => revision
                 }),
               :ok <-
                 Journal.authority_event(
                   db,
                   revision,
                   "thing_profile_selection_revoked",
                   old["target_id"]
                 ),
               :ok <- retain_selection(db, row),
               {:ok, []} <-
                 query(
                   db,
                   "UPDATE enrolled_things SET resource_revision=? WHERE thing_id=? AND resource_revision=?",
                   [row["resource_revision"], row["target_id"], old["resource_revision"]]
                 ),
               {:ok, [[1]]} <- query(db, "SELECT changes()"),
               :ok <- clear_current(db, old["target_id"]),
               {:ok, affected} <-
                 invalidate(
                   db,
                   pending,
                   if(input["action"] == "revoke",
                     do: "profile_trust_revoked",
                     else: "profile_selection_revoked"
                   )
                 ) do
            {:cont,
             {:ok,
              %{
                changed_targets: counts.changed_targets + 1,
                invalidated_requests: counts.invalidated_requests + affected.invalidated_requests,
                unknown_outcomes: counts.unknown_outcomes + affected.unknown_outcomes
              }}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
            _ -> {:halt, {:error, :corrupt_profile_ledger}}
          end
        end
      )
    else
      false -> {:error, :corrupt_profile_ledger}
      error -> error
    end
  end

  def operation_row(
        principal,
        input,
        document,
        final,
        trust_generation,
        policy_generation,
        counts
      ) do
    Map.merge(
      Map.take(input, ~w(action authority_epoch operation_id expected_revision artifact_digest)),
      %{
        "principal_id" => principal,
        "input_document" => document,
        "input_digest" => Artifact.digest(document),
        "final_revision" => final,
        "changed_targets" => counts.changed_targets,
        "invalidated_requests" => counts.invalidated_requests,
        "unknown_outcomes" => counts.unknown_outcomes,
        "previous_trust_revision" => input["expected_trust_revision"],
        "trust_generation" => trust_generation,
        "policy_generation" => policy_generation
      }
    )
  end

  def retain_operation(db, row, event) do
    with {:ok, _} <- LedgerCodec.encode("operation", row),
         :ok <- Journal.authority_event(db, row["final_revision"], event, row["artifact_digest"]),
         :ok <- insert(db, "profile_operations", @operation_fields, row) do
      :ok
    end
  end

  def receipt(row), do: Map.new(@receipt_fields, fn key -> {key, row[Atom.to_string(key)]} end)

  defp selection_row(basis, input, review, binding, revision) do
    %{
      "target_id" => input["target_id"],
      "generation" => basis["selection_generation"] + 1,
      "principal_id" => basis["principal_id"],
      "authority_epoch" => input["authority_epoch"],
      "operation_id" => input["operation_id"],
      "previous_selection_revision" => basis["selection_revision"],
      "previous_resource_revision" => basis["resource_revision"],
      "previous_binding_revision" => basis["binding_revision"],
      "artifact_digest" => basis["artifact_digest"],
      "projection_digest" => basis["projection_digest"],
      "trust_revision" => basis["trust_revision"],
      "state" => "selected",
      "resource_revision" => basis["resource_revision"] + 1,
      "binding_revision" => binding,
      "runtime_digest" => review.runtime_digest,
      "review_document" => review.document,
      "thing_document" => Registry.encode_thing(review.thing) |> elem(1),
      "revision" => revision
    }
  end

  defp retain_selection(db, row) do
    with {:ok, _} <- LedgerCodec.encode("selection", row),
         :ok <- insert(db, "profile_selection_history", ProfileSelectionHistory.fields(), row),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_current VALUES (?,?,?,?) ON CONFLICT(target_id) DO UPDATE SET generation=excluded.generation,selection_revision=excluded.selection_revision,state=excluded.state",
             [row["target_id"], row["generation"], row["revision"], row["state"]]
           ) do
      :ok
    end
  end

  defp available_identity(db, review) do
    case query(db, "SELECT thing_id FROM enrollment_bindings WHERE stable_id=? AND thing_id!=?", [
           review.enrollment.stable_id,
           review.thing.id
         ]) do
      {:ok, []} -> :ok
      {:ok, [_ | _]} -> {:error, :enrollment_conflict}
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp commit_reviewed_declaration(
         db,
         %{basis: %{"current_thing_document" => nil}} = review,
         binding
       ) do
    e = review.enrollment

    with {:ok, []} <-
           query(db, "SELECT thing_id FROM enrolled_things WHERE thing_id=?", [e.thing_id]),
         {:ok, document} <- Registry.encode_thing(review.thing),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO enrolled_things (thing_id,profile_ref,document,resource_revision,status) VALUES (?,?,?,1,'active')",
             [e.thing_id, e.profile_ref, document]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO enrollment_bindings (thing_id,stable_id,identity_digest,candidate_ref,review_ref,method,qualification_ref,operator_id,profile_ref,revision,digest_version) VALUES (?,?,?,?,?,?,?,?,?,?,2)",
             [
               e.thing_id,
               e.stable_id,
               e.identity_digest,
               e.candidate_ref,
               e.review_ref,
               e.method,
               e.qualification_ref,
               e.operator_id,
               e.profile_ref,
               binding
             ]
           ),
         :ok <- retain_review(db, binding, review),
         :ok <- Journal.authority_event(db, binding, "thing_enrolled_reviewed", e.thing_id) do
      :ok
    else
      {:ok, [_ | _]} -> {:error, :enrollment_conflict}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp commit_reviewed_declaration(db, review, binding) do
    with :ok <- retain_review(db, binding, review),
         :ok <-
           Journal.authority_event(db, binding, "thing_enrollment_rereviewed", review.thing.id),
         :ok <- replace_declaration(db, review, binding),
         do: :ok
  end

  defp retain_review(db, revision, review) do
    e = review.enrollment

    case query(db, "INSERT INTO enrollment_review_history VALUES (?,?,?,?,2,?,?,?,?,?,?,?,?,?)", [
           revision,
           e.thing_id,
           e.stable_id,
           e.identity_digest,
           e.candidate_ref,
           e.review_ref,
           e.method,
           e.qualification_ref,
           e.operator_id,
           e.profile_ref,
           review.interview.manufacturer,
           review.interview.model,
           review.interview.firmware
         ]) do
      {:ok, []} -> :ok
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp replace_declaration(db, review, binding) do
    e = review.enrollment

    with {:ok, document} <- Registry.encode_thing(review.thing),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrolled_things SET profile_ref=?,document=?,resource_revision=resource_revision+1 WHERE thing_id=? AND resource_revision=? AND status='active'",
             [e.profile_ref, document, e.thing_id, review.basis["resource_revision"]]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrollment_bindings SET identity_digest=?,candidate_ref=?,review_ref=?,qualification_ref=?,operator_id=?,profile_ref=?,revision=? WHERE thing_id=? AND revision=?",
             [
               e.identity_digest,
               e.candidate_ref,
               e.review_ref,
               e.qualification_ref,
               e.operator_id,
               e.profile_ref,
               binding,
               e.thing_id,
               review.basis["binding_revision"]
             ]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()") do
      :ok
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp clear_current(db, target) do
    with :ok <- OverrideWriter.clear_override_for_target(db, target),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id=?", [target]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id=?", [target]),
         {:ok, []} <-
           query(db, "UPDATE profile_qualifications SET status='revoked' WHERE thing_id=?", [
             target
           ]) do
      :ok
    end
  end

  defp pending(db, target) do
    with {:ok, held} <- RequestInvalidator.held_for_thing(db, target),
         {:ok, execution} <- RequestInvalidator.pending_execution_rows(db, {:thing, target}),
         true <- length(held) + length(execution) <= 1_024 do
      {:ok, %{held: held, execution: execution}}
    else
      false -> {:error, :profile_transition_capacity}
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp invalidate(db, pending, reason) do
    with {:ok, _} <- RequestInvalidator.reject_held_batch(db, pending.held, reason),
         :ok <-
           Enum.reduce_while(pending.execution, :ok, fn [principal, epoch, operation, state],
                                                        :ok ->
             case RequestInvalidator.invalidate_execution_row(
                    db,
                    principal,
                    epoch,
                    operation,
                    state,
                    reason
                  ) do
               {:ok, _} -> {:cont, :ok}
               error -> {:halt, error}
             end
           end) do
      {:ok,
       %{
         changed_targets: 0,
         invalidated_requests: length(pending.held) + length(pending.execution),
         unknown_outcomes:
           Enum.count(pending.execution, &(List.last(&1) in ["dispatching", "protocol_accepted"]))
       }}
    end
  end

  defp revoke_pins(%{"action" => "revoke_selection"} = input, [row]) do
    if row["resource_revision"] == input["expected_resource_revision"] and
         row["generation"] == input["expected_selection_generation"] and
         row["resource_revision"] < @max_i64, do: :ok, else: {:error, :profile_selection_changed}
  end

  defp revoke_pins(%{"action" => "revoke_selection"}, _), do: {:error, :profile_selection_changed}

  defp revoke_pins(%{"action" => "revoke"}, rows),
    do:
      if(Enum.all?(rows, &(&1["resource_revision"] < @max_i64)),
        do: :ok,
        else: {:error, :profile_selection_changed}
      )

  defp selection_capacity(_db, %{"selection_generation" => generation}) when generation > 0,
    do: :ok

  defp selection_capacity(db, _) do
    case query(db, "SELECT COUNT(*) FROM profile_current") do
      {:ok, [[count]]} when count < 64 -> :ok
      {:ok, [[_]]} -> {:error, :profile_capacity}
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp unused_review(db, reference) do
    case query(db, "SELECT revision FROM enrollment_review_history WHERE review_ref=?", [
           reference
         ]) do
      {:ok, []} -> :ok
      {:ok, [_ | _]} -> {:error, :review_conflict}
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp review_capacity(db, target) do
    case query(db, "SELECT COUNT(*) FROM enrollment_review_history WHERE thing_id=?", [target]) do
      {:ok, [[count]]} when count < 32 -> :ok
      _ -> {:error, :review_capacity}
    end
  end

  defp operation_capacity(db) do
    case query(db, "SELECT COUNT(*) FROM profile_operations") do
      {:ok, [[count]]} when count < 1_024 -> :ok
      _ -> {:error, :profile_operation_capacity}
    end
  end

  defp suspended_policy(db) do
    case query(db, "SELECT value FROM meta WHERE key='active_rule_admission'") do
      {:ok, [[0]]} -> :ok
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp fresh(deadline) when is_integer(deadline),
    do:
      if(System.monotonic_time(:millisecond) < deadline,
        do: :ok,
        else: {:error, :profile_review_expired}
      )

  defp fresh(_), do: {:error, :profile_review_expired}

  defp insert(db, table, fields, row) do
    case query(
           db,
           "INSERT INTO #{table} (#{Enum.join(fields, ",")}) VALUES (#{Enum.map_join(fields, ",", fn _ -> "?" end)})",
           Enum.map(fields, &row[&1])
         ) do
      {:ok, []} -> :ok
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp policy({:error, reason}) when reason in @denials, do: {:rollback, {:policy, reason}}
  defp policy({:error, reason}), do: {:rollback, reason}
  defp policy(result), do: result
end
