defmodule WotexHome.Durable.Store.ScheduleLifecycle do
  @moduledoc "Store-owned single-schedule activation and suspension history. No runner, occurrence creation or device dispatch."
  alias WotexHome.Id

  alias WotexHome.Durable.Store.{
    Access,
    ClockContext,
    ExecutionWriter,
    Journal,
    MaintenanceWriter,
    RequestInvalidator,
    ScheduleWriter
  }

  alias WotexHome.Schedules.{
    ActivationClock,
    AdmissionArtifact,
    Codec,
    CountdownExpiry,
    OperationInput
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @fields ~w(principal_id authority_epoch operation_id kind expected_revision input_document admission_revision previous_generation generation barrier_revision revision affected_requests unknown_outcomes reason clock_document initial_watermark)
  @columns Enum.join(@fields, ",")
  @capacity 1_024
  @public_capacity 960
  @byte_limit 8_388_608
  @withdraw_prefix "schedule-withdraw:"
  @withdraw_format "wotex-home.schedule-withdrawal.v1"
  @corrupt ~w(corrupt_schedule_lifecycle corrupt_schedule_admission corrupt_controller_history corrupt_maintenance corrupt_invariant corrupt_value corrupt_override corrupt_receipt corrupt_enrollment corrupt_principal corrupt_native_setup corrupt_native_target_history corrupt_profile_ledger corrupt_qualification_history corrupt_rule_admission)a

  defmodule Withdrawal do
    @moduledoc false
    @enforce_keys [:activation, :withdrawal]
    defstruct @enforce_keys
  end

  def columns, do: @columns

  def change(db, credential, document, clock) do
    policy(fn ->
      with {:ok, kind, input} when kind in ["activate", "suspend"] <-
             OperationInput.decode(document),
           {:ok, actor} <- actor(db, credential, :manage),
           :ok <- validate(db),
           {:ok, rows} <- original(db, actor, input["authority_epoch"], input["operation_id"]) do
        case rows do
          [row] ->
            with {:ok, retained} <- historical(db, row),
                 true <- retained.input_document == document,
                 do: {:rollback, {:unchanged, {:ok, receipt(retained)}}},
                 else: (
                   false -> {:error, :schedule_operation_conflict}
                   error -> error
                 )

          [] ->
            with :ok <- unused(db, actor, input["authority_epoch"], input["operation_id"]),
                 :ok <- compare(db, input),
                 :ok <- capacity(db, @public_capacity, byte_size(document) + 4_096),
                 {:ok, admission, clock_document, watermark} <-
                   basis(db, actor, kind, input, clock),
                 do:
                   publish(
                     db,
                     actor,
                     kind,
                     input,
                     document,
                     admission,
                     nil,
                     clock_document,
                     watermark,
                     clock
                   )

          _ ->
            corrupt()
        end
      else
        {:ok, _, _} -> {:error, :unsupported_schedule_operation}
        error -> error
      end
    end)
  end

  def original_status(db, credential, document) do
    with {:ok, kind, input} when kind in ["activate", "suspend"] <-
           OperationInput.decode(document),
         {:ok, actor} <- actor(db, credential, :read),
         :ok <- validate(db),
         {:ok, rows} <- original(db, actor, input["authority_epoch"], input["operation_id"]) do
      case rows do
        [] ->
          :not_found

        [row] ->
          with {:ok, retained} <- historical(db, row),
               true <- retained.input_document == document,
               do: {:ok, receipt(retained)},
               else: (
                 false -> {:error, :schedule_operation_conflict}
                 error -> error
               )

        _ ->
          corrupt()
      end
    else
      {:ok, _, _} -> {:error, :unsupported_schedule_operation}
      error -> error
    end
  end

  def status(db, credential, clock) do
    with {:ok, actor} <- actor(db, credential, :read),
         :ok <- validate(db),
         {:ok, head} <- principal_head(db, actor) do
      case head do
        nil ->
          {:ok, %{state: :inactive, activation_revision: 0, reason: nil}}

        %{principal: ^actor} ->
          with {:ok, state} <- disposition(db, head, clock),
               do: {:ok, Map.merge(receipt(head), state)}

        _ ->
          :not_found
      end
    end
  end

  @doc "Internal original active definition. The caller must establish clock, occurrence and execution guards separately."
  def current_activation(db) do
    with {:ok, %{kind: "activate"} = head} <- head(db),
         {:ok, [[_, epoch, generation]]} <- meta(db),
         true <- {epoch, generation} == {head.epoch, head.generation},
         {:ok, artifact, _} <- ScheduleWriter.current_admission(db, head.admission),
         do: {:ok, head, artifact},
         else: (
           {:ok, _} -> {:error, :schedule_inactive}
           false -> {:error, :schedule_inactive}
           error -> error
         )
  end

  @doc "Original activation only; no current generation, author or clock authority."
  def retained_activation(db, revision) do
    with {:ok, [row]} <-
           query(db, "SELECT #{@columns} FROM schedule_lifecycle_operations WHERE revision=?", [
             revision
           ]),
         {:ok, %{kind: "activate"} = activation} <- historical(db, row),
         do: {:ok, activation},
         else: (_ -> {:error, :corrupt_schedule_lifecycle})
  end

  # Called inside the same Store transaction as a changed authority basis.
  # An existing generation barrier already makes old work permanently inert;
  # never fence again and erase a newly activated explicit rule set.
  def withdraw_invalidated(db, clock \\ nil) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [25, 26, 27] -> withdraw_current(db, clock)
      {:ok, [[version]]} when version in 1..24 -> :ok
      _ -> corrupt()
    end
  end

  # Callers have already validated and retained this exact activation/artifact.
  # Read the current pointer/CAS without repeating expensive artifact custody
  # inside each effect guard; that guard independently repeats current admission.
  def withdraw_countdown(
        db,
        activation,
        %{"trigger" => ["countdown" | _]} = source,
        clock,
        observation
      ) do
    with {:ok, [meta]} <- meta(db),
         {:ok, [[head_revision]]} <-
           query(db, "SELECT MAX(revision) FROM schedule_lifecycle_operations") do
      case meta do
        [revision, epoch, generation]
        when epoch == activation.epoch and generation == activation.generation and
               head_revision == activation.revision ->
          withdraw_clock(db, activation, revision, source, clock, observation)

        _ ->
          :ok
      end
    end
  end

  def withdraw_countdown(_, _, _, _, _), do: :ok

  @doc "Borrowed Store-only evidence of an actually published withdrawal, before undoing tentative power work. Never accepted by an authority route."
  def withdrawal_receipt(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [25, 26, 27] ->
        with {:ok, current} <- head(db) do
          case current do
            %{kind: "withdraw"} = withdrawal ->
              with {:ok, revision} <- withdrawn_activation(withdrawal.input_document),
                   {:ok, activation} <- retained_activation(db, revision),
                   do: {:ok, %Withdrawal{activation: activation, withdrawal: withdrawal}}

            _ ->
              {:ok, nil}
          end
        end

      {:ok, [[version]]} when version in 1..24 ->
        {:ok, nil}

      _ ->
        corrupt()
    end
  end

  @doc "Retain a detected loss against its exact original activation after savepoint restoration; returning custody cannot revive that generation."
  def retain_withdrawal(db, nil), do: withdraw_invalidated(db)

  def retain_withdrawal(db, %Withdrawal{activation: activation, withdrawal: withdrawal}) do
    with {:ok, current} <- head(db), {:ok, [meta]} <- meta(db) do
      cond do
        current == withdrawal ->
          :ok

        current == activation and
            {Enum.at(meta, 1), Enum.at(meta, 2)} == {activation.epoch, activation.generation} ->
          with {:ok, expiry} <- expiry_frame(withdrawal.input_document),
               do: publish_withdrawal(db, activation, hd(meta), withdrawal.reason, expiry)

        true ->
          corrupt()
      end
    end
  end

  def retain_withdrawal(_, _), do: corrupt()

  defp withdraw_current(db, clock) do
    with {:ok, head} <- head(db), {:ok, [meta]} <- meta(db) do
      case {head, meta} do
        {%{kind: "activate", generation: generation, epoch: epoch} = head,
         [revision, epoch, generation]} ->
          current =
            with {:ok, artifact, principal} <-
                   ScheduleWriter.current_admission(db, head.admission),
                 {:ok, _} <- WotexHome.Schedules.Timezone.source(artifact.source),
                 do: {:ok, artifact, principal}

          case current do
            {:ok, artifact, _} ->
              withdraw_clock(db, head, revision, artifact.source, clock)

            {:error, reason} when reason in @corrupt ->
              {:error, reason}

            {:error, reason} when is_atom(reason) ->
              publish_withdrawal(db, head, revision, Atom.to_string(reason))

            _ ->
              corrupt()
          end

        _ ->
          :ok
      end
    end
  end

  @doc "Actual new Store boot only; historical source bytes establish expiry identity, never current runtime or time authority. Called inside the startup recovery transaction."
  def expire_boot(db, boot) do
    with true <- WotexHome.Id.valid?(boot),
         :ok <- validate_if_current(db),
         {:ok, head} <- head(db),
         {:ok, [meta]} <- meta(db) do
      case {head, meta} do
        {%{kind: "activate", epoch: epoch, generation: generation} = activation,
         [revision, epoch, generation]} ->
          with {:ok, artifact} <- ScheduleWriter.retained_admission(db, activation.admission) do
            case artifact.source["trigger"] do
              ["countdown", original_boot, _, _, _] when original_boot != boot ->
                publish_withdrawal(
                  db,
                  activation,
                  revision,
                  "countdown_missed:old_boot",
                  {boot, 1}
                )

              _ ->
                :ok
            end
          end

        _ ->
          :ok
      end
    else
      false -> corrupt()
      error -> error
    end
  end

  @doc "Actual Store clock-generation withdrawal only, inside its durable transaction. Zero records exhaustion, never a qualified clock."
  def expire_clock(db, boot, clock_generation) do
    with true <-
           WotexHome.Id.valid?(boot) and Codec.integer?(clock_generation, 0, Codec.maximum()),
         :ok <- validate_if_current(db),
         {:ok, head} <- head(db),
         {:ok, [meta]} <- meta(db) do
      case {head, meta} do
        {%{kind: "activate", epoch: epoch, generation: generation} = activation,
         [revision, epoch, generation]} ->
          with {:ok, artifact} <- ScheduleWriter.retained_admission(db, activation.admission) do
            case artifact.source["trigger"] do
              ["countdown", ^boot, bound_generation, _, _]
              when bound_generation != clock_generation ->
                publish_withdrawal(
                  db,
                  activation,
                  revision,
                  "countdown_missed:clock_changed",
                  {boot, clock_generation}
                )

              _ ->
                :ok
            end
          end

        _ ->
          :ok
      end
    else
      false -> corrupt()
      error -> error
    end
  end

  defp withdraw_clock(db, head, revision, source, clock, observation \\ :read)
  defp withdraw_clock(_db, _head, _revision, _source, nil, _observation), do: :ok

  defp withdraw_clock(
         db,
         head,
         revision,
         %{"trigger" => ["countdown", bound_boot, bound_generation, _, _]} = source,
         clock,
         observation
       ) do
    {boot, now} = ClockContext.receipt(clock)

    with true <- WotexHome.Id.valid?(boot) and Codec.integer?(now, 0, Codec.maximum()) do
      cond do
        boot != bound_boot ->
          # The original boot alone is sufficient; no new clock confidence is inferred.
          case temporal_observation(clock, observation) do
            {:ok, snapshot} ->
              publish_withdrawal(
                db,
                head,
                revision,
                "countdown_missed:old_boot",
                {boot, snapshot.scope["clock_generation"]}
              )

            error ->
              error
          end

        true ->
          case temporal_observation(clock, observation) do
            {:ok, snapshot} ->
              generation = snapshot.scope["clock_generation"]

              cond do
                generation != bound_generation ->
                  publish_withdrawal(
                    db,
                    head,
                    revision,
                    "countdown_missed:clock_changed",
                    {boot, generation}
                  )

                ActivationClock.ready(source, snapshot) == :ok ->
                  :ok

                true ->
                  publish_withdrawal(
                    db,
                    head,
                    revision,
                    "countdown_missed:clock_unavailable",
                    {boot, generation}
                  )
              end

            {:error, :temporal_clock_unavailable} ->
              publish_withdrawal(
                db,
                head,
                revision,
                "countdown_missed:clock_unavailable",
                {boot, nil}
              )

            error ->
              error
          end
      end
    else
      false -> {:error, :temporal_clock_unavailable}
    end
  end

  defp withdraw_clock(_, _, _, _, _, _), do: :ok

  defp temporal_observation(clock, :read), do: ClockContext.temporal(clock)
  defp temporal_observation(_, observation), do: observation

  defp publish_withdrawal(db, activation, revision, reason, expiry \\ nil) do
    with {:ok, document} <- withdrawal_document(activation, revision, reason, expiry),
         do: publish_withdrawal_document(db, activation, revision, reason, document)
  end

  defp withdrawal_document(activation, revision, reason, nil),
    do:
      {:ok,
       JSON.encode!([@withdraw_format, activation.revision, activation.epoch, revision, reason])}

  defp withdrawal_document(
         activation,
         revision,
         "countdown_missed:" <> reason,
         {boot, generation}
       ) do
    case reason do
      "old_boot" ->
        CountdownExpiry.build(activation, revision, :old_boot, boot, generation)

      "clock_changed" ->
        CountdownExpiry.build(activation, revision, :clock_changed, boot, generation)

      "clock_unavailable" ->
        CountdownExpiry.build(activation, revision, :clock_unavailable, boot, generation)

      _ ->
        corrupt()
    end
  end

  defp withdrawal_document(_, _, _, _), do: corrupt()

  defp withdrawn_activation(document) do
    case Codec.record(document) do
      {:ok, [@withdraw_format, revision, _, _, _]} ->
        {:ok, revision}

      _ ->
        with {:ok, record} <- CountdownExpiry.decode(document),
             do: {:ok, record.activation_revision}
    end
  end

  defp expiry_frame(document) do
    case Codec.record(document) do
      {:ok, [@withdraw_format, _, _, _, _]} ->
        {:ok, nil}

      _ ->
        with {:ok, record} <- CountdownExpiry.decode(document),
             do: {:ok, {record.boot_epoch, record.clock_generation}}
    end
  end

  defp publish_withdrawal_document(db, activation, revision, reason, document) do
    operation = @withdraw_prefix <> Codec.hash(document)

    input = %{
      "authority_epoch" => activation.epoch,
      "operation_id" => operation,
      "expected_revision" => revision
    }

    with :ok <- capacity(db, @capacity, byte_size(document)),
         {:commit, {:ok, _}} <-
           publish(
             db,
             activation.principal,
             "withdraw",
             input,
             document,
             activation.admission,
             reason,
             nil,
             -1
           ),
         do: :ok,
         else: (
           {:rollback, reason} -> {:error, reason}
           error -> error
         )
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [25, 26, 27] -> validate(db)
      {:ok, [[version]]} when version in 1..24 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, [[revision, epoch, generation]]} <- meta(db),
         true <-
           Codec.integer?(revision, 0, Codec.maximum()) and
             Codec.integer?(epoch, 1, Codec.maximum()) and
             Codec.integer?(generation, 0, Codec.maximum()),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM schedule_lifecycle_operations ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= @capacity,
         true <- rows == [] or generation_link?(db, generation),
         :ok <- current_projection(db, epoch, generation),
         true <-
           Enum.reduce(rows, 0, fn row, sum ->
             sum + byte_size(Enum.at(row, 5)) +
               if(is_binary(Enum.at(row, 14)), do: byte_size(Enum.at(row, 14)), else: 0)
           end) <= @byte_limit,
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('schedule_activated','schedule_suspended','schedule_withdrawn')"
           ),
         true <- count == length(rows),
         true <- Enum.all?(rows, &match?({:ok, _}, historical(db, &1))),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM schedule_lifecycle_operations l JOIN schedule_admissions a USING (principal_id,authority_epoch,operation_id)"
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM (SELECT barrier_revision FROM schedule_lifecycle_operations GROUP BY barrier_revision HAVING COUNT(*)>1)"
           ),
         do: :ok,
         else: (_ -> corrupt())
  rescue
    _ -> corrupt()
  end

  defp generation_link?(db, generation),
    do:
      query(
        db,
        "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced','rule_policy_activated')"
      ) == {:ok, [[generation]]}

  defp current_projection(db, epoch, generation) do
    with {:ok, [[count, explicit_admission]]} <-
           query(
             db,
             "SELECT (SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE kind='activate' AND authority_epoch=? AND generation=?),(SELECT value FROM meta WHERE key='active_rule_admission')",
             [epoch, generation]
           ),
         true <- count == 0 or (count == 1 and explicit_admission == 0),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp basis(db, actor, "activate", input, clock) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, artifact, ^actor} <-
           ScheduleWriter.current_admission(db, input["admission_revision"]),
         {:ok, document, watermark} <- ActivationClock.capture(artifact.source, clock),
         :ok <- countdown_not_expired(db, artifact),
         {:ok, snapshot, ^watermark} <- ActivationClock.decode(document),
         true <- snapshot.scope["authority_epoch"] == input["authority_epoch"],
         do: {:ok, input["admission_revision"], document, watermark},
         else: (
           {:ok, _, _} -> {:error, :permission_denied}
           false -> {:error, :stale_authority_epoch}
           error -> error
         )
  end

  defp basis(_, _, "suspend", _, _), do: {:ok, 0, nil, -1}

  defp countdown_not_expired(db, %{source: %{"trigger" => ["countdown" | _]}} = artifact) do
    with {:ok, documents} <-
           query(
             db,
             "SELECT DISTINCT a.artifact_document FROM schedule_lifecycle_operations l JOIN schedule_admissions a ON a.revision=l.admission_revision WHERE l.kind='withdraw' AND l.reason IN ('countdown_missed:old_boot','countdown_missed:clock_changed','countdown_missed:clock_unavailable')"
           ) do
      Enum.reduce_while(documents, :ok, fn [document], :ok ->
        case AdmissionArtifact.decode(document) do
          {:ok, retained} ->
            if retained.source_document == artifact.source_document,
              do: {:halt, {:error, :schedule_elapsed}},
              else: {:cont, :ok}

          _ ->
            {:halt, corrupt()}
        end
      end)
    end
  end

  defp countdown_not_expired(_, _), do: :ok

  defp publish(
         db,
         principal,
         kind,
         input,
         document,
         admission,
         reason,
         clock_document,
         watermark,
         clock \\ nil
       ) do
    epoch = input["authority_epoch"]
    expected = input["expected_revision"]
    operation = input["operation_id"]

    with {:ok, [[^expected, ^epoch, previous]]} <- meta(db),
         {:ok, pending} <- RequestInvalidator.pending_execution_rows(db, :all),
         unknown = Enum.count(pending, &(List.last(&1) in ["dispatching", "protocol_accepted"])),
         {:commit, {:ok, barrier}} <-
           ExecutionWriter.fence_rule_generation_tx(db, expected, epoch),
         {:ok, clock_document, watermark} <-
           refresh_clock(db, kind, admission, clock_document, watermark, clock),
         {:ok, revision} <- Journal.next_revision(db),
         :ok <-
           Journal.authority_event(db, revision, event(kind), entity(principal, epoch, operation)),
         values = [
           principal,
           epoch,
           operation,
           kind,
           expected,
           document,
           admission,
           previous,
           barrier.rule_generation,
           expected + 1,
           revision,
           barrier.affected_requests,
           unknown,
           reason,
           clock_document,
           watermark
         ],
         {:ok, []} <-
           query(
             db,
             "INSERT INTO schedule_lifecycle_operations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
             values
           ),
         {:ok, retained} <- historical(db, values),
         :ok <- repeat_clock(db, kind, admission, clock_document, clock),
         do: {:commit, {:ok, receipt(retained)}},
         else: (error -> error)
  end

  defp historical(db, [
         principal,
         epoch,
         operation,
         kind,
         expected,
         document,
         admission,
         previous,
         generation,
         barrier,
         revision,
         affected,
         unknown,
         reason,
         clock_document,
         watermark
       ]) do
    with true <- Id.valid?(principal) and Id.valid?(operation),
         true <- Codec.integer?(epoch, 1, Codec.maximum()),
         true <-
           Enum.all?(
             [expected, admission, previous, generation, barrier, revision, affected, unknown],
             &Codec.integer?(&1, 0, Codec.maximum())
           ),
         true <- kind in ["activate", "suspend", "withdraw"],
         true <- admission <= expected,
         true <- barrier == expected + 1 and generation == previous + 1,
         true <- revision == barrier + affected + 1 and affected <= 1_024 and unknown <= affected,
         :ok <-
           historical_input(
             db,
             principal,
             epoch,
             operation,
             kind,
             expected,
             document,
             admission,
             reason
           ),
         :ok <- historical_clock(db, principal, epoch, kind, admission, clock_document, watermark),
         {:ok, [["rule_generation_fenced", "rules:empty"]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             barrier
           ]),
         {:ok, [[journal_event, journal_entity]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         true <-
           journal_event == event(kind) and journal_entity == entity(principal, epoch, operation),
         {:ok, [[^generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced','rule_policy_activated') AND revision<=?",
             [barrier]
           ),
         {:ok, [[^affected, ^unknown]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(disposition='outcome_unknown'),0) FROM request_journal WHERE revision>? AND revision<? AND ((disposition='rejected' AND reason='rule_generation_fenced') OR (disposition='outcome_unknown' AND reason='rule_generation_fenced_after_handoff'))",
             [barrier, revision]
           ),
         {:ok, [[current, current_epoch, current_generation]]} <- meta(db),
         true <-
           revision <= current and epoch <= current_epoch and generation <= current_generation,
         {:ok, [[1]]} <-
           query(db, "SELECT COUNT(*) FROM principals WHERE principal_id=?", [principal]),
         do:
           {:ok,
            %{
              principal: principal,
              epoch: epoch,
              operation: operation,
              kind: kind,
              expected: expected,
              input_document: document,
              admission: admission,
              previous_generation: previous,
              generation: generation,
              barrier: barrier,
              revision: revision,
              affected: affected,
              unknown: unknown,
              reason: reason,
              clock_document: clock_document,
              watermark: watermark
            }},
         else: (_ -> corrupt())
  end

  defp historical(_, _), do: corrupt()

  defp historical_input(_, _, epoch, operation, kind, expected, document, admission, nil)
       when kind in ["activate", "suspend"] do
    with false <- String.starts_with?(operation, @withdraw_prefix),
         {:ok, ^kind, input} <- OperationInput.decode(document),
         true <-
           {epoch, operation, expected} ==
             {input["authority_epoch"], input["operation_id"], input["expected_revision"]},
         true <- admission == Map.get(input, "admission_revision", 0),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp historical_input(
         db,
         principal,
         epoch,
         operation,
         "withdraw",
         expected,
         document,
         admission,
         reason
       ) do
    with true <- is_binary(reason) and byte_size(reason) in 1..128,
         {:ok, head_revision} <- withdrawal_input(document, epoch, expected, reason),
         true <- operation == @withdraw_prefix <> Codec.hash(document),
         {:ok, [[^principal, "activate", ^admission, generation]]} <-
           query(
             db,
             "SELECT principal_id,kind,admission_revision,generation FROM schedule_lifecycle_operations WHERE revision=?",
             [head_revision]
           ),
         true <- head_revision <= expected,
         {:ok, [[^generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced','rule_policy_activated') AND revision<=?",
             [expected]
           ),
         {:ok, [[^head_revision]]} <-
           query(
             db,
             "SELECT MAX(revision) FROM schedule_lifecycle_operations WHERE revision<=?",
             [expected]
           ),
         :ok <- withdrawal_source(db, document, admission),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp historical_input(_, _, _, _, _, _, _, _, _), do: corrupt()

  defp withdrawal_input(document, epoch, expected, reason) do
    case Codec.record(document) do
      {:ok, [@withdraw_format, revision, ^epoch, ^expected, ^reason]} ->
        if not String.starts_with?(reason, "countdown_missed:") and
             document == JSON.encode!([@withdraw_format, revision, epoch, expected, reason]),
           do: {:ok, revision},
           else: corrupt()

      _ ->
        with {:ok, record} <- CountdownExpiry.decode(document),
             true <-
               {record.authority_epoch, record.expected_revision, record.reason} ==
                 {epoch, expected, reason},
             do: {:ok, record.activation_revision},
             else: (_ -> corrupt())
    end
  end

  defp withdrawal_source(db, document, admission) do
    case expiry_frame(document) do
      {:ok, nil} ->
        :ok

      {:ok, _} ->
        with {:ok, record} <- CountdownExpiry.decode(document),
             {:ok, artifact} <- ScheduleWriter.retained_admission(db, admission),
             true <- CountdownExpiry.for_source?(record, artifact.source),
             do: :ok,
             else: (_ -> corrupt())

      _ ->
        corrupt()
    end
  end

  defp historical_clock(db, principal, epoch, "activate", admission, document, watermark) do
    with {:ok, [[^principal, ^epoch, "admit", artifact_document]]} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,kind,artifact_document FROM schedule_admissions WHERE revision=?",
             [admission]
           ),
         {:ok, artifact} <- AdmissionArtifact.decode(artifact_document),
         {:ok, snapshot, ^watermark} <- ActivationClock.decode(document),
         true <- snapshot.scope["authority_epoch"] == epoch,
         :ok <- owner_link(db, admission, snapshot.scope),
         {:ok, ^watermark} <- ActivationClock.initial(artifact.source, snapshot),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp historical_clock(_, _, _, kind, _, nil, -1) when kind in ["suspend", "withdraw"], do: :ok
  defp historical_clock(_, _, _, _, _, _, _), do: corrupt()

  defp owner_link(db, admission, scope) do
    with {:ok, [[deployment, origin_document]]} <-
           query(
             db,
             "SELECT deployment_id,origin_document FROM controller_identity WHERE singleton=1"
           ),
         true <- deployment == scope["deployment_id"],
         {:ok, origin} <- WotexHome.Recovery.ControllerCodec.decode("origin", origin_document),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM controller_acceptances WHERE revision<=? ORDER BY revision DESC LIMIT 1",
             [admission]
           ),
         {:ok, owner, epoch} <- historical_owner(rows, origin),
         true <- {owner, epoch} == {scope["owner_id"], scope["authority_epoch"]},
         do: :ok,
         else: (_ -> corrupt())
  end

  defp historical_owner([], origin), do: {:ok, origin["owner_id"], origin["authority_epoch"]}

  defp historical_owner([[document]], _) do
    with {:ok, receipt} <-
           WotexHome.Recovery.TransferAcceptanceCodec.decode("acceptance", document),
         do: {:ok, receipt["destination_owner_id"], receipt["authority_epoch"]}
  end

  defp historical_owner(_, _), do: corrupt()

  defp refresh_clock(db, "activate", admission, _, _, clock) do
    with {:ok, artifact, _} <- ScheduleWriter.current_admission(db, admission),
         do: ActivationClock.capture(artifact.source, clock)
  end

  defp refresh_clock(_, _, _, document, watermark, _), do: {:ok, document, watermark}

  defp repeat_clock(db, "activate", admission, document, clock) do
    with {:ok, original, _} <- ActivationClock.decode(document),
         {:ok, artifact, _} <- ScheduleWriter.current_admission(db, admission),
         {:ok, current_document, _} <- ActivationClock.capture(artifact.source, clock),
         {:ok, current, _} <- ActivationClock.decode(current_document),
         true <- original.scope == current.scope and current.now_ms >= original.now_ms,
         do: :ok,
         else: (
           false -> {:error, :clock_changed}
           error -> error
         )
  end

  defp repeat_clock(_, _, _, _, _), do: :ok

  defp disposition(db, %{kind: "activate"} = head, clock) do
    with {:ok, [[_, epoch, generation]]} <- meta(db),
         true <- {epoch, generation} == {head.epoch, head.generation},
         {:ok, artifact, _} <- ScheduleWriter.current_admission(db, head.admission),
         {:ok, _} <- ActivationClock.current(artifact.source, clock),
         do: {:ok, %{state: :active, reason: nil}},
         else: (
           false -> {:ok, %{state: :suspended, reason: :stale_rule_generation}}
           {:error, reason} when reason in @corrupt -> {:error, reason}
           {:error, reason} -> {:ok, %{state: :suspended, reason: reason}}
           _ -> corrupt()
         )
  end

  defp disposition(_, head, _),
    do: {:ok, %{state: :suspended, reason: head.reason || :explicit_suspension}}

  defp receipt(row),
    do: %{
      kind: row.kind,
      state: if(row.kind == "activate", do: :activated, else: :suspended),
      principal_id: row.principal,
      authority_epoch: row.epoch,
      operation_id: row.operation,
      input_digest: Codec.hash(row.input_document),
      admission_revision: row.admission,
      previous_generation: row.previous_generation,
      rule_generation: row.generation,
      barrier_revision: row.barrier,
      revision: row.revision,
      affected_requests: row.affected,
      unknown_outcomes: row.unknown,
      reason: row.reason,
      initial_watermark: row.watermark
    }

  defp head(db) do
    case query(
           db,
           "SELECT #{@columns} FROM schedule_lifecycle_operations ORDER BY revision DESC LIMIT 1"
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> historical(db, row)
      _ -> corrupt()
    end
  end

  defp principal_head(db, actor) do
    case query(
           db,
           "SELECT #{@columns} FROM schedule_lifecycle_operations WHERE principal_id=? ORDER BY revision DESC LIMIT 1",
           [actor]
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> historical(db, row)
      _ -> corrupt()
    end
  end

  defp original(db, actor, epoch, operation),
    do:
      query(
        db,
        "SELECT #{@columns} FROM schedule_lifecycle_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
        [actor, epoch, operation]
      )

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='rule_generation')"
      )

  defp actor(db, credential, :manage) do
    with {:ok, %{principal_id: actor}} <- ScheduleWriter.authorize(db, credential),
         do: {:ok, actor}
  end

  defp actor(db, credential, :read) do
    with {:ok, hash} <- WotexHome.Durable.Registry.credential_hash(credential),
         {:ok, actor, permissions} <- Access.authenticate(db, hash),
         true <- "rule:review" in permissions,
         do: {:ok, actor},
         else: (
           false -> {:error, :permission_denied}
           error -> error
         )
  end

  defp compare(db, input) do
    with {:ok, [[revision, epoch, _]]} <- meta(db) do
      cond do
        epoch != input["authority_epoch"] -> {:error, :stale_authority_epoch}
        revision != input["expected_revision"] -> {:error, :resnapshot_required}
        true -> :ok
      end
    end
  end

  def unused(db, actor, epoch, operation) do
    with false <- String.starts_with?(operation, @withdraw_prefix),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM schedule_admissions WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [actor, epoch, operation]
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM schedule_lifecycle_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [actor, epoch, operation]
           ),
         do: :ok,
         else: (_ -> {:error, :schedule_operation_conflict})
  end

  defp capacity(db, limit, extra) do
    with {:ok, [[count, bytes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))+COALESCE(length(CAST(clock_document AS BLOB)),0)),0) FROM schedule_lifecycle_operations"
           ),
         do:
           if(count < limit and bytes + extra <= @byte_limit,
             do: :ok,
             else: {:error, :schedule_lifecycle_capacity}
           )
  end

  defp event("activate"), do: "schedule_activated"
  defp event("suspend"), do: "schedule_suspended"
  defp event("withdraw"), do: "schedule_withdrawn"
  defp entity(principal, epoch, operation), do: "#{principal}/#{epoch}/#{operation}"
  defp corrupt, do: {:error, :corrupt_schedule_lifecycle}

  defp policy(fun) do
    case fun.() do
      {:error, reason} when reason in @corrupt -> {:rollback, reason}
      {:error, reason} when is_atom(reason) -> {:rollback, {:policy, reason}}
      {:error, reason} -> {:rollback, reason}
      other -> other
    end
  end
end
