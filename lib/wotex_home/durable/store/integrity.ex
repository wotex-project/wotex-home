defmodule WotexHome.Durable.Store.Integrity do
  @moduledoc """
  Semantic integrity gates shared by startup migrations and backup verification.

  These checks read only the borrowed connection. They never open a database,
  migrate rows, commit transactions or interpret a retained receipt as effect
  authority. Store fails startup on inconsistent state before serving calls.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Store.{InvariantWriter, MaintenanceWriter, ObservationCodec, RuleWriter}
  alias WotexHome.Durable.Store.ProfileWriter
  alias WotexHome.Rules.{CandidateArtifact, OverrideLease}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807
  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64

  def validate_schema_version(1, db), do: validate_observation_schema(db)
  def validate_schema_version(2, db), do: validate_request_schema(db)
  def validate_schema_version(4, db), do: validate_schema_v4(db)
  def validate_schema_version(5, db), do: validate_schema_v5(db)
  def validate_schema_version(6, db), do: validate_schema_v6(db)
  def validate_schema_version(7, db), do: validate_schema_v7(db)
  def validate_schema_version(8, db), do: validate_schema_v8(db)
  def validate_schema_version(9, db), do: validate_schema_v9(db)
  def validate_schema_version(10, db), do: validate_schema_v10(db)
  def validate_schema_version(11, db), do: validate_schema_v11(db)
  def validate_schema_version(12, db), do: validate_schema_v12(db)
  def validate_schema_version(13, db), do: validate_schema_v13(db)
  def validate_schema_version(14, db), do: validate_schema_v14(db)
  def validate_schema_version(15, db), do: validate_schema_v15(db)
  def validate_schema_version(16, db), do: validate_schema_v16(db)
  def validate_schema_version(17, db), do: validate_schema_v17(db)
  def validate_schema_version(18, db), do: validate_schema(db)
  def validate_schema_version(19, db), do: validate_schema_v19(db)
  def validate_schema_version(20, db), do: validate_schema_v20(db)
  def validate_schema_version(21, db), do: validate_schema_v21(db)
  def validate_schema_version(22, db), do: validate_schema_v22(db)
  def validate_schema_version(23, db), do: validate_schema_v23(db)
  def validate_schema_version(24, db), do: validate_schema_v24(db)
  def validate_schema_version(25, db), do: validate_schema_v25(db)

  @doc "Read-only Store consistency check for an already version-matched SQLite snapshot."
  @spec validate_snapshot(term()) :: :ok | {:error, atom() | tuple()}
  def validate_snapshot(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[4]]} -> validate_schema_v4(db)
      {:ok, [[5]]} -> validate_schema_v5(db)
      {:ok, [[6]]} -> validate_schema_v6(db)
      {:ok, [[7]]} -> validate_schema_v7(db)
      {:ok, [[8]]} -> validate_schema_v8(db)
      {:ok, [[9]]} -> validate_schema_v9(db)
      {:ok, [[10]]} -> validate_schema_v10(db)
      {:ok, [[11]]} -> validate_schema_v11(db)
      {:ok, [[12]]} -> validate_schema_v12(db)
      {:ok, [[13]]} -> validate_schema_v13(db)
      {:ok, [[14]]} -> validate_schema_v14(db)
      {:ok, [[15]]} -> validate_schema_v15(db)
      {:ok, [[16]]} -> validate_schema_v16(db)
      {:ok, [[17]]} -> validate_schema_v17(db)
      {:ok, [[18]]} -> validate_schema(db)
      {:ok, [[19]]} -> validate_schema_v19(db)
      {:ok, [[20]]} -> validate_schema_v20(db)
      {:ok, [[21]]} -> validate_schema_v21(db)
      {:ok, [[22]]} -> validate_schema_v22(db)
      {:ok, [[23]]} -> validate_schema_v23(db)
      {:ok, [[24]]} -> validate_schema_v24(db)
      {:ok, [[25]]} -> validate_schema_v25(db)
      _ -> {:error, :unsupported_schema_version}
    end
  end

  defp validate_schema(db) do
    with :ok <- validate_schema_v17(db), :ok <- MaintenanceWriter.validate(db), do: :ok
  end

  defp validate_schema_v20(db) do
    with :ok <- validate_schema_v19(db),
         :ok <- WotexHome.Durable.Store.QualificationHistory.validate(db),
         do: :ok
  end

  defp validate_schema_v21(db) do
    with :ok <- validate_schema_v20(db),
         :ok <- WotexHome.Durable.Store.ControllerWriter.validate(db),
         do: :ok
  end

  defp validate_schema_v22(db) do
    with :ok <- validate_schema_v21(db),
         :ok <- WotexHome.Durable.Store.NativePrincipalWriter.validate(db),
         do: :ok
  end

  defp validate_schema_v23(db) do
    with :ok <- validate_schema_v22(db),
         :ok <- WotexHome.Durable.Store.NativeTargetHistory.validate(db),
         do: :ok
  end

  defp validate_schema_v24(db) do
    with :ok <- validate_schema_v23(db),
         :ok <- WotexHome.Durable.Store.ScheduleWriter.validate(db),
         do: :ok
  end

  defp validate_schema_v25(db) do
    with :ok <- validate_schema_v24(db),
         :ok <- WotexHome.Durable.Store.ScheduleLifecycle.validate(db),
         do: :ok
  end

  defp validate_schema_v19(db) do
    with :ok <- validate_schema(db), :ok <- ProfileWriter.validate(db), do: :ok
  end

  defp validate_schema_v17(db) do
    with :ok <- validate_schema_v16(db), :ok <- RuleWriter.validate(db), do: :ok
  end

  defp validate_schema_v16(db) do
    with :ok <- validate_schema_v15(db),
         :ok <- InvariantWriter.validate(db) do
      :ok
    end
  end

  defp validate_schema_v15(db) do
    with :ok <- validate_schema_v14(db),
         :ok <- validate_observation_clocks(db) do
      :ok
    end
  end

  defp validate_schema_v14(db) do
    with :ok <- validate_schema_v13(db),
         :ok <- validate_causal_roots(db) do
      :ok
    end
  end

  defp validate_observation_clocks(db) do
    with {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM journal WHERE received_store_boot_epoch IS NOT NULL AND (revision < 1 OR event_type != 'observation')"
           ),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM (
             SELECT received_store_boot_epoch AS epoch, received_store_monotonic_ms AS ms FROM journal
             UNION ALL
             SELECT received_store_boot_epoch, received_store_monotonic_ms FROM observation_current
           ) WHERE (epoch IS NULL AND ms IS NOT NULL) OR
             (epoch IS NOT NULL AND (typeof(epoch) != 'text' OR typeof(ms) != 'integer' OR ms < 0))
           """),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM observation_current c LEFT JOIN journal j ON j.revision=c.revision
           WHERE j.revision IS NULL OR j.event_type != 'observation'
             OR c.received_store_boot_epoch IS NOT j.received_store_boot_epoch
             OR c.received_store_monotonic_ms IS NOT j.received_store_monotonic_ms
             OR c.thing_id IS NOT j.thing_id OR c.capability_key IS NOT j.capability_key
             OR c.profile_ref IS NOT j.profile_ref OR c.evidence_ref IS NOT j.evidence_ref
             OR c.source_epoch IS NOT j.source_epoch OR c.source_sequence IS NOT j.source_sequence
             OR c.boot_epoch IS NOT j.boot_epoch OR c.source_time_utc_ms IS NOT j.source_time_utc_ms
             OR c.received_time_utc_ms IS NOT j.received_time_utc_ms
             OR c.received_monotonic_ms IS NOT j.received_monotonic_ms
             OR c.quality IS NOT j.quality OR c.trust IS NOT j.trust
             OR c.value_kind IS NOT j.value_kind OR c.value_a IS NOT j.value_a OR c.value_b IS NOT j.value_b
           """),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM (
             SELECT received_store_monotonic_ms AS ms,
               LAG(received_store_monotonic_ms) OVER
                 (PARTITION BY received_store_boot_epoch ORDER BY revision) AS previous_ms
             FROM journal WHERE received_store_boot_epoch IS NOT NULL
           ) WHERE ms < previous_ms
           """),
         :ok <- validate_observation_epochs(db, 0) do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_observation_epochs(db, after_revision) do
    case query(
           db,
           "SELECT revision, received_store_boot_epoch, thing_id, capability_key, profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch, source_time_utc_ms, received_time_utc_ms, received_monotonic_ms, quality, trust, value_kind, value_a, value_b FROM journal WHERE revision > ? AND received_store_boot_epoch IS NOT NULL ORDER BY revision LIMIT 100",
           [after_revision]
         ) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        if Enum.all?(rows, fn [revision, epoch, id, key | fields] ->
             valid_stored_integer?(revision) and Id.valid?(epoch) and
               Enum.all?(Enum.take(fields, 2), &Id.valid?/1) and
               match?(
                 {:ok, _, ^revision},
                 ObservationCodec.decode_current(id, key, fields ++ [revision])
               )
           end),
           do: validate_observation_epochs(db, rows |> List.last() |> hd()),
           else: {:error, {:schema_inconsistent, :invalid_observation_clock}}

      other ->
        {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v13(db) do
    with :ok <- validate_schema_v12(db),
         :ok <- validate_handoff_clocks(db) do
      :ok
    end
  end

  defp validate_causal_roots(db) do
    with {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM request_receipts p
           LEFT JOIN request_causal_roots r USING (principal_id, authority_epoch, operation_id)
           WHERE r.operation_id IS NULL
           """),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM request_causal_roots r
           LEFT JOIN request_receipts p USING (principal_id, authority_epoch, operation_id)
           LEFT JOIN request_execution e USING (principal_id, authority_epoch, operation_id)
           LEFT JOIN request_journal c ON c.revision=r.created_revision
             AND c.principal_id=r.principal_id AND c.authority_epoch=r.authority_epoch
             AND c.operation_id=r.operation_id AND c.disposition IN ('held', 'rejected')
           LEFT JOIN request_journal q ON q.revision=r.reservation_revision
             AND q.principal_id=r.principal_id AND q.authority_epoch=r.authority_epoch
             AND q.operation_id=r.operation_id AND q.disposition='queued' AND q.reason IS NULL
           WHERE p.operation_id IS NULL
             OR typeof(r.origin) != 'text' OR r.origin NOT IN ('explicit_request', 'legacy_request')
             OR typeof(r.reserved_effects) != 'integer' OR r.reserved_effects NOT IN (0, 1)
             OR (r.origin='explicit_request' AND
               (typeof(r.created_revision) != 'integer' OR r.created_revision < 1
                OR r.created_revision > p.revision OR c.revision IS NULL
                OR r.created_revision != (SELECT MIN(j.revision) FROM request_journal j
                  WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
                    AND j.operation_id=r.operation_id)))
             OR (r.origin='legacy_request' AND r.created_revision IS NOT NULL)
             OR (r.reserved_effects=0 AND
               (r.reservation_revision IS NOT NULL OR e.operation_id IS NOT NULL
                OR EXISTS (SELECT 1 FROM request_journal j
                  WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
                    AND j.operation_id=r.operation_id AND j.disposition='queued')))
             OR (r.reserved_effects=1 AND r.reservation_revision IS NULL
               AND r.origin != 'legacy_request')
             OR (r.reservation_revision IS NOT NULL AND
               (typeof(r.reservation_revision) != 'integer' OR r.reservation_revision < 1
                OR r.reservation_revision > p.revision OR q.revision IS NULL
                OR r.created_revision > r.reservation_revision
                OR r.reservation_revision != (SELECT MIN(j.revision) FROM request_journal j
                  WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
                    AND j.operation_id=r.operation_id AND j.disposition='queued')
                OR 1 != (SELECT COUNT(*) FROM request_journal j
                  WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
                    AND j.operation_id=r.operation_id AND j.disposition='queued')))
             OR (e.operation_id IS NOT NULL AND
               (r.reserved_effects != 1 OR
                (r.reservation_revision IS NOT NULL AND r.reservation_revision != e.admission_revision)))
           """),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v12(db) do
    with :ok <- validate_schema_v11(db),
         :ok <- validate_rule_candidates(db) do
      :ok
    end
  end

  defp validate_handoff_clocks(db) do
    with {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM request_execution e
           LEFT JOIN request_journal j ON j.revision=e.handoff_revision
             AND j.principal_id=e.principal_id AND j.authority_epoch=e.authority_epoch
             AND j.operation_id=e.operation_id AND j.disposition='dispatching' AND j.reason IS NULL
           WHERE (e.handoff_store_boot_epoch IS NULL AND e.handoff_store_monotonic_ms IS NOT NULL)
             OR (e.handoff_store_boot_epoch IS NOT NULL AND
               (typeof(e.handoff_store_boot_epoch) != 'text'
                OR typeof(e.handoff_store_monotonic_ms) != 'integer'
                OR e.handoff_store_monotonic_ms < 0 OR j.revision IS NULL))
           """),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM (
             SELECT handoff_store_monotonic_ms AS ms,
               LAG(handoff_store_monotonic_ms) OVER
                 (PARTITION BY handoff_store_boot_epoch ORDER BY handoff_revision) AS previous_ms
             FROM request_execution WHERE handoff_store_boot_epoch IS NOT NULL
           ) WHERE ms < previous_ms
           """),
         :ok <- validate_handoff_epochs(db, 0) do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  # Bound each result page; don't load an entire retained execution history.
  defp validate_handoff_epochs(db, after_revision) do
    case query(
           db,
           "SELECT handoff_revision, handoff_store_boot_epoch FROM request_execution WHERE handoff_store_boot_epoch IS NOT NULL AND handoff_revision > ? ORDER BY handoff_revision LIMIT 256",
           [after_revision]
         ) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        if Enum.all?(rows, fn [revision, epoch] ->
             valid_stored_integer?(revision) and revision > after_revision and Id.valid?(epoch)
           end) do
          [last_revision, _epoch] = List.last(rows)
          validate_handoff_epochs(db, last_revision)
        else
          {:error, :invalid_handoff_epoch}
        end

      error ->
        error
    end
  end

  defp validate_rule_candidates(db) do
    with {:ok, [[store_revision, store_epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT c.principal_id, c.authority_epoch, c.operation_id, c.expected_revision, c.rules_document, c.artifact_document, c.artifact_digest, c.revision, a.revision, p.principal_id FROM rule_candidate_reviews c LEFT JOIN authority_journal a ON a.revision=c.revision AND a.event_type='rule_candidate_reviewed' AND a.entity_id=c.operation_id LEFT JOIN principals p ON p.principal_id=c.principal_id ORDER BY c.revision LIMIT 1025"
           ),
         true <- length(rows) <= 1_024,
         true <-
           Enum.all?(rows, fn
             [
               principal,
               epoch,
               operation,
               expected,
               rules,
               document,
               digest,
               revision,
               event,
               owner
             ] ->
               Id.valid?(principal) and owner == principal and Id.valid?(operation) and
                 valid_stored_integer?(epoch) and epoch >= 1 and epoch <= store_epoch and
                 valid_stored_integer?(expected) and valid_stored_integer?(revision) and
                 revision == expected + 1 and revision <= store_revision and event == revision and
                 valid_candidate_content?(rules, document, digest, expected)

             _ ->
               false
           end),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp valid_candidate_content?(rules, document, digest, expected) when is_binary(document) do
    case CandidateArtifact.decode(document) do
      {:ok, artifact} ->
        CandidateArtifact.digest(document) == digest and artifact.rules_document == rules and
          Enum.all?(artifact.resources, &(&1["resource_revision"] <= expected))

      _ ->
        false
    end
  end

  defp valid_candidate_content?(_rules, _document, _digest, _expected), do: false

  defp validate_schema_v11(db) do
    with :ok <- validate_schema_v10(db),
         :ok <- validate_override_operations(db) do
      :ok
    end
  end

  defp validate_schema_v10(db) do
    with :ok <- validate_schema_v9(db),
         :ok <- validate_override_leases(db) do
      :ok
    end
  end

  defp validate_schema_v9(db) do
    with :ok <- validate_schema_v8(db),
         :ok <- validate_rule_generation(db) do
      :ok
    end
  end

  defp validate_schema_v8(db) do
    with :ok <- validate_schema_v7(db),
         :ok <- validate_profile_qualifications(db),
         :ok <- validate_unresolved_effect_domains(db) do
      :ok
    end
  end

  defp validate_override_leases(db) do
    with {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, rows} <-
           query(
             db,
             "SELECT l.target_id, l.operator_id, l.authority_epoch, l.boot_epoch, l.start_ms, l.expires_ms, l.basis_revision, l.revision, a.revision, t.resource_revision, p.principal_id FROM operator_override_leases l LEFT JOIN authority_journal a ON a.revision = l.revision AND a.event_type = 'override_lease_issued' AND a.entity_id = l.target_id LEFT JOIN enrolled_things t ON t.thing_id = l.target_id LEFT JOIN principals p ON p.principal_id = l.operator_id ORDER BY l.target_id LIMIT 4097"
           ),
         true <- length(rows) <= 4_096,
         true <-
           Enum.all?(rows, fn
             [
               target_id,
               operator_id,
               epoch,
               boot_epoch,
               start_ms,
               expires_ms,
               basis_revision,
               revision,
               journal_revision,
               resource_revision,
               principal_id
             ] ->
               principal_id == operator_id and Id.valid?(boot_epoch) and
                 valid_stored_integer?(revision) and revision >= 1 and
                 revision <= store_revision and journal_revision == revision and
                 valid_stored_integer?(resource_revision) and
                 basis_revision <= resource_revision and
                 match?(
                   {:ok, _},
                   OverrideLease.new(%{
                     "target_id" => target_id,
                     "operator_id" => operator_id,
                     "authority_epoch" => epoch,
                     "start_ms" => start_ms,
                     "expires_ms" => expires_ms,
                     "basis_revision" => basis_revision
                   })
                 )

             _ ->
               false
           end),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_override_operations(db) do
    with {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, rows} <-
           query(
             db,
             "SELECT o.operator_id, o.authority_epoch, o.operation_id, o.target_id, o.basis_revision, o.duration_ms, o.start_ms, o.expires_ms, o.issue_revision, o.revoke_revision, i.revision, r.revision, t.resource_revision, p.principal_id FROM operator_override_operations o LEFT JOIN authority_journal i ON i.revision = o.issue_revision AND i.event_type = 'override_lease_issued' AND i.entity_id = o.target_id LEFT JOIN authority_journal r ON r.revision = o.revoke_revision AND r.event_type = 'override_lease_revoked' AND r.entity_id = o.target_id LEFT JOIN enrolled_things t ON t.thing_id = o.target_id LEFT JOIN principals p ON p.principal_id = o.operator_id ORDER BY o.issue_revision LIMIT 65537"
           ),
         true <- length(rows) <= 65_536,
         true <-
           Enum.all?(rows, fn
             [
               operator_id,
               epoch,
               operation_id,
               target_id,
               basis_revision,
               duration_ms,
               start_ms,
               expires_ms,
               issue_revision,
               revoke_revision,
               issue_event,
               revoke_event,
               resource_revision,
               principal_id
             ] ->
               Id.valid?(operator_id) and Id.valid?(operation_id) and Id.valid?(target_id) and
                 principal_id == operator_id and valid_stored_integer?(epoch) and epoch >= 1 and
                 valid_stored_integer?(basis_revision) and
                 valid_stored_integer?(resource_revision) and
                 basis_revision <= resource_revision and
                 is_integer(duration_ms) and duration_ms in 1..86_400_000 and
                 valid_stored_integer?(start_ms) and valid_stored_integer?(expires_ms) and
                 expires_ms - start_ms == duration_ms and
                 valid_stored_integer?(issue_revision) and issue_revision >= 1 and
                 issue_revision <= store_revision and issue_event == issue_revision and
                 ((is_nil(revoke_revision) and is_nil(revoke_event)) or
                    (valid_stored_integer?(revoke_revision) and
                       revoke_revision > issue_revision and revoke_revision <= store_revision and
                       revoke_event == revoke_revision))

             _ ->
               false
           end),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_rule_generation(db) do
    with {:ok, [[generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         {:ok, [[fence_count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced', 'rule_policy_activated')"
           ),
         {:ok, [[stale_execution]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_execution WHERE rule_generation > ? OR (state IN ('queued', 'claimed') AND rule_generation != ?)",
             [generation, generation]
           ),
         true <-
           is_integer(generation) and generation >= 0 and generation <= @max_i64 and
             generation == fence_count and stale_execution == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_unresolved_effect_domains(db) do
    case query(
           db,
           "SELECT COUNT(*) FROM (SELECT effect_domain FROM request_execution WHERE state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted', 'outcome_unknown') GROUP BY effect_domain HAVING COUNT(*) > 1)"
         ) do
      {:ok, [[0]]} -> :ok
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v7(db) do
    with :ok <- validate_schema_v5(db),
         :ok <- validate_enrollment_reviews(db) do
      :ok
    end
  end

  defp validate_profile_qualifications(db) do
    profile_mismatch =
      if profile_history_mode?(db),
        do:
          "(q.profile_ref != t.profile_ref AND NOT (q.status='revoked' AND EXISTS (SELECT 1 FROM profile_selection_history s WHERE s.target_id=q.thing_id AND s.revision>q.revision)))",
        else: "q.profile_ref != t.profile_ref"

    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[invalid]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_qualifications q LEFT JOIN enrollment_bindings b ON b.thing_id = q.thing_id LEFT JOIN enrolled_things t ON t.thing_id = q.thing_id LEFT JOIN authority_journal a ON a.revision = q.revision AND a.event_type = 'profile_qualified' AND a.entity_id = q.thing_id WHERE b.thing_id IS NULL OR t.thing_id IS NULL OR a.revision IS NULL OR #{profile_mismatch} OR q.resource_revision > t.resource_revision OR q.revision < 1 OR q.revision > ? OR length(q.identity_digest) != 64 OR q.identity_digest GLOB '*[^0-9a-f]*' OR length(q.basis_digest) != 64 OR q.basis_digest GLOB '*[^0-9a-f]*' OR length(q.registry_digest) != 64 OR q.registry_digest GLOB '*[^0-9a-f]*' OR length(q.runtime_digest) != 64 OR q.runtime_digest GLOB '*[^0-9a-f]*' OR length(q.evidence_ref) NOT BETWEEN 1 AND 128",
             [revision]
           ),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <- invalid == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v6(db) do
    with :ok <- validate_schema_v5(db),
         :ok <- validate_enrollment_bindings(db) do
      :ok
    end
  end

  defp validate_enrollment_reviews(db) do
    succession? =
      query(db, "PRAGMA user_version") in [
        {:ok, [[22]]},
        {:ok, [[23]]},
        {:ok, [[24]]},
        {:ok, [[25]]}
      ]

    history_mismatch =
      if succession?,
        do: "(b.profile_ref != h.profile_ref OR b.qualification_ref != h.qualification_ref)",
        else:
          "(b.profile_ref != h.profile_ref OR b.qualification_ref != h.qualification_ref OR b.operator_id != h.operator_id)"

    history_mismatch =
      if profile_history_mode?(db),
        do:
          "(" <>
            history_mismatch <>
            " AND NOT EXISTS (SELECT 1 FROM profile_selection_history s WHERE s.target_id=h.thing_id AND h.revision<s.binding_revision))",
        else: history_mismatch

    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[invalid_bindings]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_bindings b LEFT JOIN enrolled_things t ON t.thing_id = b.thing_id LEFT JOIN principals p ON p.principal_id = b.operator_id LEFT JOIN enrollment_review_history h ON h.revision = b.revision AND h.thing_id = b.thing_id LEFT JOIN authority_journal a ON a.revision = b.revision AND a.entity_id = b.thing_id WHERE t.thing_id IS NULL OR p.principal_id IS NULL OR h.revision IS NULL OR a.revision IS NULL OR a.event_type NOT IN ('thing_enrolled_reviewed', 'thing_enrollment_rereviewed') OR b.profile_ref != t.profile_ref OR b.stable_id != h.stable_id OR b.identity_digest != h.identity_digest OR b.digest_version != h.digest_version OR b.candidate_ref != h.candidate_ref OR b.review_ref != h.review_ref OR b.method != h.method OR b.qualification_ref != h.qualification_ref OR b.operator_id != h.operator_id OR b.profile_ref != h.profile_ref OR b.revision < 1 OR b.revision > ?",
             [revision]
           ),
         {:ok, [[invalid_history]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_review_history h LEFT JOIN enrollment_bindings b ON b.thing_id = h.thing_id LEFT JOIN authority_journal a ON a.revision = h.revision AND a.entity_id = h.thing_id WHERE b.thing_id IS NULL OR a.revision IS NULL OR b.stable_id != h.stable_id OR #{history_mismatch} OR a.event_type NOT IN ('thing_enrolled_reviewed', 'thing_enrollment_rereviewed') OR h.revision < 1 OR h.revision > ? OR length(h.identity_digest) != 64 OR h.identity_digest GLOB '*[^0-9a-f]*' OR (h.digest_version = 2 AND (h.manufacturer IS NULL OR h.model IS NULL OR h.firmware IS NULL)) OR (h.digest_version = 1 AND (h.manufacturer IS NOT NULL OR h.model IS NOT NULL OR h.firmware IS NOT NULL))",
             [revision]
           ),
         {:ok, [[missing_initial]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_bindings b WHERE NOT EXISTS (SELECT 1 FROM enrollment_review_history h JOIN authority_journal a ON a.revision = h.revision AND a.entity_id = h.thing_id AND a.event_type = 'thing_enrolled_reviewed' WHERE h.thing_id = b.thing_id)"
           ),
         {:ok, [[overfull_history]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM (SELECT thing_id FROM enrollment_review_history GROUP BY thing_id HAVING COUNT(*) > 32)"
           ),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <-
           invalid_bindings == 0 and invalid_history == 0 and missing_initial == 0 and
             overfull_history == 0,
         :ok <- WotexHome.Durable.Store.EnrollmentSuccession.validate(db) do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp profile_history_mode?(db),
    do:
      query(db, "PRAGMA user_version") in [
        {:ok, [[20]]},
        {:ok, [[21]]},
        {:ok, [[22]]},
        {:ok, [[23]]},
        {:ok, [[24]]},
        {:ok, [[25]]}
      ]

  defp validate_schema_v5(db) do
    with :ok <- validate_schema_v4(db),
         :ok <- validate_execution_schema(db) do
      :ok
    end
  end

  defp validate_enrollment_bindings(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[invalid]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_bindings b LEFT JOIN enrolled_things t ON t.thing_id = b.thing_id LEFT JOIN principals p ON p.principal_id = b.operator_id LEFT JOIN authority_journal a ON a.revision = b.revision AND a.event_type = 'thing_enrolled_reviewed' AND a.entity_id = b.thing_id WHERE t.thing_id IS NULL OR p.principal_id IS NULL OR a.revision IS NULL OR b.profile_ref != t.profile_ref OR b.revision < 1 OR b.revision > ? OR length(b.stable_id) NOT BETWEEN 1 AND 128 OR length(b.candidate_ref) NOT BETWEEN 1 AND 128 OR length(b.review_ref) NOT BETWEEN 1 AND 128 OR length(b.qualification_ref) NOT BETWEEN 1 AND 128 OR length(b.identity_digest) != 64 OR b.identity_digest GLOB '*[^0-9a-f]*'",
             [revision]
           ),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <- invalid == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v4(db) do
    with :ok <- validate_observation_schema_tables(db),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[observation_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM journal"),
         {:ok, [[request_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_journal"),
         {:ok, [[authority_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM authority_journal"),
         {:ok, [[latest_receipt]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_receipts"),
         {:ok, [[latest_current]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current"),
         {:ok, [[_held_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox"),
         {:ok, [[orphan_held]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_receipts r WHERE r.disposition = 'held' AND NOT EXISTS (SELECT 1 FROM request_outbox o WHERE o.principal_id = r.principal_id AND o.authority_epoch = r.authority_epoch AND o.operation_id = r.operation_id AND o.state = 'held')"
           ),
         {:ok, [[orphan_outbox]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE r.disposition != 'held'"
           ),
         {:ok, [[_enrolled_count]]} <- query(db, "SELECT COUNT(*) FROM enrolled_things"),
         {:ok, [[_principal_count]]} <- query(db, "SELECT COUNT(*) FROM principals"),
         {:ok, [[_source_epoch_grant_count]]} <-
           query(db, "SELECT COUNT(*) FROM source_epoch_grants"),
         {:ok, [[invalid_source_epoch_grants]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM source_epoch_grants g LEFT JOIN enrolled_things t ON t.thing_id = g.thing_id WHERE g.old_epoch = g.new_epoch OR g.current_revision < 0 OR g.grant_revision <= g.current_revision OR g.grant_revision > ? OR t.status IS NULL OR t.status != 'active'",
             [revision]
           ),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <-
           is_integer(epoch) and epoch >= 1 and is_integer(revision) and
             revision == Enum.max([observation_revision, request_revision, authority_revision]) and
             latest_receipt <= revision and latest_current <= revision and orphan_held == 0 and
             orphan_outbox == 0 and invalid_source_epoch_grants == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_execution_schema(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[orphan_receipts]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_receipts r WHERE r.disposition NOT IN ('held', 'rejected') AND NOT EXISTS (SELECT 1 FROM request_execution e WHERE e.principal_id = r.principal_id AND e.authority_epoch = r.authority_epoch AND e.operation_id = r.operation_id)"
           ),
         {:ok, [[invalid_execution]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_execution e LEFT JOIN request_receipts r ON r.principal_id = e.principal_id AND r.authority_epoch = e.authority_epoch AND r.operation_id = e.operation_id LEFT JOIN request_outbox o ON o.principal_id = e.principal_id AND o.authority_epoch = e.authority_epoch AND o.operation_id = e.operation_id WHERE r.disposition IS NULL OR r.disposition != e.state OR r.target_id != e.target_id OR r.profile_ref != e.profile_ref OR e.effect_domain != e.target_id OR e.revision != r.revision OR e.revision > ? OR e.baseline_revision > e.revision OR o.state IS NOT NULL OR (e.state = 'queued' AND (e.claim_token IS NOT NULL OR e.claim_boot_epoch IS NOT NULL OR e.handoff_revision IS NOT NULL)) OR (e.state = 'claimed' AND (typeof(e.claim_token) != 'blob' OR length(e.claim_token) != 32 OR e.claim_boot_epoch IS NULL OR e.claim_boot_epoch = '' OR e.handoff_revision IS NOT NULL OR e.attempts < 1)) OR (e.state IN ('dispatching', 'protocol_accepted', 'observed', 'contradicted', 'failed', 'outcome_unknown') AND (typeof(e.claim_token) != 'blob' OR length(e.claim_token) != 32 OR e.claim_boot_epoch IS NULL OR e.claim_boot_epoch = '' OR e.handoff_revision IS NULL OR e.handoff_revision < 1 OR e.handoff_revision > e.revision OR e.attempts < 1))",
             [revision]
           ),
         true <- orphan_receipts == 0 and invalid_execution == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_request_schema(db) do
    with :ok <- validate_observation_schema_tables(db),
         {:ok, [[_receipt_count]]} <- query(db, "SELECT COUNT(*) FROM request_receipts"),
         {:ok, [[_outbox_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox"),
         {:ok, [[_request_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_journal") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_observation_schema(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[latest_event]]} <- query(db, "SELECT COALESCE(MAX(revision), 0) FROM journal"),
         {:ok, [[latest_current]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current"),
         true <- is_integer(revision) and revision == latest_event and latest_current <= revision do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_observation_schema_tables(db) do
    case query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current") do
      {:ok, [[_latest_current]]} -> :ok
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  @doc "Runs SQLite's bounded storage integrity check before serving authority."
  @spec check_sqlite(term()) :: :ok | {:error, term()}
  def check_sqlite(db) do
    case query(db, "PRAGMA quick_check") do
      {:ok, [["ok"]]} -> :ok
      other -> {:error, {:integrity_failed, other}}
    end
  end
end
