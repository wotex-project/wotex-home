defmodule WotexHome.Durable.Store.ProfileWriter do
  @moduledoc """
  Stateless retained local digest approvals for the single Store writer.

  Approval is catalogue admission, never target selection or qualification.
  This first durable slice keeps selection and all owning-domain pin tables
  empty until their complete transition/guard mechanism is delivered.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, Journal, MaintenanceWriter}
  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Profiles.{Artifact, LedgerCodec, Operation}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @artifact_fields ~w(artifact_digest id version metadata_document projection_document projection_digest binding registry_digest first_approval_revision)
  @operation_fields ~w(principal_id authority_epoch operation_id action input_document input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)
  @artifact_columns Enum.join(@artifact_fields, ",")
  @operation_columns Enum.join(@operation_fields, ",")
  @receipt_fields ~w(authority_epoch operation_id action input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)a
  @inactive_tables ~w(profile_selection_history profile_current profile_observation_pins profile_request_pins profile_rule_pins profile_qualification_pins)
  @max_i64 9_223_372_036_854_775_807
  @denials ~w(unauthorized invalid_credential permission_denied invalid_profile_operation profile_operation_conflict stale_authority_epoch resnapshot_required maintenance_required profile_trust_changed profile_unavailable profile_label_conflict profile_already_approved profile_already_revoked profile_capacity profile_operation_capacity profile_selection_unavailable)a

  @doc "Current authentication and original receipt lookup precede custody/CAS work."
  def prepare(db, credential, document) do
    with {:ok, input} <- Operation.decode(document),
         {:ok, principal} <- actor(db, credential),
         :ok <- validate(db),
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
           {:ok, final} <- Journal.next_revision(db),
           :ok <- retain_artifact(db, input, artifact, final),
           row = operation_row(principal, input, document, final, previous, policy + 1),
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
               policy + 1
             ]),
           {:ok, [[1]]} <- query(db, "SELECT changes()"),
           :ok <- validate(db) do
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

  @doc "Read-only semantic/journal integrity; independent of current file availability."
  def validate(db) do
    with {:ok, revision, epoch, policy} <- meta(db),
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
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('portable_profile_approved','portable_profile_revoked')"
           ),
         true <- event_count == length(operations) and policy == length(operations),
         :ok <- validate_operations(db, operations, profiles, revision, epoch),
         true <-
           Enum.all?(@inactive_tables, fn table ->
             query(db, "SELECT COUNT(*) FROM #{table}") == {:ok, [[0]]}
           end) do
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
         {:ok, [[operations]]} <- query(db, "SELECT COUNT(*) FROM profile_operations") do
      {:ok,
       %{
         profile_artifacts:
           Enum.map(profiles, fn [raw, projection, registry] ->
             %{artifact_digest: raw, projection_digest: projection, registry_digest: registry}
           end),
         profile_operation_rows: operations,
         profile_selection_rows: 0,
         portable_profile_bytes_included: false,
         profile_history_reactivates_on_restore: false
       }}
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

  defp retain_artifact(_db, %{"action" => "revoke"}, _artifact, _final), do: :ok

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

  defp operation_row(principal, input, document, final, previous, policy) do
    Map.merge(
      Map.take(input, ~w(action authority_epoch operation_id expected_revision artifact_digest)),
      %{
        "principal_id" => principal,
        "input_document" => document,
        "input_digest" => Artifact.digest(document),
        "final_revision" => final,
        "changed_targets" => 0,
        "invalidated_requests" => 0,
        "unknown_outcomes" => 0,
        "previous_trust_revision" => previous.revision,
        "trust_generation" => previous.generation + 1,
        "policy_generation" => policy
      }
    )
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

  defp validate_operations(db, rows, profiles, revision, epoch) do
    Enum.reduce_while(Enum.with_index(rows, 1), {:ok, %{}}, fn {values, policy}, {:ok, history} ->
      row = row_map(@operation_fields, values)
      digest = row["artifact_digest"]
      previous = Map.get(history, digest, %{revision: 0, generation: 0, action: nil})

      with {:ok, _} <- LedgerCodec.encode("operation", row),
           %{} = profile <- profiles[digest],
           true <- row["action"] in ["approve", "revoke"],
           true <-
             row["policy_generation"] == policy and row["final_revision"] <= revision and
               row["authority_epoch"] <= epoch,
           true <-
             row["previous_trust_revision"] == previous.revision and
               row["trust_generation"] == previous.generation + 1,
           true <-
             row["changed_targets"] == 0 and row["invalidated_requests"] == 0 and
               row["unknown_outcomes"] == 0,
           :ok <- desired_change(row["action"], previous),
           true <-
             previous.revision != 0 or
               (row["action"] == "approve" and
                  profile["first_approval_revision"] == row["final_revision"]),
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
          Map.put(history, digest, %{
            revision: row["final_revision"],
            generation: row["trust_generation"],
            action: row["action"]
          })}}
      else
        _ -> {:halt, {:error, :corrupt_profile_ledger}}
      end
    end)
    |> case do
      {:ok, history} when map_size(history) == map_size(profiles) -> :ok
      _ -> {:error, :corrupt_profile_ledger}
    end
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
  defp supported_action(action) when action in ["approve", "revoke"], do: :ok
  defp supported_action(_), do: {:error, :profile_selection_unavailable}
  defp row_map(fields, values), do: Map.new(Enum.zip(fields, values))
  defp placeholders(fields), do: Enum.map_join(fields, ",", fn _ -> "?" end)
  defp event("approve"), do: "portable_profile_approved"
  defp event("revoke"), do: "portable_profile_revoked"
  defp equal(value, value, _), do: :ok
  defp equal(_, _, error), do: {:error, error}
end
