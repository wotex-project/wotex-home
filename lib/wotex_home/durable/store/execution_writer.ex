defmodule WotexHome.Durable.Store.ExecutionWriter do
  @moduledoc """
  Direct LIFX receipt and execution transactions under the single Store writer.

  This collaborator receives a borrowed connection and immutable guard basis.
  It owns no process, monitor, credential issuance, clock or device transport.
  Store alone wraps these functions in transactions and checks the live caller
  before any claim-token transition. Handoff records uncertainty, never a send.
  """

  alias WotexHome.{Id, Mutation, Policy}
  alias WotexHome.Durable.{Receipt, Registry}

  alias WotexHome.Durable.Store.{
    AttemptGuard,
    CausalLedger,
    InvariantWriter,
    MaintenanceWriter,
    ObservationWriter,
    ProfilePins,
    RuleWriter
  }

  alias WotexHome.Lifx.{ColorPlan, DirectPowerLimits, DirectPowerSafety, PowerClaim}
  alias WotexHome.Policy.Context
  alias WotexHome.Semantics.{Observation, Thing, Value}

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  import WotexHome.Durable.Store.Access,
    only: [
      authenticate: 2,
      usable_thing: 2,
      allowed_targets: 2,
      active_principal_permissions: 2
    ]

  import WotexHome.Durable.Store.Journal,
    only: [next_revision: 1, request_event: 7, authority_event: 4]

  import WotexHome.Durable.Store.ObservationCodec, only: [decode_current: 3, decode_value: 3]
  import WotexHome.Durable.Store.QualificationWriter, only: [qualified_power_profile: 5]

  import WotexHome.Durable.Store.RequestInvalidator,
    only: [
      reject_held: 5,
      reject_held_batch: 3,
      invalidate_execution_for: 3,
      invalidate_execution_row: 6,
      pending_execution_rows: 2
    ]

  import WotexHome.Durable.Store.RequestLedger, only: [select_request: 4, decode_receipt: 4]

  @max_i64 9_223_372_036_854_775_807
  @final_policy ~w(unauthorized principal_unavailable target_unavailable stale_authority_epoch stale_resource_revision stale_rule_generation permission_denied profile_unqualified profile_artifact_unavailable profile_basis_changed runtime_artifact_unavailable qualification_artifact_unavailable observation_unavailable basis_changed guard_unresolved effect_domain_busy invariant_unresolved operator_override_active rule_basis_changed schedule_basis_changed temporal_basis_changed temporal_clock_unavailable timezone_basis_changed occurrence_early occurrence_expired clock_uncertain maintenance_active stale_rule_admission unsupported_admission_profile attempt_history_cold attempt_rate_exhausted attempt_spacing causal_provenance_unavailable execution_basis_changed)a
  @initial_policy @final_policy ++
                    [:stale_schedule_admission] ++
                    WotexHome.Durable.Store.ProfileGuard.denials()
  @inspection_policy @initial_policy ++
                       ~w(not_found request_not_held unsupported_capability read_only_capability risk_not_supported invalid_value color_plan_unavailable effect_required)a
  @select_current """
  SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch,
         source_time_utc_ms, received_time_utc_ms, received_monotonic_ms,
         quality, trust, value_kind, value_a, value_b, revision
  FROM observation_current WHERE thing_id = ? AND capability_key = ?
  """

  def admit_held_power_tx(
        db,
        credential,
        hash,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        qualification_state,
        store_clock
      ) do
    with {:ok, ^hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash) do
      admit_power_tx(
        db,
        principal_id,
        permissions,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        qualification_state,
        store_clock,
        :adapter
      )
    else
      {:error, reason} -> inspection_refusal(reason)
      _ -> {:rollback, {:policy, :unauthorized}}
    end
  end

  @doc "Borrowed Store-only advancement of an original explicit request. The retained author keeps every current guard; no bearer is created."
  def admit_explicit_power_tx(
        db,
        principal_id,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        qualification_state,
        store_clock
      ) do
    with :ok <- explicit_request_origin(db, principal_id, authority_epoch, operation_id),
         {:ok, permissions} <- active_principal_permissions(db, principal_id) do
      admit_power_tx(
        db,
        principal_id,
        permissions,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        qualification_state,
        store_clock,
        :adapter
      )
    else
      {:error, reason} when reason in [:not_explicit_request, :not_found] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        inspection_refusal(reason)
    end
  end

  defp explicit_request_origin(db, principal, epoch, operation) do
    case query(
           db,
           "SELECT origin,created_revision FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, [["explicit_request", revision]]} when is_integer(revision) and revision > 0 ->
        :ok

      {:ok, [[origin, _]]} when origin in ["legacy_request", "schedule_occurrence"] ->
        {:error, :not_explicit_request}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  @doc "Borrowed Store-only schedule admission with the retained principal and Store receipt clock; no bearer or caller time."
  def admit_schedule_power_tx(
        db,
        principal_id,
        authority_epoch,
        operation_id,
        qualification_state,
        store_clock
      ) do
    with {:ok, [["schedule_occurrence"]]} <-
           query(
             db,
             "SELECT origin FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, permissions} <- active_principal_permissions(db, principal_id),
         true <- Enum.all?(~w(rule:review rule:manage control:ordinary), &(&1 in permissions)),
         {:ok, boot_epoch, now_ms} <- sample_handoff_clock(store_clock) do
      admit_power_tx(
        db,
        principal_id,
        permissions,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        qualification_state,
        store_clock,
        :store
      )
    else
      {:ok, _} -> {:rollback, {:policy, :not_scheduled_request}}
      false -> {:rollback, {:policy, :permission_denied}}
      {:error, :principal_unavailable} -> {:rollback, {:policy, :principal_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_receipt}
    end
  end

  defp admit_power_tx(
         db,
         principal_id,
         permissions,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms,
         qualification_state,
         store_clock,
         freshness
       ) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row),
         :ok <-
           RuleWriter.execution_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             store_clock
           ),
         {:ok, boot_epoch, now_ms, freshness} <-
           execution_report_clock(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             boot_epoch,
             now_ms,
             store_clock,
             freshness
           ) do
      case receipt.disposition do
        :queued ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        :held ->
          case inspect_held_power_for_principal(
                 db,
                 principal_id,
                 permissions,
                 authority_epoch,
                 operation_id,
                 boot_epoch,
                 now_ms,
                 freshness
               ) do
            {:ok, :already_reported, snapshot} ->
              case close_power_no_send(
                     db,
                     receipt,
                     Enum.at(row, 1),
                     snapshot.observation_revision,
                     store_clock
                   ) do
                {:ok, revision} ->
                  {:commit,
                   {:ok,
                    %{
                      receipt
                      | disposition: :rejected,
                        reason: "already_reported_no_send",
                        revision: revision
                    }}}

                {:error, reason}
                when reason in [
                       :effect_domain_busy,
                       :observation_unavailable,
                       :occurrence_early,
                       :occurrence_expired,
                       :clock_uncertain,
                       :temporal_basis_changed,
                       :temporal_clock_unavailable,
                       :timezone_basis_changed,
                       :schedule_basis_changed
                     ] ->
                  {:rollback, {:policy, reason}}

                {:error, reason} ->
                  {:rollback, reason}
              end

            {:ok, :requires_effect, snapshot} ->
              [_, target_id, "power", "boolean", value_a, nil, profile_ref | _] = row

              with {:ok, evidence_ref} <-
                     qualified_power_profile(
                       db,
                       target_id,
                       profile_ref,
                       snapshot.resource_revision,
                       qualification_state
                     ),
                   :ok <- effect_domain_idle(db, target_id),
                   :ok <- invariant_guard(db, target_id, store_clock),
                   {:ok, store_epoch, store_ms} <- sample_handoff_clock(store_clock),
                   :ok <- attempt_guard(db, target_id, store_epoch, store_ms),
                   {:ok, revision} <- next_revision(db),
                   :ok <-
                     queue_held_power(
                       db,
                       receipt,
                       target_id,
                       profile_ref,
                       evidence_ref,
                       snapshot.resource_revision,
                       snapshot.observation_revision,
                       value_a,
                       revision
                     ),
                   :ok <-
                     RuleWriter.execution_guard(
                       db,
                       principal_id,
                       authority_epoch,
                       operation_id,
                       store_clock
                     ),
                   :ok <-
                     repeat_schedule_report(
                       db,
                       principal_id,
                       authority_epoch,
                       operation_id,
                       target_id,
                       snapshot.observation_revision,
                       store_clock
                     ) do
                {:commit, {:ok, %{receipt | disposition: :queued, revision: revision}}}
              else
                {:error, reason}
                when reason in [
                       :observation_unavailable,
                       :profile_unqualified,
                       :runtime_artifact_unavailable,
                       :qualification_artifact_unavailable,
                       :effect_domain_busy,
                       :invariant_unresolved,
                       :operator_override_active,
                       :rule_basis_changed,
                       :schedule_basis_changed,
                       :temporal_basis_changed,
                       :temporal_clock_unavailable,
                       :timezone_basis_changed,
                       :occurrence_early,
                       :occurrence_expired,
                       :clock_uncertain,
                       :maintenance_active,
                       :stale_rule_admission,
                       :unsupported_admission_profile,
                       :attempt_history_cold,
                       :attempt_rate_exhausted,
                       :attempt_spacing,
                       :causal_budget_exhausted
                     ] ->
                  {:rollback, {:policy, reason}}

                {:error, reason} ->
                  {:rollback, reason}
              end

            {:error, reason} ->
              inspection_refusal(reason)
          end

        _ ->
          {:rollback, {:policy, :request_not_held}}
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:error, reason}
      when reason in [
             :unauthorized,
             :operator_override_active,
             :rule_basis_changed,
             :schedule_basis_changed,
             :temporal_basis_changed,
             :temporal_clock_unavailable,
             :timezone_basis_changed,
             :occurrence_early,
             :occurrence_expired,
             :clock_uncertain,
             :maintenance_active,
             :stale_rule_admission,
             :principal_unavailable,
             :permission_denied,
             :invariant_unresolved
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp effect_domain_idle(db, target_id) do
    case query(
           db,
           "SELECT state FROM request_execution WHERE effect_domain = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted', 'outcome_unknown') LIMIT 1",
           [target_id]
         ) do
      {:ok, []} -> :ok
      {:ok, [_]} -> {:error, :effect_domain_busy}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp close_power_no_send(db, receipt, target, report, clock) do
    with {:ok, revision} <- close_no_send_if_idle(db, receipt, target),
         :ok <-
           RuleWriter.execution_guard(
             db,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             clock
           ),
         :ok <-
           repeat_schedule_report(
             db,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             target,
             report,
             clock
           ),
         do: {:ok, revision}
  end

  defp close_no_send_if_idle(db, receipt, target_id) do
    with :ok <- effect_domain_idle(db, target_id) do
      reject_held(
        db,
        receipt.principal_id,
        receipt.authority_epoch,
        receipt.operation_id,
        "already_reported_no_send"
      )
    end
  end

  defp queue_held_power(
         db,
         receipt,
         target_id,
         profile_ref,
         evidence_ref,
         resource_revision,
         baseline_revision,
         value_a,
         revision
       ) do
    planned_value = if value_a == "1", do: <<1, 1>>, else: <<1, 0>>

    with true <- value_a in ["0", "1"],
         :ok <- effect_domain_idle(db, target_id),
         {:ok, [[rule_generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'held'",
             [receipt.principal_id, receipt.authority_epoch, receipt.operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO request_execution (principal_id, authority_epoch, operation_id, target_id, effect_domain, profile_ref, profile_evidence_ref, resource_revision, rule_generation, baseline_revision, admission_revision, planned_value, state, claim_token, claim_boot_epoch, handoff_revision, attempts, revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', NULL, NULL, NULL, 0, ?)",
             [
               receipt.principal_id,
               receipt.authority_epoch,
               receipt.operation_id,
               target_id,
               target_id,
               profile_ref,
               evidence_ref,
               resource_revision,
               rule_generation,
               baseline_revision,
               revision,
               planned_value,
               revision
             ]
           ),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'queued', reason = NULL, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'held'",
             [revision, receipt.principal_id, receipt.authority_epoch, receipt.operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             "queued",
             nil
           ),
         :ok <- CausalLedger.reserve(db, receipt, revision) do
      :ok
    else
      false ->
        {:error, :corrupt_receipt}

      {:error, reason} when reason in [:effect_domain_busy, :causal_budget_exhausted] ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  def claim_queued_power_tx(
        db,
        principal_id,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        token,
        qualification_state,
        store_clock
      ) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :queued} = receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         {:ok, [execution_row]} <-
           query(
             db,
             "SELECT target_id, effect_domain, profile_ref, profile_evidence_ref, resource_revision, rule_generation, baseline_revision, planned_value, state, attempts FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, target_id, profile_ref, evidence_ref, resource_revision, rule_generation,
          baseline_revision, desired} <- validate_claim_rows(receipt_row, execution_row),
         :ok <-
           claim_current_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             target_id,
             profile_ref,
             evidence_ref,
             resource_revision,
             rule_generation,
             baseline_revision,
             desired,
             boot_epoch,
             now_ms,
             qualification_state,
             store_clock
           ),
         :ok <- invariant_guard(db, target_id, store_clock),
         :ok <-
           RuleWriter.execution_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             store_clock
           ),
         {:ok, store_epoch, store_ms} <- sample_handoff_clock(store_clock),
         :ok <- attempt_guard(db, target_id, store_epoch, store_ms),
         :ok <- CausalLedger.execution_guard(db, receipt),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = 'claimed', claim_token = CAST(? AS BLOB), claim_boot_epoch = ?, attempts = 1, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'queued'",
             [token, boot_epoch, revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'claimed', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'queued'",
             [revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             "claimed",
             nil
           ),
         claimed = %{receipt | disposition: :claimed, revision: revision},
         {:ok, claim} <-
           build_power_claim(
             db,
             claimed,
             token,
             boot_epoch,
             target_id,
             desired,
             resource_revision
           ),
         :ok <-
           RuleWriter.execution_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             store_clock
           ),
         :ok <-
           repeat_schedule_report(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             target_id,
             baseline_revision,
             store_clock
           ) do
      {:commit, {claimed, claim}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:ok, %Receipt{}} ->
        {:rollback, {:policy, :request_not_queued}}

      {:error, reason}
      when reason in [
             :principal_unavailable,
             :target_unavailable,
             :stale_authority_epoch,
             :stale_resource_revision,
             :stale_rule_generation,
             :permission_denied,
             :profile_unqualified,
             :runtime_artifact_unavailable,
             :qualification_artifact_unavailable,
             :observation_unavailable,
             :basis_changed,
             :invariant_unresolved,
             :operator_override_active,
             :rule_basis_changed,
             :schedule_basis_changed,
             :temporal_basis_changed,
             :temporal_clock_unavailable,
             :timezone_basis_changed,
             :occurrence_early,
             :occurrence_expired,
             :clock_uncertain,
             :maintenance_active,
             :stale_rule_admission,
             :unsupported_admission_profile,
             :request_not_queued,
             :attempt_history_cold,
             :attempt_rate_exhausted,
             :attempt_spacing,
             :causal_provenance_unavailable
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp build_power_claim(
         db,
         receipt,
         token,
         boot_epoch,
         target_id,
         desired,
         resource_revision
       ) do
    with {:ok, [[stable_id, document]]} <-
           query(
             db,
             "SELECT b.stable_id, t.document FROM enrollment_bindings b JOIN enrolled_things t ON t.thing_id = b.thing_id WHERE b.thing_id = ? AND t.status = 'active' AND t.resource_revision = ?",
             [target_id, resource_revision]
           ),
         true <- Id.valid?(stable_id),
         {:ok, %Thing{id: ^target_id} = thing} <- Registry.decode_thing(document),
         {:ok, mutation} <-
           Mutation.new(%{
             "api_version" => 1,
             "operation_id" => receipt.operation_id,
             "authority_epoch" => receipt.authority_epoch,
             "expected_revision" => resource_revision,
             "target_id" => target_id,
             "capability_key" => "power",
             "value" => %{"type" => "boolean", "value" => desired}
           }) do
      {:ok,
       %PowerClaim{
         receipt: receipt,
         token: token,
         stable_id: stable_id,
         thing: thing,
         mutation: mutation,
         boot_epoch: boot_epoch
       }}
    else
      _ -> {:error, :corrupt_enrollment}
    end
  end

  def handoff_claimed_power_tx(
        db,
        principal_id,
        authority_epoch,
        operation_id,
        token,
        now_ms,
        qualification_state,
        handoff_clock
      ) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :claimed} = receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         {:ok, [execution_row]} <-
           query(
             db,
             "SELECT target_id, effect_domain, profile_ref, profile_evidence_ref, resource_revision, rule_generation, baseline_revision, planned_value, state, attempts, claim_token, claim_boot_epoch, handoff_revision FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, target_id, profile_ref, evidence_ref, resource_revision, rule_generation,
          baseline_revision, desired, boot_epoch} <-
           validate_handoff_rows(receipt_row, execution_row, token),
         :ok <-
           claim_current_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             target_id,
             profile_ref,
             evidence_ref,
             resource_revision,
             rule_generation,
             baseline_revision,
             desired,
             boot_epoch,
             now_ms,
             qualification_state,
             handoff_clock
           ),
         :ok <- invariant_guard(db, target_id, handoff_clock),
         :ok <-
           RuleWriter.execution_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             handoff_clock
           ),
         {:ok, store_epoch, store_ms} <- sample_handoff_clock(handoff_clock),
         :ok <- attempt_guard(db, target_id, store_epoch, store_ms),
         :ok <- CausalLedger.execution_guard(db, receipt),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = 'dispatching', handoff_revision = ?, handoff_store_boot_epoch = ?, handoff_store_monotonic_ms = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'claimed' AND claim_token = CAST(? AS BLOB)",
             [
               revision,
               store_epoch,
               store_ms,
               revision,
               principal_id,
               authority_epoch,
               operation_id,
               token
             ]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'dispatching', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'claimed'",
             [revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             "dispatching",
             nil
           ),
         :ok <-
           RuleWriter.execution_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             handoff_clock
           ),
         :ok <-
           repeat_schedule_report(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             target_id,
             baseline_revision,
             handoff_clock
           ) do
      {:commit, %{receipt | disposition: :dispatching, revision: revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:ok, %Receipt{}} ->
        {:rollback, {:policy, :request_not_claimed}}

      {:error, reason}
      when reason in [
             :principal_unavailable,
             :target_unavailable,
             :stale_authority_epoch,
             :stale_resource_revision,
             :stale_rule_generation,
             :permission_denied,
             :profile_unqualified,
             :runtime_artifact_unavailable,
             :qualification_artifact_unavailable,
             :observation_unavailable,
             :basis_changed,
             :invariant_unresolved,
             :operator_override_active,
             :rule_basis_changed,
             :schedule_basis_changed,
             :temporal_basis_changed,
             :temporal_clock_unavailable,
             :timezone_basis_changed,
             :occurrence_early,
             :occurrence_expired,
             :clock_uncertain,
             :maintenance_active,
             :stale_rule_admission,
             :unsupported_admission_profile,
             :attempt_history_cold,
             :attempt_rate_exhausted,
             :attempt_spacing,
             :causal_provenance_unavailable
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  @doc "Capture a transient guard from the writer's actual receipt, before enclosing withdrawal/history checks. Owns no durable authority."
  def commit_context(db, %Receipt{} = receipt, clock, qualification, boot, now) do
    base = %{
      principal: receipt.principal_id,
      epoch: receipt.authority_epoch,
      operation: receipt.operation_id,
      receipt: receipt,
      token: nil,
      boot: boot,
      now: now,
      qualification: qualification,
      clock: clock
    }

    case receipt do
      %{disposition: :queued} ->
        {:ok, Map.put(base, :phase, :queue)}

      %{disposition: :claimed} ->
        with {:ok, [[token, claim_boot]]} <-
               query(
                 db,
                 "SELECT claim_token,claim_boot_epoch FROM request_execution WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
                 identity(base)
               ),
             do: {:ok, Map.merge(base, %{phase: :claim, token: token, boot: claim_boot})}

      %{disposition: :rejected, reason: "already_reported_no_send"} ->
        with {:ok, [row]} <- select_request(db, base.principal, base.epoch, base.operation),
             {:ok, _observation, baseline} <- current_report(db, Enum.at(row, 1), "power"),
             {:ok, [root]} <- no_send_root(db, base),
             do:
               {:ok,
                Map.merge(base, %{
                  phase: :no_send,
                  request_row: row,
                  baseline: baseline,
                  root: root
                })}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  @doc "Final Store-owned power repeat after history validation. Returns a transaction decision, never a device send."
  def final_power_decision(db, context, commit) do
    case final_power_guard(db, context) do
      :ok -> commit
      {:error, reason} when reason in @final_policy -> {:rollback, {:policy, reason}}
      {:error, reason} -> {:rollback, reason}
    end
  end

  @doc "Closed current-basis denials that permit Store withdrawal after undoing tentative power work. Damaged history and SQL errors are excluded."
  def policy_denial?(reason), do: reason in @initial_policy

  @doc "Closed semantic errors shared by Store's advisory held inspection and mutating inspection; no caller supplies an error classification."
  def inspection_policy?(reason), do: reason in @inspection_policy

  # Inspection may return policy, decoded-history or SQL failures. Only this
  # closed semantic set may leave the owner writable after transaction rollback.
  defp inspection_refusal(reason) when reason in @inspection_policy,
    do: {:rollback, {:policy, reason}}

  defp inspection_refusal(reason), do: {:rollback, reason}

  def final_power_guard(db, %{phase: :no_send} = context), do: final_no_send_guard(db, context)

  def final_power_guard(db, context) do
    %{
      phase: phase,
      principal: principal,
      epoch: epoch,
      operation: operation,
      token: token,
      boot: expected_boot,
      now: now,
      qualification: qualification,
      clock: clock
    } = context

    disposition = %{queue: :queued, claim: :claimed, handoff: :dispatching}[phase]

    with :ok <- MaintenanceWriter.guard(db),
         :ok <- final_actor(db, context),
         {:ok, [receipt_row]} <- select_request(db, principal, epoch, operation),
         {:ok, receipt} <- decode_receipt(principal, epoch, operation, receipt_row),
         true <- receipt.disposition == disposition,
         true <- Map.get(context, :receipt, receipt) == receipt,
         {:ok, [execution_row]} <-
           query(
             db,
             "SELECT target_id,effect_domain,profile_ref,profile_evidence_ref,resource_revision,rule_generation,baseline_revision,planned_value,state,attempts,claim_token,claim_boot_epoch,handoff_revision FROM request_execution WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ),
         {:ok, target, profile, evidence, resource, generation, baseline, desired, boot} <-
           final_power_rows(
             receipt_row,
             execution_row,
             phase,
             token,
             expected_boot,
             receipt.revision
           ),
         :ok <-
           claim_current_guard(
             db,
             principal,
             epoch,
             operation,
             target,
             profile,
             evidence,
             resource,
             generation,
             baseline,
             desired,
             boot,
             now,
             qualification,
             clock
           ),
         :ok <- invariant_guard(db, target, clock),
         :ok <- CausalLedger.execution_guard(db, receipt),
         {:ok, store_boot, store_now} <- sample_handoff_clock(clock),
         :ok <-
           AttemptGuard.check_excluding(
             db,
             target,
             {store_boot, store_now},
             DirectPowerLimits.attempts(),
             {principal, epoch, operation}
           ),
         :ok <- RuleWriter.execution_guard(db, principal, epoch, operation, clock),
         :ok <- repeat_schedule_report(db, principal, epoch, operation, target, baseline, clock),
         do: :ok,
         else: (
           false -> {:error, :execution_basis_changed}
           {:ok, _} -> {:error, :corrupt_receipt}
           error -> error
         )
  end

  defp final_power_rows(receipt, execution, phase, token, expected_boot, revision) do
    case Enum.split(execution, 8) do
      {basis, ["queued", 0, nil, nil, nil]} when phase == :queue ->
        with true <- Id.valid?(expected_boot),
             {:ok, target, profile, evidence, resource, generation, baseline, desired} <-
               validate_claim_rows(receipt, basis ++ ["queued", 0]),
             do:
               {:ok, target, profile, evidence, resource, generation, baseline, desired,
                expected_boot},
             else: (_ -> {:error, :corrupt_receipt})

      {basis, [state, 1, ^token, boot, handoff]} ->
        valid =
          Id.valid?(boot) and byte_size(token) == 32 and
            ((phase == :claim and state == "claimed" and boot == expected_boot and is_nil(handoff)) or
               (phase == :handoff and state == "dispatching" and handoff == revision))

        with true <- valid,
             {:ok, target, profile, evidence, resource, generation, baseline, desired} <-
               validate_claim_rows(receipt, basis ++ ["queued", 0]),
             do: {:ok, target, profile, evidence, resource, generation, baseline, desired, boot},
             else: (_ -> {:error, :corrupt_receipt})

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp final_no_send_guard(db, context) do
    %{principal: principal, epoch: epoch, operation: operation, clock: clock} = context

    with :ok <- MaintenanceWriter.guard(db),
         :ok <- final_actor(db, context),
         {:ok, [row]} <- select_request(db, principal, epoch, operation),
         true <- row == context.request_row,
         {:ok, receipt} <- decode_receipt(principal, epoch, operation, row),
         true <- receipt == context.receipt,
         {:ok, [[0, 0]]} <-
           query(
             db,
             "SELECT (SELECT COUNT(*) FROM request_outbox WHERE principal_id=? AND authority_epoch=? AND operation_id=?),(SELECT COUNT(*) FROM request_execution WHERE principal_id=? AND authority_epoch=? AND operation_id=?)",
             identity(context) ++ identity(context)
           ),
         {:ok, [root]} <- no_send_root(db, context),
         true <- root == context.root,
         {:ok, permissions} <- active_principal_permissions(db, principal),
         {:ok, boot, now, freshness} <-
           execution_report_clock(
             db,
             principal,
             epoch,
             operation,
             context.boot,
             context.now,
             clock,
             :adapter
           ),
         {:ok, :already_reported, snapshot} <-
           inspect_power_basis(
             db,
             row,
             principal,
             permissions,
             epoch,
             operation,
             boot,
             now,
             freshness
           ),
         true <- snapshot.observation_revision == context.baseline,
         target = Enum.at(row, 1),
         :ok <- effect_domain_idle(db, target),
         :ok <- RuleWriter.execution_guard(db, principal, epoch, operation, clock),
         :ok <-
           repeat_schedule_report(
             db,
             principal,
             epoch,
             operation,
             target,
             context.baseline,
             clock
           ),
         do: :ok,
         else: (
           false -> {:error, :execution_basis_changed}
           {:ok, :requires_effect, _} -> {:error, :basis_changed}
           {:ok, _} -> {:error, :corrupt_receipt}
           error -> error
         )
  end

  defp final_actor(db, %{auth_hash: hash, principal: principal}) do
    case authenticate(db, hash) do
      {:ok, ^principal, _} -> :ok
      {:ok, _, _} -> {:error, :unauthorized}
      error -> error
    end
  end

  defp final_actor(db, %{required_origin: :explicit_request} = context),
    do: explicit_request_origin(db, context.principal, context.epoch, context.operation)

  defp final_actor(_db, _context), do: :ok

  defp no_send_root(db, context),
    do:
      query(
        db,
        "SELECT origin,created_revision,reserved_effects,reservation_revision,rule_admission_revision,rule_generation FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
        identity(context)
      )

  defp identity(context), do: [context.principal, context.epoch, context.operation]

  defp attempt_guard(db, target_id, epoch, ms),
    do: AttemptGuard.check(db, target_id, {epoch, ms}, DirectPowerLimits.attempts())

  defp sample_handoff_clock(clock) do
    case WotexHome.Durable.Store.ClockContext.receipt(clock) do
      {epoch, ms} when is_integer(ms) and ms >= 0 and ms <= @max_i64 ->
        if Id.valid?(epoch), do: {:ok, epoch, ms}, else: {:error, :corrupt_receipt}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp validate_handoff_rows(
         [expected_revision, target_id, "power", "boolean", value_a, nil, profile_ref | _],
         [
           target_id,
           target_id,
           profile_ref,
           evidence_ref,
           resource_revision,
           rule_generation,
           baseline_revision,
           planned_value,
           "claimed",
           1,
           token,
           boot_epoch,
           nil
         ],
         token
       ) do
    desired = value_a == "1"

    if value_a in ["0", "1"] and planned_value == <<1, if(desired, do: 1, else: 0)>> and
         expected_revision == resource_revision and is_integer(resource_revision) and
         is_integer(rule_generation) and rule_generation >= 0 and
         is_integer(baseline_revision) and Id.valid?(evidence_ref) and Id.valid?(boot_epoch) do
      {:ok, target_id, profile_ref, evidence_ref, resource_revision, rule_generation,
       baseline_revision, desired, boot_epoch}
    else
      {:error, :corrupt_receipt}
    end
  end

  defp validate_handoff_rows(_receipt_row, _execution_row, _token),
    do: {:error, :corrupt_receipt}

  def accept_power_ack_tx(db, principal_id, authority_epoch, operation_id, token) do
    with {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         {:ok, [[state, stored_token]]} <-
           query(
             db,
             "SELECT state, claim_token FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         true <- stored_token == token do
      case {receipt.disposition, state} do
        {:protocol_accepted, "protocol_accepted"} ->
          {:rollback, {:unchanged, receipt}}

        {:dispatching, "dispatching"} ->
          with {:ok, revision} <- next_revision(db),
               {:ok, []} <-
                 query(
                   db,
                   "UPDATE request_execution SET state = 'protocol_accepted', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'dispatching' AND claim_token = CAST(? AS BLOB)",
                   [revision, principal_id, authority_epoch, operation_id, token]
                 ),
               {:ok, [[1]]} <- query(db, "SELECT changes()"),
               {:ok, []} <-
                 query(
                   db,
                   "UPDATE request_receipts SET disposition = 'protocol_accepted', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'dispatching'",
                   [revision, principal_id, authority_epoch, operation_id]
                 ),
               {:ok, [[1]]} <- query(db, "SELECT changes()"),
               :ok <-
                 request_event(
                   db,
                   revision,
                   principal_id,
                   authority_epoch,
                   operation_id,
                   "protocol_accepted",
                   nil
                 ) do
            {:commit, %{receipt | disposition: :protocol_accepted, revision: revision}}
          else
            {:error, reason} -> {:rollback, reason}
            _ -> {:rollback, :corrupt_receipt}
          end

        _ ->
          {:rollback, {:policy, :request_not_handed_off}}
      end
    else
      {:ok, []} -> {:rollback, {:policy, :not_found}}
      false -> {:rollback, {:policy, :claim_token_mismatch}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_receipt}
    end
  end

  def settle_power_readback_tx(
        db,
        principal_id,
        authority_epoch,
        operation_id,
        token,
        observation,
        store_clock
      ) do
    with {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         true <- receipt.disposition in [:dispatching, :protocol_accepted],
         {:ok, [[target_id, planned_value, state, stored_token, boot_epoch]]} <-
           query(
             db,
             "SELECT target_id, planned_value, state, claim_token, claim_boot_epoch FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         true <- state in ["dispatching", "protocol_accepted"],
         true <- stored_token == token,
         {:ok, desired} <- decode_planned_power(planned_value),
         {:ok, thing, resource_revision} <- usable_thing(db, target_id),
         :ok <-
           ProfilePins.require_current(
             db,
             :request,
             thing,
             resource_revision,
             {principal_id, authority_epoch, operation_id}
           ),
         {:ok, capability} <- Thing.capability(thing, "power"),
         :ok <- valid_power_readback(observation, target_id, boot_epoch, capability),
         {:ok, _observation_revision} <-
           retain_power_readback(db, observation, capability, store_clock),
         disposition = if(observation.value.data == desired, do: :observed, else: :contradicted),
         reason = if(disposition == :observed, do: nil, else: "readback_mismatch"),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = ? AND claim_token = CAST(? AS BLOB)",
             [
               Atom.to_string(disposition),
               revision,
               principal_id,
               authority_epoch,
               operation_id,
               state,
               token
             ]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = ?, reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = ?",
             [
               Atom.to_string(disposition),
               reason,
               revision,
               principal_id,
               authority_epoch,
               operation_id,
               state
             ]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             Atom.to_string(disposition),
             reason
           ) do
      {:commit, %{receipt | disposition: disposition, reason: reason, revision: revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      false ->
        {:rollback, {:policy, :request_not_handed_off}}

      :error ->
        {:rollback, {:policy, :invalid_power_readback}}

      {:error, reason}
      when reason in [
             :target_unavailable,
             :unsupported_capability,
             :capability_mismatch,
             :invalid_power_readback,
             :stale_sequence,
             :sequence_conflict,
             :source_epoch_changed,
             :profile_changed,
             :duplicate_power_readback
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp valid_power_readback(
         %Observation{
           thing_id: target_id,
           capability_key: "power",
           quality: "reported",
           trust: "unauthenticated_local",
           boot_epoch: boot_epoch,
           value: %Value{kind: :boolean}
         } = observation,
         target_id,
         boot_epoch,
         capability
       ) do
    if Observation.valid?(observation, capability),
      do: :ok,
      else: {:error, :invalid_power_readback}
  end

  defp valid_power_readback(_observation, _target_id, _boot_epoch, _capability),
    do: {:error, :invalid_power_readback}

  defp retain_power_readback(db, observation, capability, store_clock) do
    case ObservationWriter.record(db, observation, capability, store_clock) do
      {:commit, {:ok, revision}} -> {:ok, revision}
      {:rollback, {:duplicate, _revision}} -> {:error, :duplicate_power_readback}
      {:rollback, {:policy, reason}} -> {:error, reason}
      {:rollback, reason} -> {:error, reason}
    end
  end

  defp decode_planned_power(<<1, 1>>), do: {:ok, true}
  defp decode_planned_power(<<1, 0>>), do: {:ok, false}
  defp decode_planned_power(_planned), do: {:error, :corrupt_receipt}

  def mark_power_outcome_unknown_tx(
        db,
        principal_id,
        authority_epoch,
        operation_id,
        token,
        reason
      ) do
    with {:ok, reason_text} <- power_unknown_reason(reason),
         {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         {:ok, [[state, stored_token]]} <-
           query(
             db,
             "SELECT state, claim_token FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         true <- state in ["dispatching", "protocol_accepted"],
         true <- stored_token == token,
         {:ok, revision} <-
           invalidate_execution_row(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             state,
             reason_text
           ) do
      {:commit,
       %{
         receipt
         | disposition: :outcome_unknown,
           reason: reason_text <> "_after_handoff",
           revision: revision
       }}
    else
      {:ok, []} -> {:rollback, {:policy, :not_found}}
      false -> {:rollback, {:policy, :request_not_handed_off}}
      {:error, :invalid_unknown_reason} -> {:rollback, {:policy, :invalid_unknown_reason}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_receipt}
    end
  end

  defp power_unknown_reason(reason)
       when reason in [
              :set_send_uncertain,
              :read_send_uncertain,
              :ack_timeout,
              :readback_timeout,
              :datagram_budget_exhausted,
              :transport_unavailable,
              :invalid_transport_result,
              :clock_unavailable,
              :settlement_unavailable
            ],
       do: {:ok, Atom.to_string(reason)}

  defp power_unknown_reason(_reason), do: {:error, :invalid_unknown_reason}

  def abandoned_worker_tx(db, principal_id, authority_epoch, operation_id) do
    case query(
           db,
           "SELECT state FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
           [principal_id, authority_epoch, operation_id]
         ) do
      {:ok, [[state]]} when state in ["dispatching", "protocol_accepted"] ->
        case invalidate_execution_row(
               db,
               principal_id,
               authority_epoch,
               operation_id,
               state,
               "worker_exit"
             ) do
          {:ok, revision} -> {:commit, {:unknown, revision}}
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, [["claimed"]]} ->
        {:rollback, {:unchanged, :claimed}}

      {:ok, []} ->
        {:rollback, {:unchanged, :gone}}

      {:ok, [[_terminal]]} ->
        {:rollback, {:unchanged, :terminal}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  def reject_abandoned_claim_tx(db, principal_id, authority_epoch, operation_id, owner_active?) do
    with {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :claimed} = receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         false <- owner_active?,
         {:ok, [["claimed", nil, token_type, 32]]} <-
           query(
             db,
             "SELECT state, handoff_revision, typeof(claim_token), length(claim_token) FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         true <- token_type == "blob",
         {:ok, revision} <-
           invalidate_execution_row(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             "claimed",
             "worker_abandoned_before_handoff"
           ) do
      {:commit,
       %{
         receipt
         | disposition: :rejected,
           reason: "worker_abandoned_before_handoff",
           revision: revision
       }}
    else
      {:ok, []} -> {:rollback, {:policy, :not_found}}
      {:ok, %Receipt{}} -> {:rollback, {:policy, :request_not_claimed}}
      true -> {:rollback, {:policy, :claim_owner_active}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_receipt}
    end
  end

  def fence_rule_generation_tx(db, expected_revision, authority_epoch) do
    with {:ok, [[current_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[current_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         :ok <-
           check_rule_fence_basis(
             current_revision,
             expected_revision,
             current_epoch,
             authority_epoch,
             generation
           ),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' ORDER BY principal_id, authority_epoch, operation_id LIMIT 1025"
           ),
         {:ok, pending} <- pending_execution_rows(db, :all),
         true <- length(held) + length(pending) <= 1_024,
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "UPDATE meta SET value = ? WHERE key = 'rule_generation'", [generation + 1]),
         :ok <- authority_event(db, revision, "rule_generation_fenced", "rules:empty"),
         {:ok, []} <- query(db, "UPDATE meta SET value=0 WHERE key='active_rule_admission'"),
         {:ok, _after_held} <- reject_held_batch(db, held, "rule_generation_fenced"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, :all, "rule_generation_fenced") do
      {:commit,
       {:ok,
        %{
          store_revision: final_revision,
          rule_generation: generation + 1,
          affected_requests: length(held) + length(pending)
        }}}
    else
      {:error, reason}
      when reason in [:stale_store_revision, :stale_authority_epoch, :generation_exhausted] ->
        {:rollback, {:policy, reason}}

      false ->
        {:rollback, {:policy, :generation_fence_capacity}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp check_rule_fence_basis(
         current_revision,
         expected_revision,
         current_epoch,
         authority_epoch,
         generation
       ) do
    cond do
      current_revision != expected_revision ->
        {:error, :stale_store_revision}

      current_epoch != authority_epoch ->
        {:error, :stale_authority_epoch}

      not is_integer(generation) or generation < 0 or generation >= @max_i64 ->
        {:error, :generation_exhausted}

      true ->
        :ok
    end
  end

  defp validate_claim_rows(
         [expected_revision, target_id, "power", "boolean", value_a, nil, profile_ref | _],
         [
           target_id,
           target_id,
           profile_ref,
           evidence_ref,
           resource_revision,
           rule_generation,
           baseline_revision,
           planned_value,
           "queued",
           0
         ]
       ) do
    desired = value_a == "1"

    if value_a in ["0", "1"] and planned_value == <<1, if(desired, do: 1, else: 0)>> and
         expected_revision == resource_revision and is_integer(resource_revision) and
         is_integer(rule_generation) and rule_generation >= 0 and
         is_integer(baseline_revision) and Id.valid?(evidence_ref) do
      {:ok, target_id, profile_ref, evidence_ref, resource_revision, rule_generation,
       baseline_revision, desired}
    else
      {:error, :corrupt_receipt}
    end
  end

  defp validate_claim_rows(_receipt_row, _execution_row), do: {:error, :corrupt_receipt}

  defp claim_current_guard(
         db,
         principal_id,
         authority_epoch,
         operation_id,
         target_id,
         profile_ref,
         evidence_ref,
         resource_revision,
         rule_generation,
         baseline_revision,
         desired,
         boot_epoch,
         now_ms,
         qualification_state,
         store_clock
       ) do
    with {:ok, permissions} <- active_principal_permissions(db, principal_id),
         {:ok, targets} <- allowed_targets(db, principal_id),
         {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         :ok <- check_claim_generation(db, rule_generation),
         {:ok, thing, ^resource_revision} <- usable_thing(db, target_id),
         :ok <-
           ProfilePins.require_current(
             db,
             :request,
             thing,
             resource_revision,
             {principal_id, authority_epoch, operation_id}
           ),
         true <- thing.role == "Light" and thing.profile_ref == profile_ref,
         {:ok, ^evidence_ref} <-
           qualified_power_profile(
             db,
             target_id,
             profile_ref,
             resource_revision,
             qualification_state
           ),
         mutation = %Mutation{
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           expected_revision: resource_revision,
           target_id: target_id,
           capability_key: "power",
           value: %{"type" => "boolean", "value" => desired}
         },
         :ok <-
           Policy.check(mutation, thing, %Context{
             principal_id: principal_id,
             permissions: permissions,
             allowed_targets: targets,
             authority_epoch: store_epoch,
             resource_revision: resource_revision,
             enrollment_valid: true,
             profile_valid: true,
             invariants: DirectPowerSafety.decision(thing)
           }),
         {:ok, capability} <- Thing.capability(thing, "power"),
         {:ok, observation, ^baseline_revision} <- current_report(db, target_id, "power"),
         true <- Observation.valid?(observation, capability),
         {:ok, %Value{kind: :boolean, data: reported}} <-
           execution_reported_value(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             target_id,
             observation,
             baseline_revision,
             capability,
             boot_epoch,
             now_ms,
             store_clock
           ),
         true <- reported != desired do
      :ok
    else
      false -> {:error, :basis_changed}
      {:ok, %Thing{}, _revision} -> {:error, :stale_resource_revision}
      {:ok, %Observation{}, _revision} -> {:error, :basis_changed}
      {:ok, _other_evidence} -> {:error, :profile_unqualified}
      :error -> {:error, :corrupt_receipt}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp check_claim_generation(db, rule_generation) do
    case query(db, "SELECT value FROM meta WHERE key = 'rule_generation'") do
      {:ok, [[^rule_generation]]} -> :ok
      {:ok, [[_other]]} -> {:error, :stale_rule_generation}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp invariant_guard(db, target_id, store_clock) do
    with {:ok, thing, _revision} <- usable_thing(db, target_id),
         true <- DirectPowerSafety.decision(thing) == :allow,
         {:ok, :allow} <- InvariantWriter.decision(db, target_id, store_clock) do
      :ok
    else
      false -> {:error, :invariant_unresolved}
      {:ok, _unresolved} -> {:error, :invariant_unresolved}
      error -> error
    end
  end

  def settle_held_color_noop_tx(
        db,
        credential,
        hash,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms
      ) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
      cond do
        receipt.disposition == :rejected and receipt.reason == "already_reported_no_send" ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        receipt.disposition != :held ->
          {:rollback, {:policy, :request_not_held}}

        true ->
          case inspect_held_color_result(
                 db,
                 credential,
                 authority_epoch,
                 operation_id,
                 boot_epoch,
                 now_ms
               ) do
            {:ok, plan, _snapshot} ->
              if ColorPlan.no_effect?(plan) do
                case close_no_send_if_idle(db, receipt, Enum.at(row, 1)) do
                  {:ok, revision} ->
                    {:commit,
                     {:ok,
                      %{
                        receipt
                        | disposition: :rejected,
                          reason: "already_reported_no_send",
                          revision: revision
                      }}}

                  {:error, :effect_domain_busy} ->
                    {:rollback, {:policy, :effect_domain_busy}}

                  {:error, reason} ->
                    {:rollback, reason}
                end
              else
                {:rollback, {:policy, :effect_required}}
              end

            {:error, reason} ->
              inspection_refusal(reason)
          end
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:error, reason} ->
        inspection_refusal(reason)
    end
  end

  def settle_held_power_noop_tx(
        db,
        credential,
        hash,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        store_clock
      ) do
    with {:ok, ^hash} <- Registry.credential_hash(credential),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row),
         :ok <-
           RuleWriter.execution_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             store_clock
           ),
         {:ok, boot_epoch, now_ms, freshness} <-
           execution_report_clock(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             boot_epoch,
             now_ms,
             store_clock,
             :adapter
           ) do
      cond do
        receipt.disposition == :rejected and receipt.reason == "already_reported_no_send" ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        receipt.disposition != :held ->
          {:rollback, {:policy, :request_not_held}}

        true ->
          case inspect_held_power_for_principal(
                 db,
                 principal_id,
                 permissions,
                 authority_epoch,
                 operation_id,
                 boot_epoch,
                 now_ms,
                 freshness
               ) do
            {:ok, :already_reported, snapshot} ->
              case close_power_no_send(
                     db,
                     receipt,
                     Enum.at(row, 1),
                     snapshot.observation_revision,
                     store_clock
                   ) do
                {:ok, revision} ->
                  {:commit,
                   {:ok,
                    %{
                      receipt
                      | disposition: :rejected,
                        reason: "already_reported_no_send",
                        revision: revision
                    }}}

                {:error, reason}
                when reason in [
                       :effect_domain_busy,
                       :observation_unavailable,
                       :occurrence_early,
                       :occurrence_expired,
                       :clock_uncertain,
                       :temporal_basis_changed,
                       :temporal_clock_unavailable,
                       :timezone_basis_changed,
                       :schedule_basis_changed
                     ] ->
                  {:rollback, {:policy, reason}}

                {:error, reason} ->
                  {:rollback, reason}
              end

            {:ok, :requires_effect, _snapshot} ->
              {:rollback, {:policy, :effect_required}}

            {:error, reason} ->
              inspection_refusal(reason)
          end
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:error, reason} ->
        inspection_refusal(reason)
    end
  end

  def inspect_held_color_result(
        db,
        credential,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms
      ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :held}} <-
           decode_receipt(principal_id, authority_epoch, operation_id, row),
         :ok <- held_outbox(db, principal_id, authority_epoch, operation_id),
         [expected_revision, target_id, key, kind, a, b, profile_ref | _] = row,
         true <- key in ~w(brightness colour_hsv colour_temperature),
         {:ok, value} <- decode_value(kind, a, b),
         {:ok, value_map} <- color_value_map(value),
         {:ok, thing, resource_revision} <- usable_thing(db, target_id),
         :ok <-
           ProfilePins.require_current(
             db,
             :request,
             thing,
             resource_revision,
             {principal_id, authority_epoch, operation_id}
           ),
         true <- thing.role == "Light" and thing.profile_ref == profile_ref,
         {:ok, allowed_targets} <- allowed_targets(db, principal_id),
         {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         mutation = %Mutation{
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           expected_revision: expected_revision,
           target_id: target_id,
           capability_key: key,
           value: value_map
         },
         :ok <-
           Policy.check(mutation, thing, %Context{
             principal_id: principal_id,
             permissions: permissions,
             allowed_targets: allowed_targets,
             authority_epoch: store_epoch,
             resource_revision: resource_revision,
             enrollment_valid: true,
             profile_valid: true,
             invariants: :allow
           }),
         {:ok, reports, revisions} <- color_reports(db, target_id),
         {:ok, plan} <- ColorPlan.new(thing, mutation, reports, boot_epoch, now_ms) do
      {:ok, plan,
       %{
         store_revision: store_revision,
         resource_revision: resource_revision,
         observation_revisions: revisions,
         boot_epoch: boot_epoch,
         checked_monotonic_ms: now_ms
       }}
    else
      {:ok, []} -> {:error, :not_found}
      {:ok, %Receipt{}} -> {:error, :request_not_held}
      false -> {:error, :guard_unresolved}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :guard_unresolved}
    end
  end

  defp color_value_map(%Value{kind: :fraction, data: ppm}),
    do: {:ok, %{"type" => "fraction", "ppm" => ppm}}

  defp color_value_map(%Value{kind: :hsv, data: {hue, saturation}}),
    do: {:ok, %{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation}}

  defp color_value_map(%Value{kind: :kelvin, data: kelvin}),
    do: {:ok, %{"type" => "kelvin", "kelvin" => kelvin}}

  defp color_value_map(_value), do: {:error, :unsupported_capability}

  defp color_reports(db, target_id) do
    Enum.reduce_while(~w(brightness colour_hsv colour_temperature), {:ok, %{}, %{}}, fn key,
                                                                                        {:ok,
                                                                                         reports,
                                                                                         revisions} ->
      case current_report(db, target_id, key) do
        {:ok, report, revision} ->
          {:cont, {:ok, Map.put(reports, key, report), Map.put(revisions, key, revision)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def inspect_held_power_result(
        db,
        credential,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms
      ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash) do
      inspect_held_power_for_principal(
        db,
        principal_id,
        permissions,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms,
        :adapter
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_held_power_for_principal(
         db,
         principal_id,
         permissions,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms,
         freshness
       ) do
    with {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :held}} <-
           decode_receipt(principal_id, authority_epoch, operation_id, row),
         :ok <- held_outbox(db, principal_id, authority_epoch, operation_id),
         do:
           inspect_power_basis(
             db,
             row,
             principal_id,
             permissions,
             authority_epoch,
             operation_id,
             boot_epoch,
             now_ms,
             freshness
           ),
         else: (
           {:ok, []} -> {:error, :not_found}
           {:ok, %Receipt{}} -> {:error, :request_not_held}
           error -> error
         )
  end

  defp inspect_power_basis(
         db,
         row,
         principal_id,
         permissions,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms,
         freshness
       ) do
    with [expected_revision, target_id, capability_key, kind, a, b, profile_ref | _] = row,
         true <- capability_key == "power" and kind == "boolean" and is_nil(b),
         {:ok, %Value{kind: :boolean, data: desired}} <- decode_value(kind, a, b),
         {:ok, thing, resource_revision} <- usable_thing(db, target_id),
         :ok <-
           ProfilePins.require_current(
             db,
             :request,
             thing,
             resource_revision,
             {principal_id, authority_epoch, operation_id}
           ),
         true <- thing.role == "Light" and thing.profile_ref == profile_ref,
         {:ok, allowed_targets} <- allowed_targets(db, principal_id),
         {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         mutation = %Mutation{
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           expected_revision: expected_revision,
           target_id: target_id,
           capability_key: capability_key,
           value: %{"type" => "boolean", "value" => desired}
         },
         :ok <-
           Policy.check(mutation, thing, %Context{
             principal_id: principal_id,
             permissions: permissions,
             allowed_targets: allowed_targets,
             authority_epoch: store_epoch,
             resource_revision: resource_revision,
             enrollment_valid: true,
             profile_valid: true,
             invariants: :allow
           }),
         {:ok, capability} <- Thing.capability(thing, "power"),
         {:ok, observation, observation_revision} <- current_report(db, target_id, "power"),
         true <- Observation.valid?(observation, capability),
         {:ok, %Value{kind: :boolean, data: reported}} <-
           admission_reported_value(
             db,
             target_id,
             observation,
             observation_revision,
             capability,
             boot_epoch,
             now_ms,
             freshness
           ) do
      decision = if desired == reported, do: :already_reported, else: :requires_effect

      {:ok, decision,
       %{
         store_revision: store_revision,
         resource_revision: resource_revision,
         observation_revision: observation_revision,
         boot_epoch: boot_epoch,
         checked_monotonic_ms: now_ms
       }}
    else
      {:ok, []} -> {:error, :not_found}
      {:ok, %Receipt{}} -> {:error, :request_not_held}
      :error -> {:error, :unsupported_capability}
      false -> {:error, :guard_unresolved}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :guard_unresolved}
    end
  end

  @doc "Refines only an unknown receipt with exact newer retained evidence; never requeues."
  def reconcile_unknown_power_tx(
        db,
        hash,
        epoch,
        operation_id,
        receipt_revision,
        report_revision,
        boot_epoch,
        now_ms,
        qualification_basis,
        active_owners
      ) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [row]} <- select_request(db, principal_id, epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, epoch, operation_id, row),
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, Enum.at(row, 1)),
         false <- MapSet.member?(active_owners, {principal_id, epoch, operation_id}) do
      reference = Integer.to_string(receipt_revision) <> ":" <> Integer.to_string(report_revision)

      cond do
        receipt.disposition in [:observed, :contradicted] and
            receipt.reason in [
              "reconciled_report:" <> reference,
              "reconciled_mismatch:" <> reference
            ] ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        receipt.disposition != :outcome_unknown ->
          {:rollback, {:policy, :request_not_unknown}}

        receipt.revision != receipt_revision ->
          {:rollback, {:policy, :stale_receipt_revision}}

        true ->
          reconcile_unknown_report(
            db,
            receipt,
            row,
            report_revision,
            boot_epoch,
            now_ms,
            qualification_basis,
            reference
          )
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      true ->
        {:rollback, {:policy, :worker_still_active}}

      false ->
        {:rollback, {:policy, :permission_denied}}

      {:error, reason} when reason in [:unauthorized, :target_unavailable] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp reconcile_unknown_report(
         db,
         receipt,
         [expected_resource, target_id, "power", "boolean", value_a, nil, profile_ref | _],
         report_revision,
         boot_epoch,
         now_ms,
         qualification_basis,
         reference
       ) do
    with {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         :ok <- same_reconciliation_epoch(epoch, receipt.authority_epoch),
         {:ok,
          [
            [
              ^target_id,
              ^profile_ref,
              evidence_ref,
              ^expected_resource,
              planned,
              "outcome_unknown",
              handoff_revision
            ]
          ]} <-
           query(db, "SELECT target_id, profile_ref, profile_evidence_ref, resource_revision,
             planned_value, state, handoff_revision FROM request_execution
             WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?", [
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id
           ]),
         true <- is_integer(handoff_revision) and handoff_revision in 1..@max_i64,
         {:ok, desired} <- decode_planned_power(planned),
         {:ok, %Value{kind: :boolean, data: ^desired}} <- decode_value("boolean", value_a, nil),
         {:ok, thing, current_resource} <- usable_thing(db, target_id),
         :ok <-
           ProfilePins.require_current(
             db,
             :request,
             thing,
             current_resource,
             {receipt.principal_id, receipt.authority_epoch, receipt.operation_id}
           ),
         :ok <-
           same_reconciliation_declaration(
             thing,
             current_resource,
             profile_ref,
             expected_resource
           ),
         {:ok, current_evidence} <-
           qualified_power_profile(
             db,
             target_id,
             profile_ref,
             expected_resource,
             qualification_basis
           ),
         :ok <- same_reconciliation_qualification(current_evidence, evidence_ref),
         {:ok, capability} <- Thing.capability(thing, "power"),
         {:ok, observation, current_report_revision} <- current_report(db, target_id, "power"),
         :ok <- exact_new_report(current_report_revision, report_revision, receipt.revision),
         :ok <- valid_power_readback(observation, target_id, boot_epoch, capability),
         {:ok, %Value{kind: :boolean, data: actual}} <-
           fresh_reported_value(observation, capability, boot_epoch, now_ms),
         disposition = if(actual == desired, do: :observed, else: :contradicted),
         reason =
           if(actual == desired, do: "reconciled_report:", else: "reconciled_mismatch:") <>
             reference,
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "UPDATE request_execution SET state = ?, revision = ?
             WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?
             AND state = 'outcome_unknown' AND revision = ?", [
             Atom.to_string(disposition),
             revision,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             receipt.revision
           ]),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(db, "UPDATE request_receipts SET disposition = ?, reason = ?, revision = ?
             WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?
             AND disposition = 'outcome_unknown' AND revision = ?", [
             Atom.to_string(disposition),
             reason,
             revision,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             receipt.revision
           ]),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             Atom.to_string(disposition),
             reason
           ) do
      {:commit, {:ok, %{receipt | disposition: disposition, reason: reason, revision: revision}}}
    else
      :error ->
        {:rollback, {:policy, :unsupported_capability}}

      false ->
        {:rollback, :corrupt_receipt}

      {:error, reason}
      when reason in [:corrupt_value, :corrupt_receipt, :corrupt_principal, :corrupt_enrollment] ->
        {:rollback, reason}

      {:error, reason} when is_atom(reason) ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp reconcile_unknown_report(_db, _receipt, _row, _report_revision, _boot, _now, _basis, _ref),
    do: {:rollback, {:policy, :unsupported_capability}}

  defp same_reconciliation_epoch(epoch, epoch), do: :ok
  defp same_reconciliation_epoch(_, _), do: {:error, :stale_authority_epoch}

  defp same_reconciliation_declaration(%Thing{profile_ref: profile}, resource, profile, resource),
    do: :ok

  defp same_reconciliation_declaration(_, _, _, _), do: {:error, :profile_changed}

  defp same_reconciliation_qualification(evidence, evidence), do: :ok
  defp same_reconciliation_qualification(_, _), do: {:error, :profile_changed}

  defp exact_new_report(current, requested, _unknown_revision) when current != requested,
    do: {:error, :reconciliation_evidence_changed}

  defp exact_new_report(current, _requested, unknown_revision) when current <= unknown_revision,
    do: {:error, :reconciliation_evidence_not_new}

  defp exact_new_report(_, _, _), do: :ok

  defp current_report(db, target_id, capability_key) do
    case query(db, @select_current, [target_id, capability_key]) do
      {:ok, [row]} -> decode_current(target_id, capability_key, row)
      {:ok, []} -> {:error, :observation_unavailable}
      {:ok, _} -> {:error, :corrupt_value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repeat_schedule_report(db, principal, epoch, operation, target, revision, clock) do
    case query(
           db,
           "SELECT origin FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, [["schedule_occurrence"]]} ->
        with {:ok, boot, now} <- sample_handoff_clock(clock),
             {:ok, thing, _} <- usable_thing(db, target),
             {:ok, capability} <- Thing.capability(thing, "power"),
             {:ok, observation, ^revision} <- current_report(db, target, "power"),
             {:ok, _value} <-
               admission_reported_value(
                 db,
                 target,
                 observation,
                 revision,
                 capability,
                 boot,
                 now,
                 :store
               ),
             do: :ok,
             else: (
               {:error, reason} -> {:error, reason}
               _ -> {:error, :observation_unavailable}
             )

      {:ok, [[origin]]} when origin in ["explicit_request", "legacy_request"] ->
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp execution_report_clock(db, principal, epoch, operation, boot, now, clock, default) do
    case query(
           db,
           "SELECT origin FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, [["schedule_occurrence"]]} ->
        with {:ok, store_boot, store_now} <- sample_handoff_clock(clock),
             do: {:ok, store_boot, store_now, :store}

      {:ok, [[origin]]} when origin in ["explicit_request", "legacy_request"] ->
        {:ok, boot, now, default}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp execution_reported_value(
         db,
         principal,
         epoch,
         operation,
         target,
         observation,
         revision,
         capability,
         boot,
         now,
         clock
       ) do
    with {:ok, boot, now, freshness} <-
           execution_report_clock(db, principal, epoch, operation, boot, now, clock, :adapter),
         do:
           admission_reported_value(
             db,
             target,
             observation,
             revision,
             capability,
             boot,
             now,
             freshness
           )
  end

  defp admission_reported_value(
         _db,
         _target,
         observation,
         _revision,
         capability,
         boot,
         now,
         :adapter
       ),
       do: fresh_reported_value(observation, capability, boot, now)

  defp admission_reported_value(db, target, observation, revision, capability, boot, now, :store) do
    with {:ok, %{freshness: "fresh", observation: ^observation, revision: ^revision}} <-
           WotexHome.Durable.Store.FactReadModel.report_detail(
             db,
             target,
             "power",
             capability,
             {boot, now}
           ),
         true <- observation.quality == "reported",
         do: {:ok, observation.value},
         else: (
           {:error, reason} -> {:error, reason}
           _ -> {:error, :observation_unavailable}
         )
  end

  defp fresh_reported_value(observation, capability, boot_epoch, now_ms) do
    case Observation.current_value(observation, capability, boot_epoch, now_ms) do
      {:ok, value} -> {:ok, value}
      :unknown -> {:error, :observation_unavailable}
    end
  end

  defp held_outbox(db, principal_id, authority_epoch, operation_id) do
    case query(
           db,
           "SELECT state FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
           [principal_id, authority_epoch, operation_id]
         ) do
      {:ok, [["held"]]} -> :ok
      {:ok, _} -> {:error, :corrupt_receipt}
      {:error, reason} -> {:error, reason}
    end
  end
end
