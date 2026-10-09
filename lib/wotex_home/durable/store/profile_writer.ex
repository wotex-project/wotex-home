defmodule WotexHome.Durable.Store.ProfileWriter do
  @moduledoc """
  Stateless retained local digest approvals for the single Store writer.

  Approval is catalogue admission, separate from target selection and
  qualification. Selection barriers and owning-domain pins are validated
  bidirectionally against their retained operation and journal history.
  """

  alias WotexHome.Durable.Registry

  alias WotexHome.Durable.Store.{
    Access,
    Journal,
    MaintenanceWriter,
    ProfilePinHistory,
    ProfileSelectionHistory,
    ProfileTransition
  }

  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Profiles.{Artifact, LedgerCodec, Operation, Review}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @artifact_fields ~w(artifact_digest id version metadata_document projection_document projection_digest binding registry_digest first_approval_revision)
  @operation_fields ~w(principal_id authority_epoch operation_id action input_document input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)
  @artifact_columns Enum.join(@artifact_fields, ",")
  @operation_columns Enum.join(@operation_fields, ",")
  @receipt_fields ~w(authority_epoch operation_id action input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)a
  @inactive_tables ~w(profile_selection_history profile_current profile_observation_pins profile_request_pins profile_rule_pins profile_qualification_pins)
  @max_i64 9_223_372_036_854_775_807
  @denials ~w(unauthorized invalid_credential permission_denied invalid_profile_operation profile_operation_conflict stale_authority_epoch resnapshot_required maintenance_required profile_trust_changed profile_unavailable profile_label_conflict profile_already_approved profile_already_revoked profile_capacity profile_operation_capacity profile_selection_unavailable profile_selection_changed profile_transition_capacity revision_exhausted)a

  @doc "Current authentication and original receipt lookup precede custody/CAS work."
  def prepare(db, credential, document) do
    with {:ok, input} <- Operation.decode(document),
         {:ok, principal} <- actor(db, credential),
         :ok <- validate(db),
         :ok <- WotexHome.Durable.Store.NativeTargetHistory.validate_if_current(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@operation_columns} FROM profile_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [row] ->
          stored = row_map(@operation_fields, row)

          if stored["input_document"] == document,
            do: {:ok, :existing, receipt(stored)},
            else: {:error, :profile_operation_conflict}

        _ ->
          {:error, :corrupt_profile_ledger}
      end
    end
  end

  @doc "Current lifecycle authentication for the transient review owner."
  def review_actor(db, credential) do
    with {:ok, principal} <- actor(db, credential), :ok <- validate(db), do: {:ok, principal}
  end

  def change(db, credential, document, artifact) do
    result =
      with {:ok, :new, principal, input} <- prepare(db, credential, document),
           :ok <- supported_action(input["action"]),
           {:ok, revision, epoch, policy} <- meta(db),
           :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
           :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
           {:ok, _} <- MaintenanceWriter.require_active(db),
           {:ok, previous} <- trust(db, input["artifact_digest"]),
           :ok <-
             equal(previous.revision, input["expected_trust_revision"], :profile_trust_changed),
           :ok <- desired_change(input["action"], previous),
           {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM profile_operations"),
           true <- count < 1_024 and policy < @max_i64,
           {:ok, counts} <- transition_counts(db, principal, input),
           {:ok, final} <- Journal.next_revision(db),
           :ok <- retain_artifact(db, input, artifact, final),
           next_policy = policy + if(input["action"] in ["approve", "revoke"], do: 1, else: 0),
           next_trust =
             previous.generation + if(input["action"] in ["approve", "revoke"], do: 1, else: 0),
           row =
             ProfileTransition.operation_row(
               principal,
               input,
               document,
               final,
               next_trust,
               next_policy,
               counts
             ),
           {:ok, _} <- LedgerCodec.encode("operation", row),
           :ok <-
             Journal.authority_event(db, final, event(input["action"]), input["artifact_digest"]),
           {:ok, []} <-
             query(
               db,
               "INSERT INTO profile_operations (#{@operation_columns}) VALUES (#{placeholders(@operation_fields)})",
               Enum.map(@operation_fields, &row[&1])
             ),
           {:ok, []} <-
             query(db, "UPDATE meta SET value=? WHERE key='profile_policy_generation'", [
               next_policy
             ]),
           {:ok, [[1]]} <- query(db, "SELECT changes()"),
           :ok <- WotexHome.Durable.Store.NativeTargetHistory.withdraw_if_current(db),
           :ok <- validate(db),
           :ok <- WotexHome.Durable.Store.NativeTargetHistory.validate_if_current(db) do
        {:commit, {:ok, receipt(row)}}
      else
        {:ok, :existing, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
        false -> {:error, :profile_operation_capacity}
        error -> error
      end

    case result do
      {:error, reason} when reason in @denials -> {:rollback, {:policy, reason}}
      {:error, reason} -> {:rollback, reason}
      other -> other
    end
  end

  def operation_status(db, credential, epoch, operation) do
    with true <- is_integer(epoch) and epoch in 1..@max_i64 and WotexHome.Id.valid?(operation),
         {:ok, principal} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@operation_columns} FROM profile_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [row] -> {:ok, receipt(row_map(@operation_fields, row))}
        _ -> {:error, :corrupt_profile_ledger}
      end
    else
      false -> {:error, :invalid_profile_operation}
      error -> error
    end
  end

  def catalogue(db, credential) do
    with {:ok, _} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, revision, epoch, policy} <- meta(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@artifact_columns} FROM portable_profiles ORDER BY id,version LIMIT 65"
           ),
         {:ok, items} <- summaries(db, rows) do
      {:ok,
       %{
         store_revision: revision,
         authority_epoch: epoch,
         policy_generation: policy,
         items: items
       }}
    end
  end

  @doc "Authenticated proposal basis; neither capture consumption nor selection occurs here."
  def selection_basis(db, credential, document) do
    with {:ok, input} <- Operation.decode(document),
         "select" <- input["action"],
         {:ok, :new, principal, ^input} <- prepare(db, credential, document),
         {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         true <- "enroll:review" in permissions,
         {:ok, revision, epoch, policy} <- meta(db),
         :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
         :ok <- equal(policy, input["expected_policy_generation"], :profile_policy_changed),
         {:ok, maintenance} <- MaintenanceWriter.require_active(db),
         {:ok, previous} <- trust(db, input["artifact_digest"]),
         :ok <- equal(previous.revision, input["expected_trust_revision"], :profile_trust_changed),
         "approve" <- previous.action,
         {:ok, author_permissions} <- Access.active_principal_permissions(db, previous.principal),
         true <- "profile:manage" in author_permissions,
         {:ok, [[id, version, projection, registry]]} <-
           query(
             db,
             "SELECT id,version,projection_digest,registry_digest FROM portable_profiles WHERE artifact_digest=?",
             [input["artifact_digest"]]
           ),
         {:ok, thing, resource, identity} <- selection_target(db, input["target_id"]),
         :ok <- equal(resource, input["expected_resource_revision"], :stale_resource_revision),
         :ok <-
           equal(identity.revision, input["expected_binding_revision"], :stale_binding_revision),
         {:ok, selection_revision, selection_generation} <-
           selection_cursor(db, input["target_id"]),
         :ok <-
           equal(
             selection_generation,
             input["expected_selection_generation"],
             :profile_selection_changed
           ),
         :ok <- revision_room(resource),
         {:ok, [[rule_generation]]} <-
           query(db, "SELECT value FROM meta WHERE key='rule_generation'"),
         :ok <- equal(rule_generation, input["expected_rule_generation"], :stale_rule_generation),
         {:ok, current_document} <- selection_document(thing),
         basis = %{
           "principal_id" => principal,
           "authority_epoch" => epoch,
           "store_revision" => revision,
           "profile_policy_generation" => policy,
           "rule_generation" => rule_generation,
           "maintenance_revision" => maintenance,
           "target_id" => input["target_id"],
           "resource_revision" => resource,
           "binding_revision" => identity.revision,
           "selection_revision" => selection_revision,
           "selection_generation" => selection_generation,
           "trust_revision" => previous.revision,
           "trust_generation" => previous.generation,
           "artifact_digest" => input["artifact_digest"],
           "projection_digest" => projection,
           "registry_digest" => registry,
           "profile_ref" => id <> ":" <> version,
           "stable_id" => identity.stable_id,
           "manufacturer" => identity.manufacturer,
           "model" => identity.model,
           "firmware" => identity.firmware,
           "current_thing_document" => current_document
         },
         :ok <- Review.valid_basis(basis) do
      {:ok, :new, basis}
    else
      {:ok, :existing, receipt} -> {:ok, :existing, receipt}
      false -> {:error, :permission_denied}
      nil -> {:error, :profile_unavailable}
      "revoke" -> {:error, :profile_unavailable}
      {:error, :principal_unavailable} -> {:error, :profile_author_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_profile_selection}
    end
  end

  defp selection_target(db, target) do
    case query(db, "SELECT status FROM enrolled_things WHERE thing_id=?", [target]) do
      {:ok, []} ->
        {:ok, nil, 0,
         %{stable_id: nil, revision: 0, manufacturer: nil, model: nil, firmware: nil}}

      {:ok, [["active"]]} ->
        with {:ok, thing, resource} <- Access.enrolled_thing(db, target),
             {:ok, identity} <- reviewed_identity(db, thing),
             do: {:ok, thing, resource, identity}

      {:ok, [["revoked"]]} ->
        {:error, :target_unavailable}

      _ ->
        {:error, :corrupt_enrollment}
    end
  end

  defp selection_document(nil), do: {:ok, nil}
  defp selection_document(thing), do: Registry.encode_thing(thing)

  @doc false
  def reviewed_identity(db, thing) do
    case query(
           db,
           "SELECT b.stable_id,b.revision,b.digest_version,b.method,b.profile_ref,b.review_ref,b.identity_digest,b.qualification_ref,b.operator_id,h.stable_id,h.manufacturer,h.model,h.firmware,h.profile_ref,h.review_ref,h.identity_digest,h.qualification_ref,h.operator_id,h.digest_version,a.entity_id,a.event_type FROM enrollment_bindings b LEFT JOIN enrollment_review_history h ON h.revision=b.revision LEFT JOIN authority_journal a ON a.revision=b.revision WHERE b.thing_id=?",
           [thing.id]
         ) do
      {:ok,
       [
         [
           stable,
           revision,
           2,
           "legacy_tofu",
           profile,
           review,
           digest,
           qualification,
           operator,
           stable,
           manufacturer,
           model,
           firmware,
           profile,
           review,
           digest,
           qualification,
           operator,
           2,
           target,
           event
         ]
       ]}
      when profile == thing.profile_ref and target == thing.id ->
        if event in ["thing_enrolled_reviewed", "thing_enrollment_rereviewed"] and
             Enum.all?(
               [manufacturer, model, firmware, review, qualification, operator],
               &WotexHome.Id.valid?/1
             ) and
             WotexHome.Profiles.Codec.digest?(digest) and is_integer(revision) and
             revision in 1..@max_i64 and
             WotexHome.Durable.Store.RefreshWriter.valid_lifx_stable_id?(stable) do
          {:ok,
           %{
             stable_id: stable,
             revision: revision,
             manufacturer: manufacturer,
             model: model,
             firmware: firmware
           }}
        else
          {:error, :corrupt_enrollment}
        end

      {:ok, []} ->
        {:error, :review_binding_unavailable}

      {:ok, [[_, _, 1 | _]]} ->
        {:error, :review_binding_unavailable}

      {:ok, _} ->
        {:error, :corrupt_enrollment}

      error ->
        error
    end
  end

  @doc "Read-only semantic/journal integrity; independent of current file availability."
  def validate(db) do
    with {:ok, [[version]]} when version in [19, 20, 21, 22, 23, 24, 25, 26, 27, 28] <-
           query(db, "PRAGMA user_version"),
         {:ok, revision, epoch, policy} <- meta(db),
         {:ok, artifacts} <-
           query(
             db,
             "SELECT #{@artifact_columns} FROM portable_profiles ORDER BY first_approval_revision LIMIT 65"
           ),
         true <- length(artifacts) <= 64 - length(ProfileCatalogue.summaries()),
         {:ok, profiles} <- validated_artifacts(artifacts),
         {:ok, operations} <-
           query(
             db,
             "SELECT #{@operation_columns} FROM profile_operations ORDER BY final_revision LIMIT 1025"
           ),
         true <- length(operations) <= 1_024,
         {:ok, [[event_count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('portable_profile_approved','portable_profile_revoked','portable_profile_selection_committed','portable_profile_target_revoked')"
           ),
         true <- event_count == length(operations),
         :ok <- validate_operations(db, operations, profiles, revision, epoch, policy, version),
         :ok <- selection_integrity(db, version, profiles, operations, revision, epoch) do
      :ok
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  @doc "Exact retained external dependencies for encrypted archive summaries."
  def dependencies(db) do
    with :ok <- validate(db),
         {:ok, profiles} <-
           query(
             db,
             "SELECT artifact_digest,projection_digest,registry_digest FROM portable_profiles ORDER BY artifact_digest LIMIT 65"
           ),
         {:ok, [[operations]]} <- query(db, "SELECT COUNT(*) FROM profile_operations"),
         {:ok, [[selections]]} <- query(db, "SELECT COUNT(*) FROM profile_selection_history") do
      {:ok,
       %{
         profile_artifacts:
           Enum.map(profiles, fn [raw, projection, registry] ->
             %{artifact_digest: raw, projection_digest: projection, registry_digest: registry}
           end),
         profile_operation_rows: operations,
         profile_selection_rows: selections,
         portable_profile_bytes_included: false,
         profile_history_reactivates_on_restore: false
       }}
    end
  end

  @doc "Store-serialized immutable history references for inert custody collection."
  def collection_references(db, credential) do
    with {:ok, _} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, _} <- MaintenanceWriter.require_active(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT artifact_digest FROM portable_profiles ORDER BY artifact_digest LIMIT 65"
           ) do
      {:ok, Enum.map(rows, &hd/1)}
    end
  end

  defp actor(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- "profile:manage" in permissions do
      {:ok, principal}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp meta(db) do
    case query(
           db,
           "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='profile_policy_generation')"
         ) do
      {:ok, [[revision, epoch, policy]]}
      when is_integer(revision) and revision in 0..@max_i64 and is_integer(epoch) and
             epoch in 1..@max_i64 and is_integer(policy) and policy in 0..1_024 ->
        {:ok, revision, epoch, policy}

      _ ->
        {:error, :corrupt_profile_ledger}
    end
  end

  defp trust(db, digest) do
    case query(
           db,
           "SELECT action,final_revision,trust_generation,principal_id FROM profile_operations WHERE artifact_digest=? AND action IN ('approve','revoke') ORDER BY final_revision DESC LIMIT 1",
           [digest]
         ) do
      {:ok, []} ->
        {:ok, %{action: nil, revision: 0, generation: 0, principal: nil}}

      {:ok, [[action, revision, generation, principal]]} ->
        {:ok, %{action: action, revision: revision, generation: generation, principal: principal}}

      _ ->
        {:error, :corrupt_profile_ledger}
    end
  end

  defp desired_change("approve", %{action: "approve"}), do: {:error, :profile_already_approved}
  defp desired_change("approve", _), do: :ok
  defp desired_change("revoke", %{action: nil}), do: {:error, :profile_unavailable}
  defp desired_change("revoke", %{action: "revoke"}), do: {:error, :profile_already_revoked}
  defp desired_change("revoke", _), do: :ok
  defp desired_change("revoke_selection", %{action: "approve"}), do: :ok
  defp desired_change("revoke_selection", _), do: {:error, :profile_trust_changed}

  defp retain_artifact(_db, %{"action" => action}, _artifact, _final)
       when action in ["revoke", "revoke_selection"], do: :ok

  defp retain_artifact(db, input, %Artifact{} = artifact, final) do
    with true <- artifact.digest == input["artifact_digest"],
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@artifact_columns} FROM portable_profiles WHERE artifact_digest=?",
             [artifact.digest]
           ) do
      case rows do
        [row] ->
          stored = row_map(@artifact_fields, row)

          if stored["metadata_document"] == JSON.encode!(artifact.data) and
               stored["projection_document"] == artifact.projection_document,
             do: :ok,
             else: {:error, :corrupt_profile_ledger}

        [] ->
          insert_artifact(db, artifact, final)

        _ ->
          {:error, :corrupt_profile_ledger}
      end
    else
      false -> {:error, :profile_unavailable}
      error -> error
    end
  end

  defp retain_artifact(_, _, _, _), do: {:error, :profile_unavailable}

  defp insert_artifact(db, artifact, final) do
    with {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM portable_profiles"),
         true <- count < 64 - length(ProfileCatalogue.summaries()),
         {:ok, []} <-
           query(db, "SELECT artifact_digest FROM portable_profiles WHERE id=? AND version=?", [
             artifact.data["id"],
             artifact.data["version"]
           ]),
         row = %{
           "artifact_digest" => artifact.digest,
           "id" => artifact.data["id"],
           "version" => artifact.data["version"],
           "metadata_document" => JSON.encode!(artifact.data),
           "projection_document" => artifact.projection_document,
           "projection_digest" => artifact.projection_digest,
           "binding" => artifact.data["binding"],
           "registry_digest" => hd(artifact.data["dependencies"])["sha256"],
           "first_approval_revision" => final
         },
         {:ok, _} <- LedgerCodec.encode("artifact", row),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO portable_profiles (#{@artifact_columns}) VALUES (#{placeholders(@artifact_fields)})",
             Enum.map(@artifact_fields, &row[&1])
           ) do
      :ok
    else
      false -> {:error, :profile_capacity}
      {:ok, [_ | _]} -> {:error, :profile_label_conflict}
      error -> error
    end
  end

  defp transition_counts(_db, _principal, %{"action" => "approve"}),
    do: {:ok, %{changed_targets: 0, invalidated_requests: 0, unknown_outcomes: 0}}

  defp transition_counts(db, principal, input),
    do: ProfileTransition.revoke_targets(db, principal, input)

  defp revision_room(resource) when resource < @max_i64, do: :ok
  defp revision_room(_), do: {:error, :revision_exhausted}

  defp selection_cursor(db, target) do
    case query(
           db,
           "SELECT selection_revision,generation FROM profile_current WHERE target_id=?",
           [target]
         ) do
      {:ok, []} -> {:ok, 0, 0}
      {:ok, [[revision, generation]]} -> {:ok, revision, generation}
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp validated_artifacts(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      data = row_map(@artifact_fields, row)

      case LedgerCodec.encode("artifact", data) do
        {:ok, _} -> {:cont, {:ok, Map.put(acc, data["artifact_digest"], data)}}
        _ -> {:halt, {:error, :corrupt_profile_ledger}}
      end
    end)
  end

  defp validate_operations(db, rows, profiles, revision, epoch, policy, version) do
    Enum.reduce_while(rows, {:ok, %{history: %{}, policy: 0, last_final: 0}}, fn values,
                                                                                 {:ok, state} ->
      row = row_map(@operation_fields, values)
      digest = row["artifact_digest"]
      previous = Map.get(state.history, digest, %{revision: 0, generation: 0, action: nil})

      with {:ok, _} <- LedgerCodec.encode("operation", row),
           %{} = profile <- profiles[digest],
           true <-
             row["action"] in if(version == 19,
               do: ["approve", "revoke"],
               else: ["approve", "revoke", "select", "revoke_selection"]
             ),
           true <-
             row["final_revision"] <= revision and row["authority_epoch"] <= epoch and
               row["expected_revision"] >= state.last_final,
           true <- row["previous_trust_revision"] == previous.revision,
           {:ok, next_trust, next_policy} <- operation_trust(row, previous, state.policy, profile),
           true <-
             version >= 20 or
               (row["changed_targets"] == 0 and row["invalidated_requests"] == 0 and
                  row["unknown_outcomes"] == 0),
           {:ok, [[event, ^digest]]} <-
             query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
               row["final_revision"]
             ]),
           true <- event == event(row["action"]),
           {:ok, [[_]]} <-
             query(db, "SELECT principal_id FROM principals WHERE principal_id=?", [
               row["principal_id"]
             ]) do
        {:cont,
         {:ok,
          %{
            history: Map.put(state.history, digest, next_trust),
            policy: next_policy,
            last_final: row["final_revision"]
          }}}
      else
        _ -> {:halt, {:error, :corrupt_profile_ledger}}
      end
    end)
    |> case do
      {:ok, state}
      when map_size(state.history) == map_size(profiles) and state.policy == policy ->
        :ok

      _ ->
        {:error, :corrupt_profile_ledger}
    end
  end

  defp operation_trust(%{"action" => action} = row, previous, policy, profile)
       when action in ["approve", "revoke"] do
    with :ok <- desired_change(row["action"], previous),
         true <-
           row["trust_generation"] == previous.generation + 1 and
             row["policy_generation"] == policy + 1,
         true <- row["action"] != "approve" or row["changed_targets"] == 0,
         true <-
           previous.revision != 0 or
             (row["action"] == "approve" and
                profile["first_approval_revision"] == row["final_revision"]) do
      {:ok,
       %{
         revision: row["final_revision"],
         generation: row["trust_generation"],
         action: row["action"]
       }, policy + 1}
    else
      _ -> :error
    end
  end

  defp operation_trust(row, previous, policy, _profile) do
    if previous.action == "approve" and row["trust_generation"] == previous.generation and
         row["policy_generation"] == policy and row["changed_targets"] == 1,
       do: {:ok, previous, policy},
       else: :error
  end

  defp selection_integrity(db, 19, _profiles, _operations, _revision, _epoch) do
    if Enum.all?(@inactive_tables, fn table ->
         query(db, "SELECT COUNT(*) FROM #{table}") == {:ok, [[0]]}
       end), do: :ok, else: {:error, :corrupt_profile_ledger}
  end

  defp selection_integrity(db, version, profiles, rows, revision, epoch) when version in 20..28 do
    operations =
      Map.new(rows, fn values ->
        row = row_map(@operation_fields, values)
        {{row["principal_id"], row["authority_epoch"], row["operation_id"]}, row}
      end)

    with :ok <- ProfileSelectionHistory.validate(db, profiles, operations, revision, epoch),
         :ok <- ProfilePinHistory.validate(db),
         do: :ok
  end

  defp summaries(db, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn values, {:ok, acc} ->
      row = row_map(@artifact_fields, values)

      with {:ok, trust} <- trust(db, row["artifact_digest"]) do
        active_author =
          case Access.active_principal_permissions(db, trust.principal) do
            {:ok, permissions} -> "profile:manage" in permissions
            _ -> false
          end

        state =
          cond do
            trust.action == "revoke" -> :revoked
            active_author -> :approved
            true -> :author_unavailable
          end

        item =
          Map.take(row, ~w(artifact_digest id version projection_digest binding registry_digest))

        {:cont,
         {:ok,
          [
            Map.merge(item, %{
              "trust_revision" => trust.revision,
              "trust_generation" => trust.generation,
              "state" => state,
              "trust_author" => trust.principal,
              "byte_availability" =>
                if(
                  WotexHome.Durable.Store.ProfileByteContext.artifact_available?(
                    db,
                    row["artifact_digest"],
                    row["projection_digest"],
                    row["registry_digest"]
                  ),
                  do: :available,
                  else: :unavailable
                ),
              "qualification_status" => :pending_physical_evidence
            })
            | acc
          ]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp receipt(row), do: Map.new(@receipt_fields, fn key -> {key, row[Atom.to_string(key)]} end)
  defp supported_action(action) when action in ["approve", "revoke", "revoke_selection"], do: :ok
  defp supported_action(_), do: {:error, :profile_selection_unavailable}
  defp row_map(fields, values), do: Map.new(Enum.zip(fields, values))
  defp placeholders(fields), do: Enum.map_join(fields, ",", fn _ -> "?" end)
  defp event("approve"), do: "portable_profile_approved"
  defp event("revoke"), do: "portable_profile_revoked"
  defp event("select"), do: "portable_profile_selection_committed"
  defp event("revoke_selection"), do: "portable_profile_target_revoked"
  defp equal(value, value, _), do: :ok
  defp equal(_, _, error), do: {:error, error}
end
