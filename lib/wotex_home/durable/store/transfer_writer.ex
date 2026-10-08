defmodule WotexHome.Durable.Store.TransferWriter do
  @moduledoc "Guarded destination transaction on the Store-owned handle; no host or transport."
  alias WotexHome.Durable.Registry

  alias WotexHome.Durable.Store.{
    ControllerHistory,
    ControllerWriter,
    ExecutionWriter,
    Integrity,
    Journal,
    MaintenanceWriter,
    PrincipalWriter,
    RecoveryDomains,
    RecoverySnapshot,
    Schema
  }

  alias WotexHome.Lifx.ProfileBasis
  alias WotexHome.Profiles.Artifact

  alias WotexHome.Recovery.{
    DomainCodec,
    IsolationDecision,
    TransferAcceptanceCodec,
    TransferAcceptanceRecord,
    TransferReviewCodec
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @maximum 9_223_372_036_854_775_807
  @counts [
    {"revoked_principals", :active_principal_rows,
     "UPDATE principals SET status='revoked' WHERE status='active'"},
    {"revoked_qualifications", :qualified_profile_heads,
     "UPDATE profile_qualifications SET status='revoked' WHERE status='qualified'"},
    {"cleared_source_grants", :source_grant_rows, "DELETE FROM source_epoch_grants"},
    {"cleared_observations", :current_observation_rows, "DELETE FROM observation_current"},
    {"cleared_target_grants", :target_grant_rows, "DELETE FROM principal_targets"},
    {"cleared_override_leases", :override_lease_rows, "DELETE FROM operator_override_leases"}
  ]

  @doc "Exact authenticated private receipt lookup; no challenge renewal or write."
  def existing(db, credential, input) do
    with {:ok, input_document} <- TransferAcceptanceCodec.encode("operation", input),
         {:ok, hash} <- Registry.credential_hash(credential),
         :ok <- ControllerWriter.validate(db),
         {:ok, [[version]]} when version in [21, 22, 23, 24, 25, 26] <-
           query(db, "PRAGMA user_version") do
      if version == 21 do
        :not_found
      else
        with {:ok, rows} <-
               query(
                 db,
                 "SELECT #{ControllerHistory.acceptance_columns()} FROM controller_acceptances WHERE principal_id=? AND source_epoch=? AND operation_id=?",
                 [input["principal_id"], input["source_epoch"], input["operation_id"]]
               ) do
          case rows do
            [] ->
              :not_found

            [row] ->
              with {:ok, record} <- TransferAcceptanceRecord.audit(row),
                   true <- record.review["credential_hash"] == Base.encode16(hash, case: :lower) do
                if Enum.at(row, 3) == input_document,
                  do: {:ok, record.receipt},
                  else: {:error, :controller_operation_conflict}
              else
                false -> {:error, :unauthorized}
                _ -> {:error, :corrupt_controller_acceptance}
              end

            _ ->
              {:error, :corrupt_controller_acceptance}
          end
        end
      end
    else
      {:ok, _} -> {:error, :invalid_transfer_snapshot}
      error -> error
    end
  end

  @doc false
  def accept_tx(db, review_document, domain_document, input, owner_guard)
      when is_function(owner_guard, 0) do
    result =
      with {:ok, input_document} <- TransferAcceptanceCodec.encode("operation", input),
           {:ok, review} <- TransferReviewCodec.decode(review_document),
           {:ok, scope} <- TransferReviewCodec.isolation_scope(review),
           true <-
             Map.take(
               input,
               ~w(principal_id source_epoch retirement_revision destination_owner_id review_digest)
             ) ==
               Map.take(
                 Map.put(review, "review_digest", Artifact.digest(review_document)),
                 ~w(principal_id source_epoch retirement_revision destination_owner_id review_digest)
               ),
           {:ok, isolated, policy_document} <- guard(owner_guard),
           {:ok, ^isolated} <-
             IsolationDecision.audit(isolated.package_bytes, scope, policy_document),
           true <- isolated.package_digest == input["isolation_package_digest"],
           {:ok, domains} <-
             DomainCodec.acceptance_basis(domain_document, isolated.decision["method"]),
           {:ok, source} <- source_basis(db, review, domain_document, domains),
           {:ok, retained} <-
             RecoverySnapshot.retained_commitment(db, source["revision"], input["principal_id"]),
           :ok <- Schema.install_transfer_schema_tx(db),
           {:ok, []} <-
             query(db, "UPDATE meta SET value=? WHERE key='authority_epoch' AND value=?", [
               source["authority_epoch"] + 1,
               source["authority_epoch"]
             ]),
           {:ok, [[1]]} <- query(db, "SELECT changes()"),
           {:commit,
            {:ok, %{store_revision: fence, rule_generation: generation, affected_requests: 0}}} <-
             ExecutionWriter.fence_rule_generation_tx(
               db,
               source["revision"],
               source["authority_epoch"] + 1
             ),
           true <-
             fence == source["revision"] + 1 and
               generation == review["source_rule_generation"] + 1,
           {:ok, changed} <- withdraw(db, domains.source_counts),
           {:ok, hash} <- Base.decode16(review["credential_hash"], case: :lower),
           {:commit, {:ok, nil, principal_revision}} <-
             PrincipalWriter.provision_principal_tx(
               db,
               review["principal_id"],
               hash,
               review["permissions_document"],
               [],
               nil
             ),
           true <- principal_revision == fence + 1,
           {:ok, final} <- Journal.next_revision(db),
           receipt =
             receipt(
               input,
               review,
               isolated,
               fence,
               principal_revision,
               final,
               generation,
               changed
             ),
           {:ok, receipt_document} <- TransferAcceptanceCodec.encode("acceptance", receipt),
           row = [
             input["principal_id"],
             input["source_epoch"],
             input["operation_id"],
             input_document,
             receipt_document,
             review_document,
             isolated.package_bytes,
             isolated.document,
             policy_document,
             domain_document,
             final
           ],
           {:ok, _} <- TransferAcceptanceRecord.audit(row),
           :ok <-
             Journal.authority_event(
               db,
               final,
               "controller_destination_accepted",
               "controller:" <> source["deployment_id"]
             ),
           {:ok, []} <-
             query(db, "INSERT INTO controller_acceptances VALUES (?,?,?,?,?,?,?,?,?,?,?)", row),
           {:ok, []} <-
             query(
               db,
               "INSERT INTO host_maintenance_operations VALUES (?,?,?,'transfer',?,?,?,?,?,0,0)",
               [
                 input["principal_id"],
                 source["authority_epoch"] + 1,
                 input["operation_id"],
                 source["revision"],
                 source["maintenance_revision"],
                 final,
                 fence,
                 generation
               ]
             ),
           {:ok, []} <-
             query(db, "UPDATE meta SET value=? WHERE key='maintenance_revision'", [final]),
           {:ok, [[1]]} <- query(db, "SELECT changes()"),
           {:ok, []} <-
             query(
               db,
               "UPDATE controller_identity SET owner_id=?,state='active',head_revision=? WHERE singleton=1 AND state='retired' AND head_revision=?",
               [input["destination_owner_id"], final, source["revision"]]
             ),
           {:ok, [[1]]} <- query(db, "SELECT changes()"),
           {:ok, []} <- query(db, "DELETE FROM meta WHERE key='restore_quarantine' AND value=1"),
           {:ok, [[1]]} <- query(db, "SELECT changes()"),
           :ok <- Integrity.validate_snapshot(db),
           :ok <- postconditions(db, review, receipt),
           {:ok, ^retained} <-
             RecoverySnapshot.retained_commitment(db, source["revision"], input["principal_id"]),
           :ok <- size(db),
           {:ok, ^isolated, ^policy_document} <- guard(owner_guard) do
        {:commit, {:ok, receipt}}
      else
        false -> {:error, :transfer_review_changed}
        {:rollback, reason} -> {:error, reason}
        {:ok, _} -> {:error, :transfer_review_changed}
        {:ok, _, _} -> {:error, :transfer_review_changed}
        error -> error
      end

    case result do
      {:commit, _} -> result
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :invalid_transfer_snapshot}
    end
  end

  def accept_tx(_, _, _, _, _), do: {:rollback, :invalid_transfer_snapshot}

  defp source_basis(db, review, document, decoded) do
    with :ok <- Integrity.validate_snapshot(db),
         {:ok, source} <- ControllerWriter.source_receipt(db),
         true <-
           Enum.all?(
             [
               {"deployment_id", "deployment_id"},
               {"source_owner_id", "source_owner_id"},
               {"destination_owner_id", "destination_owner_id"},
               {"source_epoch", "authority_epoch"},
               {"retirement_revision", "revision"},
               {"source_maintenance_revision", "maintenance_revision"}
             ],
             fn {left, right} -> review[left] == source[right] end
           ),
         {:ok, derived} <- RecoveryDomains.derive(db, :quarantine),
         true <- derived.document == document and Map.delete(decoded, :version) == derived,
         true <-
           Enum.all?(
             [:domain_digest, :domain_count, :counter_state, :counter_state_digest],
             fn field -> decoded[field] == review[Atom.to_string(field)] end
           ),
         {:ok, active} <- MaintenanceWriter.require_active(db),
         true <- active == source["maintenance_revision"],
         {:ok,
          [[generation, active_rule, pending, held, principals, transitions, maintenance_rows]]} <-
           query(db, """
           SELECT
             (SELECT value FROM meta WHERE key='rule_generation'),
             (SELECT value FROM meta WHERE key='active_rule_admission'),
             (SELECT COUNT(*) FROM request_execution WHERE state IN ('queued','claimed','dispatching','protocol_accepted')),
             (SELECT COUNT(*) FROM request_outbox),
             (SELECT COUNT(*) FROM principals),
             (SELECT COUNT(*) FROM controller_retirements),
             (SELECT COUNT(*) FROM host_maintenance_operations)
           """),
         true <-
           generation == review["source_rule_generation"] and active_rule == 0 and pending == 0 and
             held == 0 and principals < 64 and maintenance_rows < 1_024,
         {:ok, [[version]]} <- query(db, "PRAGMA user_version"),
         {:ok, accepted} <- acceptance_count(db, version),
         true <-
           transitions + accepted < 64 and source["revision"] <= @maximum - 3 and
             source["authority_epoch"] < @maximum and generation < @maximum,
         true <-
           decoded.source_counts.qualified_profile_heads <= 64 and
             decoded.source_counts.override_lease_rows <= 64,
         {:ok, hash} <- Base.decode16(review["credential_hash"], case: :lower),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM principals WHERE principal_id=? OR credential_hash=?",
             [review["principal_id"], hash]
           ),
         {:ok, runtime} <- ProfileBasis.runtime_digest(),
         true <- runtime == review["runtime_digest"] do
      {:ok, source}
    else
      false -> {:error, :transfer_review_changed}
      error -> error
    end
  end

  defp acceptance_count(_db, 21), do: {:ok, 0}

  defp acceptance_count(db, version) when version in [22, 23, 24, 25, 26] do
    with {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM controller_acceptances"),
         do: {:ok, count}
  end

  defp withdraw(db, counts) do
    Enum.reduce_while(@counts, {:ok, %{}}, fn {receipt_key, count_key, statement},
                                              {:ok, changed} ->
      expected = counts[count_key]

      case query(db, statement) do
        {:ok, []} ->
          case query(db, "SELECT changes()") do
            {:ok, [[^expected]]} ->
              {:cont, {:ok, Map.put(changed, receipt_key, expected)}}

            _ ->
              {:halt, {:error, :transfer_source_counts_changed}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp receipt(input, review, isolation, fence, principal, final, generation, changed) do
    review
    |> Map.take(
      ~w(source_maintenance_revision source_rule_generation deployment_id source_owner_id domain_digest domain_count counter_state counter_state_digest)
    )
    |> Map.merge(input)
    |> Map.merge(changed)
    |> Map.merge(%{
      "authority_epoch" => input["source_epoch"] + 1,
      "rule_generation" => generation,
      "fence_revision" => fence,
      "principal_revision" => principal,
      "revision" => final,
      "isolation_decision_digest" => isolation.decision_digest
    })
  end

  defp size(db) do
    with {:ok, [[pages]]} <- query(db, "PRAGMA page_count"),
         {:ok, [[bytes]]} <- query(db, "PRAGMA page_size"),
         true <- pages * bytes <= 33_554_432,
         do: :ok,
         else: (_ -> {:error, :transfer_snapshot_capacity})
  end

  defp postconditions(db, review, receipt) do
    with {:ok, [[0]]} <-
           query(
             db,
             "SELECT (SELECT COUNT(*) FROM principals WHERE principal_id!=? AND status!='revoked')+(SELECT COUNT(*) FROM profile_qualifications WHERE status!='revoked')+(SELECT COUNT(*) FROM observation_current)+(SELECT COUNT(*) FROM principal_targets)+(SELECT COUNT(*) FROM source_epoch_grants)+(SELECT COUNT(*) FROM operator_override_leases)+(SELECT COUNT(*) FROM meta WHERE key='restore_quarantine')",
             [receipt["principal_id"]]
           ),
         {:ok, [[hash, permissions, "active"]]} <-
           query(
             db,
             "SELECT credential_hash,permissions,status FROM principals WHERE principal_id=?",
             [receipt["principal_id"]]
           ),
         true <-
           is_binary(hash) and Base.encode16(hash, case: :lower) == review["credential_hash"] and
             permissions == review["permissions_document"],
         {:ok, [[epoch, revision, generation, maintenance, 0]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='rule_generation'),(SELECT value FROM meta WHERE key='maintenance_revision'),(SELECT value FROM meta WHERE key='active_rule_admission')"
           ),
         true <-
           [epoch, revision, generation, maintenance] ==
             Enum.map(~w(authority_epoch revision rule_generation revision), &receipt[&1]),
         {:ok, %{state: "active", owner_id: owner, retirement_revision: head}} <-
           ControllerWriter.identity(db),
         true <- owner == receipt["destination_owner_id"] and head == receipt["revision"] do
      :ok
    else
      _ -> {:error, :transfer_retained_state_changed}
    end
  end

  defp guard(fun) do
    case fun.() do
      {:ok, %{package_bytes: package} = value, policy}
      when is_binary(package) and is_binary(policy) ->
        {:ok, value, policy}

      {:error, _} = error ->
        error

      _ ->
        {:error, :transfer_context_unavailable}
    end
  rescue
    _ -> {:error, :transfer_context_unavailable}
  catch
    _, _ -> {:error, :transfer_context_unavailable}
  end
end
