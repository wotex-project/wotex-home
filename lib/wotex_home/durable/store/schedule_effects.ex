defmodule WotexHome.Durable.Store.ScheduleEffects do
  @moduledoc "Distinct immutable temporal request provenance under the single Store. Owns no bearer, clock, process or transport."
  alias WotexHome.Mutation

  alias WotexHome.Durable.Store.{
    ClockContext,
    ExecutionWriter,
    InvariantWriter,
    Journal,
    MaintenanceWriter,
    OverrideWriter,
    RequestLedger,
    RequestInvalidator,
    ScheduleLifecycle,
    ScheduleWriter
  }

  alias WotexHome.Schedules.{ActivationClock, Codec, Occurrence, Window}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "consideration_revision,principal_id,authority_epoch,operation_id,decision,reason,request_revision,runtime_digest,revision"
  @corrupt ~w(corrupt_schedule_effect corrupt_schedule_occurrence corrupt_schedule_lifecycle corrupt_schedule_admission corrupt_controller_history corrupt_maintenance corrupt_invariant corrupt_value corrupt_override corrupt_receipt corrupt_enrollment corrupt_principal corrupt_native_setup corrupt_native_target_history corrupt_profile_ledger corrupt_qualification_history)a

  def columns, do: @columns

  @doc "Store-owned bounded admission/expiry pass. Derives every author and identity from retained provenance; accepts no bearer, caller time or proposal."
  def advance(db, clock, qualification) do
    with :ok <- validate(db),
         {:ok, [[before]]} <- query(db, "SELECT value FROM meta WHERE key='revision'"),
         :ok <- ScheduleLifecycle.withdraw_invalidated(db, clock),
         {:ok, pending} <-
           query(
             db,
             "SELECT s.principal_id,s.authority_epoch,s.operation_id FROM schedule_effect_operations s JOIN request_receipts r USING (principal_id,authority_epoch,operation_id) WHERE s.request_revision IS NOT NULL AND r.disposition IN ('held','queued','claimed') ORDER BY s.consideration_revision LIMIT 17"
           ),
         {:ok, receipts, changed} <-
           advance_rows(db, Enum.take(pending, 16), clock, qualification),
         {:ok, [[after_revision]]} <- query(db, "SELECT value FROM meta WHERE key='revision'") do
      result = {:ok, %{receipts: receipts, has_more: length(pending) > 16}}

      if changed or after_revision != before,
        do: {:commit, result},
        else: {:rollback, {:unchanged, result}}
    else
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp advance_rows(db, rows, clock, qualification) do
    Enum.reduce_while(rows, {:ok, [], false}, fn [principal, epoch, operation],
                                                 {:ok, receipts, changed} ->
      with {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
           {:ok, receipt} <- RequestLedger.decode_receipt(principal, epoch, operation, row) do
        case advance_one(db, receipt, clock, qualification) do
          {:ok, next, mutated} -> {:cont, {:ok, receipts ++ [next], changed or mutated}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, corrupt()}
      end
    end)
  end

  @doc "Capture only bounded actual advancement receipts. No bearer, proposed effect or persistent guard."
  def commit_context(db, {:ok, %{receipts: receipts}}, clock, qualification)
      when is_list(receipts) and length(receipts) <= 16 do
    {boot, now} = ClockContext.receipt(clock)

    Enum.reduce_while(receipts, {:ok, %{guards: [], identities: []}}, fn receipt,
                                                                         {:ok, context} ->
      identity = [receipt.principal_id, receipt.authority_epoch, receipt.operation_id]
      context = %{context | identities: context.identities ++ [identity]}

      if receipt.disposition in [:queued, :claimed] or
           receipt.reason == "already_reported_no_send" do
        case ExecutionWriter.commit_context(db, receipt, clock, qualification, boot, now) do
          {:ok, guard} when is_map(guard) ->
            {:cont, {:ok, %{context | guards: context.guards ++ [guard]}}}

          {:error, reason} ->
            {:halt, {:error, reason}}

          _ ->
            {:halt, {:error, :corrupt_receipt}}
        end
      else
        {:cont, {:ok, context}}
      end
    end)
  end

  def commit_context(_, _, _, _), do: {:error, :corrupt_receipt}

  @doc "Repeat new queue/no-send and retained unsent execution guards after enclosing history validation."
  def final_advance_decision(db, context, commit) do
    Enum.reduce_while(context.guards, commit, fn guard, _ ->
      case ExecutionWriter.final_power_decision(db, guard, commit) do
        {:commit, _} -> {:cont, commit}
        {:rollback, {:policy, reason}} -> {:halt, {:rollback, {:advance_policy, guard, reason}}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "After restoring tentative admission and current withdrawal, terminalize only the failed unsent identity and return actual current receipts."
  def close_failed_commit(db, context, failed, reason) do
    with {:ok, [row]} <-
           RequestLedger.select_request(db, failed.principal, failed.epoch, failed.operation),
         {:ok, receipt} <-
           RequestLedger.decode_receipt(failed.principal, failed.epoch, failed.operation, row),
         :ok <- close_failed_unsent(db, receipt, reason),
         {:ok, receipts} <- current_receipts(db, context.identities),
         {:ok, pending} <-
           query(
             db,
             "SELECT s.principal_id,s.authority_epoch,s.operation_id FROM schedule_effect_operations s JOIN request_receipts r USING(principal_id,authority_epoch,operation_id) WHERE s.request_revision IS NOT NULL AND r.disposition IN ('held','queued','claimed') ORDER BY s.consideration_revision LIMIT 17"
           ) do
      processed = MapSet.new(context.identities)

      {:ok,
       %{receipts: receipts, has_more: Enum.any?(pending, &(not MapSet.member?(processed, &1)))}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp close_failed_unsent(db, %{disposition: state} = receipt, reason)
       when state in [:held, :queued, :claimed] do
    with {:ok, _, true} <- close_unsent(db, receipt, reason), do: :ok
  end

  defp close_failed_unsent(_db, %{disposition: :rejected}, _reason), do: :ok
  defp close_failed_unsent(_, _, _), do: {:error, :corrupt_receipt}

  defp current_receipts(db, identities) do
    Enum.reduce_while(identities, {:ok, []}, fn [principal, epoch, operation], {:ok, receipts} ->
      with {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
           {:ok, receipt} <- RequestLedger.decode_receipt(principal, epoch, operation, row),
           do: {:cont, {:ok, receipts ++ [receipt]}},
           else: (
             {:error, reason} -> {:halt, {:error, reason}}
             _ -> {:halt, {:error, :corrupt_receipt}}
           )
    end)
  end

  defp advance_one(db, %{disposition: :held} = receipt, clock, qualification) do
    with {:ok, []} <- query(db, "SAVEPOINT schedule_admission") do
      case ExecutionWriter.admit_schedule_power_tx(
             db,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             qualification,
             clock
           ) do
        {:commit, {:ok, next}} ->
          with {:ok, []} <- query(db, "RELEASE schedule_admission"), do: {:ok, next, true}

        {:rollback, {:policy, reason}} ->
          with {:ok, []} <- query(db, "ROLLBACK TO schedule_admission"),
               {:ok, []} <- query(db, "RELEASE schedule_admission"),
               do: close_unsent(db, receipt, reason)

        {:rollback, reason} ->
          {:error, reason}
      end
    end
  end

  defp advance_one(db, receipt, clock, qualification) do
    # Keep original temporal refusal precedence, then repeat ordinary pending
    # execution guards even when no other row would make the pass commit.
    decision =
      with :ok <-
             execution_guard(
               db,
               receipt.principal_id,
               receipt.authority_epoch,
               receipt.operation_id,
               clock
             ),
           {boot, now} = ClockContext.receipt(clock),
           {:ok, guard} when is_map(guard) <-
             ExecutionWriter.commit_context(db, receipt, clock, qualification, boot, now),
           do: ExecutionWriter.final_power_decision(db, guard, {:commit, :unchanged})

    case decision do
      {:commit, :unchanged} -> {:ok, receipt, false}
      {:rollback, {:policy, reason}} -> close_unsent(db, receipt, reason)
      {:rollback, reason} -> {:error, reason}
      {:error, reason} when reason in @corrupt -> {:error, reason}
      {:error, reason} when is_atom(reason) -> close_unsent(db, receipt, reason)
      {:error, _} = error -> error
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp close_unsent(db, receipt, reason) do
    reason = "schedule_blocked:" <> Atom.to_string(reason)

    result =
      case receipt.disposition do
        :held ->
          RequestInvalidator.reject_held(
            db,
            receipt.principal_id,
            receipt.authority_epoch,
            receipt.operation_id,
            reason
          )

        state when state in [:queued, :claimed] ->
          RequestInvalidator.invalidate_execution_row(
            db,
            receipt.principal_id,
            receipt.authority_epoch,
            receipt.operation_id,
            Atom.to_string(state),
            reason
          )
      end

    case result do
      {:ok, revision} ->
        {:ok, %{receipt | disposition: :rejected, reason: reason, revision: revision}, true}

      error ->
        error
    end
  end

  @doc "Borrowed execution-owner refusal after a delivery failure. Cannot recall or reject an owned claim or handed effect."
  def close_delivery(db, %{disposition: phase} = receipt, reason) when phase in [:held, :queued],
    do: close_unsent(db, receipt, reason)

  @doc "Called only while publishing a newly consumed eligible occurrence in the same Store transaction."
  def open(db, record, revision, activation, artifact, clock, receipt_limit) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, original, _} <- ActivationClock.decode(record.clock_document),
         :ok <-
           current_guards(db, activation, artifact, original, record.occurrence_document, clock),
         {target, "power", value} = artifact.rule.effect,
         {:ok, mutation} <-
           Mutation.new(%{
             "api_version" => 1,
             "authority_epoch" => activation.epoch,
             "operation_id" => record.occurrence_id,
             "expected_revision" => artifact.source["resource_revision"],
             "target_id" => target,
             "capability_key" => "power",
             "value" => %{"type" => "boolean", "value" => value.data}
           }),
         {:commit, {:ok, request}} <-
           RequestLedger.submit_schedule_tx(db, activation.principal, mutation, receipt_limit) do
      decision = if request.disposition == :held, do: "held", else: "blocked"

      publish(
        db,
        revision,
        activation.principal,
        activation.epoch,
        record.occurrence_id,
        decision,
        request.reason,
        request.revision,
        original.scope["runtime_digest"]
      )
    else
      {:error, reason} when reason in @corrupt ->
        {:error, reason}

      {:rollback, reason} when reason in @corrupt ->
        {:error, reason}

      {:error, reason} when is_atom(reason) ->
        blocked(db, record, revision, activation, reason)

      {:rollback, {:policy, reason}} when is_atom(reason) ->
        blocked(db, record, revision, activation, reason)

      # Capacity is a terminal occurrence refusal; actual SQL failures roll back.
      {:rollback, :receipt_capacity} ->
        blocked(db, record, revision, activation, :receipt_capacity)

      {:rollback, reason} ->
        {:error, reason}

      error ->
        error
    end
  end

  defp blocked(db, record, revision, activation, reason) do
    with {:ok, snapshot, _} <- ActivationClock.decode(record.clock_document),
         do:
           publish(
             db,
             revision,
             activation.principal,
             activation.epoch,
             record.occurrence_id,
             "blocked",
             Atom.to_string(reason),
             nil,
             snapshot.scope["runtime_digest"]
           )
  end

  defp publish(db, considered, principal, epoch, operation, decision, reason, request, runtime) do
    with {:ok, revision} <- Journal.next_revision(db),
         :ok <- Journal.authority_event(db, revision, "schedule_effect_" <> decision, operation),
         {:ok, []} <-
           query(db, "INSERT INTO schedule_effect_operations VALUES (?,?,?,?,?,?,?,?,?)", [
             considered,
             principal,
             epoch,
             operation,
             decision,
             reason,
             request,
             runtime,
             revision
           ]),
         do:
           {:ok,
            %{
              state: String.to_existing_atom(decision),
              reason: reason,
              principal_id: principal,
              authority_epoch: epoch,
              operation_id: operation,
              request_revision: request,
              revision: revision
            }}
  end

  @doc "The shared rule guard calls this at queue, no-send closure, claim and final handoff."
  def execution_guard(db, principal, epoch, operation, clock) do
    with {:ok, [[origin]]} <-
           query(
             db,
             "SELECT origin FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case origin do
        "schedule_occurrence" ->
          with :ok <- validate(db),
               {:ok, [row]} <-
                 query(
                   db,
                   "SELECT #{@columns} FROM schedule_effect_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
                   [principal, epoch, operation]
                 ),
               {:ok, record, activation, artifact, original} <- historical(db, row),
               :ok <- MaintenanceWriter.guard(db),
               {:ok, current, current_artifact} <- ScheduleLifecycle.current_activation(db),
               true <- current.revision == activation.revision and current.principal == principal,
               true <- current_artifact.source_document == artifact.source_document,
               do:
                 current_guards(
                   db,
                   current,
                   current_artifact,
                   original,
                   record.occurrence_document,
                   clock
                 ),
               else: (
                 false -> {:error, :schedule_basis_changed}
                 {:error, :schedule_inactive} -> {:error, :schedule_basis_changed}
                 {:ok, _} -> corrupt()
                 error -> error
               )

        kind when kind in ["explicit_request", "legacy_request"] ->
          with {:ok, [[version]]} <- query(db, "PRAGMA user_version") do
            if version == 27 do
              case query(
                     db,
                     "SELECT 1 FROM schedule_effect_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
                     [principal, epoch, operation]
                   ) do
                {:ok, []} -> :ok
                _ -> corrupt()
              end
            else
              :ok
            end
          end

        _ ->
          corrupt()
      end
    else
      {:ok, _} -> corrupt()
      error -> error
    end
  end

  defp current_guards(db, activation, artifact, original, occurrence_document, clock) do
    observation = ClockContext.temporal(clock)

    with :ok <-
           ScheduleLifecycle.withdraw_countdown(
             db,
             activation,
             artifact.source,
             clock,
             observation
           ),
         :ok <- countdown_activation(db, artifact.source, activation),
         {:ok, snapshot} <- observation,
         true <- snapshot.scope == original.scope and snapshot.now_ms >= original.now_ms,
         true <- ActivationClock.ready(artifact.source, snapshot) == :ok,
         {:ok, zone} <- ClockContext.timezone(clock, artifact.source),
         true <- zone == artifact.timezone,
         {:ok, occurrence} <- Occurrence.decode(occurrence_document),
         {:ok, window} <-
           Window.check(
             artifact.source,
             occurrence,
             snapshot.sample,
             snapshot.scope["store_boot_epoch"],
             snapshot.scope["clock_generation"],
             snapshot.now_ms,
             zone
           ),
         :ok <- window(window),
         {boot, now} = ClockContext.receipt(clock),
         true <- boot == snapshot.scope["store_boot_epoch"] and now >= snapshot.now_ms,
         {:ok, :allow} <- InvariantWriter.decision(db, artifact.source["target_id"], clock),
         {:ok, nil} <-
           OverrideWriter.active_override_for_target(
             db,
             artifact.source["target_id"],
             activation.epoch,
             boot,
             now
           ),
         do: :ok,
         else: (
           false -> {:error, :temporal_basis_changed}
           {:ok, state} when state in [:deny, :unknown] -> {:error, :invariant_unresolved}
           {:ok, _lease} -> {:error, :operator_override_active}
           error -> error
         )
  end

  defp countdown_activation(db, %{"trigger" => ["countdown" | _]}, activation) do
    with {:ok, [[epoch, generation, revision]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='rule_generation'),(SELECT MAX(revision) FROM schedule_lifecycle_operations)"
           ),
         true <-
           {epoch, generation, revision} ==
             {activation.epoch, activation.generation, activation.revision},
         do: :ok,
         else: (
           false -> {:error, :schedule_basis_changed}
           error -> error
         )
  end

  defp countdown_activation(_, _, _), do: :ok

  defp window(:eligible), do: :ok
  defp window(:early), do: {:error, :occurrence_early}
  defp window(:expired), do: {:error, :occurrence_expired}
  defp window(:uncertain), do: {:error, :clock_uncertain}

  def original(db, considered) do
    case query(
           db,
           "SELECT #{@columns} FROM schedule_effect_operations WHERE consideration_revision=?",
           [considered]
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [[_, principal, epoch, operation, decision, reason, request, _, revision]]} ->
        {:ok,
         %{
           state: String.to_existing_atom(decision),
           reason: reason,
           principal_id: principal,
           authority_epoch: epoch,
           operation_id: operation,
           request_revision: request,
           revision: revision
         }}

      _ ->
        corrupt()
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[27]]} -> validate(db)
      {:ok, [[version]]} when version in 1..26 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM schedule_effect_operations ORDER BY revision LIMIT 4097"
           ),
         true <- length(rows) <= 4_096,
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('schedule_effect_held','schedule_effect_blocked')"
           ),
         true <- count == length(rows),
         true <- Enum.all?(rows, &match?({:ok, _, _, _, _}, historical(db, &1))),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_causal_roots c LEFT JOIN schedule_effect_operations s USING (principal_id,authority_epoch,operation_id) WHERE (c.origin='schedule_occurrence' AND (s.request_revision IS NULL OR s.request_revision IS NOT c.created_revision)) OR (s.request_revision IS NOT NULL AND c.origin!='schedule_occurrence')"
           ),
         do: :ok,
         else: (_ -> corrupt())
  rescue
    _ -> corrupt()
  end

  defp historical(db, [
         considered,
         principal,
         epoch,
         operation,
         decision,
         reason,
         request,
         runtime,
         revision
       ]) do
    with true <-
           Codec.integer?(considered, 1, Codec.maximum()) and
             Codec.integer?(revision, considered + 1, Codec.maximum()),
         true <-
           decision in ["held", "blocked"] and
             if(decision == "held",
               do: is_nil(reason) and is_integer(request),
               else: is_binary(reason) and byte_size(reason) in 1..128
             ),
         {:ok, [row]} <-
           query(
             db,
             "SELECT #{WotexHome.Durable.Store.ScheduleOccurrences.columns()} FROM schedule_considerations WHERE revision=? AND decision='eligible' AND occurrence_id=?",
             [considered, operation]
           ),
         {values, [_]} = Enum.split(row, length(WotexHome.Schedules.Consideration.fields())),
         record = Map.new(Enum.zip(WotexHome.Schedules.Consideration.fields(), values)),
         {:ok, activation} <-
           ScheduleLifecycle.retained_activation(db, record.activation_revision),
         true <- activation.principal == principal and activation.epoch == epoch,
         {:ok, artifact} <- ScheduleWriter.retained_admission(db, activation.admission),
         true <- WotexHome.Schedules.Consideration.valid?(record, activation, artifact),
         {:ok, original, _} <- ActivationClock.decode(record.clock_document),
         true <- original.scope["runtime_digest"] == runtime,
         {:ok, [[event, ^operation]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         true <- event == "schedule_effect_" <> decision,
         true <- revision == considered + if(is_nil(request), do: 1, else: 2),
         {:ok, [[current_revision]]} <- query(db, "SELECT value FROM meta WHERE key='revision'"),
         true <- revision <= current_revision,
         :ok <-
           request_binding(
             db,
             principal,
             epoch,
             operation,
             considered,
             request,
             decision,
             reason,
             artifact
           ),
         do: {:ok, record, activation, artifact, original},
         else: (_ -> corrupt())
  end

  defp request_binding(
         _db,
         _principal,
         _epoch,
         _operation,
         _considered,
         nil,
         "blocked",
         _reason,
         _artifact
       ),
       do: :ok

  defp request_binding(
         db,
         principal,
         epoch,
         operation,
         considered,
         request,
         decision,
         reason,
         artifact
       ) do
    {target, "power", value} = artifact.rule.effect
    encoded = if(value.data, do: "1", else: "0")
    disposition = if(decision == "held", do: "held", else: "rejected")

    with true <- request == considered + 1,
         {:ok, [[resource, ^target, "power", "boolean", ^encoded, nil, profile]]} <-
           query(
             db,
             "SELECT expected_revision,target_id,capability_key,value_kind,value_a,value_b,profile_ref FROM request_receipts WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ),
         true <-
           resource == artifact.source["resource_revision"] and
             profile == artifact.things[target].profile_ref,
         {:ok, [[^disposition, ^reason]]} <-
           query(
             db,
             "SELECT disposition,reason FROM request_journal WHERE revision=? AND principal_id=? AND authority_epoch=? AND operation_id=?",
             [request, principal, epoch, operation]
           ),
         {:ok, [["schedule_occurrence", ^request, nil, nil]]} <-
           query(
             db,
             "SELECT origin,created_revision,rule_admission_revision,rule_generation FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp corrupt, do: {:error, :corrupt_schedule_effect}
end
