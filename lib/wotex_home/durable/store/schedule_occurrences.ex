defmodule WotexHome.Durable.Store.ScheduleOccurrences do
  @moduledoc "Store-owned immutable occurrence consumption and no-repeat cursors, with separately retained temporal held-request provenance."
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ClockContext, Journal, ScheduleLifecycle, ScheduleWriter}
  alias WotexHome.Schedules.{ActivationClock, Codec, Consideration}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @columns Enum.join(Enum.map(Consideration.fields(), &Atom.to_string/1) ++ ["revision"], ",")
  @cursor_columns "activation_revision,considered_through,head_revision"
  @qualified_columns "c." <> String.replace(@columns, ",", ",c.")
  @capacity 4_096
  @byte_limit 4_194_304
  @corrupt ~w(corrupt_schedule_effect corrupt_schedule_occurrence corrupt_schedule_lifecycle corrupt_schedule_admission corrupt_controller_history corrupt_maintenance corrupt_invariant corrupt_value corrupt_override corrupt_receipt corrupt_enrollment corrupt_principal corrupt_native_setup corrupt_native_target_history corrupt_profile_ledger corrupt_qualification_history)a

  def columns, do: @columns
  def cursor_columns, do: @cursor_columns

  def consider(db, clock, receipt_limit \\ 65_536) do
    result =
      with :ok <- validate(db),
           :ok <- ScheduleLifecycle.withdraw_invalidated(db, clock),
           {:ok, basis} <- poll_basis(db, clock),
           {:ok, record} <-
             Consideration.build(
               basis.activation,
               basis.artifact,
               basis.snapshot,
               basis.watermark
             ) do
        publish_consideration(db, clock, receipt_limit, basis, record)
      else
        {:error, :schedule_inactive} -> {:commit, {:ok, %{state: :inactive}}}
        error -> error
      end

    policy(result)
  end

  @doc "Borrowed Store-only snapshot for calculation outside the writer; never caller-authored clock or source data."
  def prepare_poll(db, clock) do
    result =
      with :ok <- validate(db),
           :ok <- ScheduleLifecycle.withdraw_invalidated(db, clock),
           {:ok, basis} <- poll_basis(db, clock),
           do: {:commit, {:ok, basis}},
           else: (
             {:error, :schedule_inactive} -> {:commit, {:ok, :inactive}}
             error -> error
           )

    policy(result)
  end

  @doc "Consumes only the Store-retained one-use poll basis; the calculated record grants no authority."
  def consume_poll(db, clock, receipt_limit, basis, record) do
    result =
      with :ok <- calculation_matches(basis, record),
           :ok <- validate(db),
           :ok <- ScheduleLifecycle.withdraw_invalidated(db, clock),
           {:ok, activation, artifact} <- ScheduleLifecycle.current_activation(db),
           true <- activation == basis.activation and artifact == basis.artifact,
           {:ok, watermark} <- cursor(db, activation),
           true <- watermark == basis.watermark,
           :ok <- repeat_clock(db, clock, basis) do
        publish_consideration(db, clock, receipt_limit, basis, record)
      else
        # Keep a newly discovered sticky withdrawal even when it invalidates
        # this prepared calculation. No occurrence is published by that barrier.
        {:error, :schedule_inactive} -> {:commit, {:error, :schedule_basis_changed}}
        false -> {:error, :schedule_poll_changed}
        error -> error
      end

    policy(result)
  end

  @doc "Store-only final repeat after history validation and immediately before the enclosing commit."
  def final_poll_decision(db, clock, basis, record, commit) do
    case final_poll_guard(db, clock, basis, record) do
      :ok -> commit
      {:error, reason} when reason in @corrupt -> {:rollback, reason}
      {:error, reason} when is_atom(reason) -> {:rollback, {:policy, reason}}
      {:error, reason} -> {:rollback, reason}
    end
  end

  def final_poll_guard(db, clock, basis, record) do
    with {:ok, activation, artifact} <- ScheduleLifecycle.current_activation(db),
         :ok <- same_poll_basis(activation, artifact, basis),
         :ok <- repeat_clock(db, clock, basis),
         :ok <- retained_effect_guard(db, clock, basis, record),
         {boot, now} <- ClockContext.receipt(clock),
         true <-
           boot == basis.snapshot.scope["store_boot_epoch"] and
             now >= basis.snapshot.now_ms and now - basis.snapshot.now_ms < 5_000,
         do: :ok,
         else: (
           false ->
             {:error, :schedule_poll_expired}

           {:error, :schedule_inactive} ->
             if match?(["countdown" | _], basis.artifact.source["trigger"]) and record != :idle,
               do: {:error, :schedule_basis_changed},
               else: inactive_poll_guard(db, basis)

           error ->
             error
         )
  end

  defp inactive_poll_guard(db, basis) do
    case query(
           db,
           "SELECT (SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='rule_generation')"
         ) do
      {:ok, [[epoch, generation]]} ->
        if epoch != basis.activation.epoch or generation != basis.activation.generation,
          do: :ok,
          else: {:error, :schedule_basis_changed}

      _ ->
        corrupt()
    end
  end

  defp same_poll_basis(activation, artifact, basis) do
    if activation == basis.activation and artifact == basis.artifact,
      do: :ok,
      else: {:error, :schedule_poll_changed}
  end

  defp retained_effect_guard(_db, _clock, _basis, :idle), do: :ok

  defp retained_effect_guard(db, clock, basis, %{decision: "eligible"} = record) do
    case query(db, "SELECT decision FROM schedule_effect_operations WHERE operation_id=?", [
           record.occurrence_id
         ]) do
      {:ok, [["held"]]} ->
        WotexHome.Durable.Store.RuleWriter.execution_guard(
          db,
          basis.activation.principal,
          basis.activation.epoch,
          record.occurrence_id,
          clock
        )

      {:ok, [["blocked"]]} ->
        :ok

      _ ->
        corrupt()
    end
  end

  defp retained_effect_guard(_db, _clock, _basis, _record), do: :ok

  defp poll_basis(db, clock) do
    with {:ok, activation, artifact} <- ScheduleLifecycle.current_activation(db),
         {:ok, watermark} <- cursor(db, activation),
         {:ok, snapshot} <- ClockContext.temporal(clock),
         :ok <- ActivationClock.ready(artifact.source, snapshot),
         {:ok, zone} <- ClockContext.timezone(clock, artifact.source),
         true <- zone == artifact.timezone,
         do:
           {:ok,
            %{
              activation: activation,
              artifact: artifact,
              snapshot: snapshot,
              watermark: watermark,
              zone: zone
            }},
         else: (
           false -> {:error, :timezone_basis_changed}
           error -> error
         )
  end

  defp calculation_matches(basis, :idle) do
    case Consideration.build(basis.activation, basis.artifact, basis.snapshot, basis.watermark) do
      {:ok, :idle} -> :ok
      _ -> {:error, :invalid_schedule_consideration}
    end
  end

  defp calculation_matches(basis, record) when is_map(record) do
    with true <- Codec.exact?(record, Consideration.fields()),
         true <-
           record.activation_revision == basis.activation.revision and
             record.previous_watermark == basis.watermark,
         {:ok, document} <- ActivationClock.encode(basis.snapshot, record.watermark),
         true <- document == record.clock_document,
         true <- Consideration.valid?(record, basis.activation, basis.artifact),
         do: :ok,
         else: (_ -> {:error, :invalid_schedule_consideration})
  end

  defp calculation_matches(_, _), do: {:error, :invalid_schedule_consideration}

  defp repeat_clock(db, clock, basis) do
    observation = ClockContext.temporal(clock)

    with :ok <-
           ScheduleLifecycle.withdraw_countdown(
             db,
             basis.activation,
             basis.artifact.source,
             clock,
             observation
           ),
         {:ok, current} <- observation,
         true <-
           basis.snapshot.scope == current.scope and
             current.now_ms >= basis.snapshot.now_ms,
         true <- ActivationClock.ready(basis.artifact.source, current) == :ok,
         {:ok, zone} <- ClockContext.timezone(clock, basis.artifact.source),
         true <- zone == basis.zone,
         do: :ok,
         else: (
           false -> {:error, :clock_changed}
           error -> error
         )
  end

  defp publish_consideration(_db, _clock, _limit, basis, :idle) do
    {:rollback,
     {:unchanged,
      {:ok,
       %{state: :idle, activation_revision: basis.activation.revision, watermark: basis.watermark}}}}
  end

  defp publish_consideration(db, clock, receipt_limit, basis, record) do
    %{activation: activation, artifact: artifact, watermark: watermark} = basis

    with :ok <- capacity(db, bytes(record)),
         {:ok, revision} <- Journal.next_revision(db),
         :ok <-
           Journal.authority_event(db, revision, "schedule_occurrence_considered", entity(record)),
         values = Enum.map(Consideration.fields(), &record[&1]) ++ [revision],
         {:ok, []} <-
           query(
             db,
             "INSERT INTO schedule_considerations VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
             values
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO schedule_watermarks VALUES (?,?,?) ON CONFLICT(activation_revision) DO UPDATE SET considered_through=excluded.considered_through,head_revision=excluded.head_revision WHERE schedule_watermarks.considered_through=?",
             [activation.revision, record.watermark, revision, watermark]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, effect} <-
           maybe_open_effect(db, record, revision, activation, artifact, clock, receipt_limit),
         {:ok, ^activation, ^artifact} <- ScheduleLifecycle.current_activation(db),
         :ok <- repeat_clock(db, clock, basis),
         do: {:commit, {:ok, receipt(record, revision, effect)}},
         else: (
           {:ok, _, _} -> {:error, :schedule_poll_changed}
           {:ok, _} -> corrupt()
           error -> error
         )
  end

  @doc "Principal-private existing-only occurrence lookup; current clock and target grant are unnecessary."
  def original_status(db, credential, occurrence_id) do
    with true <- occurrence_id?(occurrence_id),
         {:ok, actor} <- actor(db, credential),
         :ok <- validate(db),
         :ok <- WotexHome.Durable.Store.ScheduleEffects.validate_if_current(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@qualified_columns} FROM schedule_considerations c JOIN schedule_lifecycle_operations l ON l.revision=c.activation_revision WHERE c.occurrence_id=? AND l.principal_id=?",
             [occurrence_id, actor]
           ) do
      case rows do
        [] ->
          :not_found

        [row] ->
          {record, revision} = record(row)

          with {:ok, effect} <- retained_effect(db, revision),
               do: {:ok, receipt(record, revision, effect)}

        _ ->
          corrupt()
      end
    else
      false -> {:error, :invalid_schedule_occurrence}
      error -> error
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [26, 27, 28] -> validate(db)
      {:ok, [[version]]} when version in 1..25 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM schedule_considerations ORDER BY revision LIMIT 4097"
           ),
         true <- length(rows) <= @capacity,
         true <-
           Enum.reduce(rows, 0, fn row, sum ->
             {record, _} = record(row)
             sum + bytes(record)
           end) <= @byte_limit,
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='schedule_occurrence_considered'"
           ),
         true <- count == length(rows),
         {:ok, final} <- validate_rows(db, rows),
         {:ok, cursors} <-
           query(
             db,
             "SELECT #{@cursor_columns} FROM schedule_watermarks ORDER BY activation_revision LIMIT 1025"
           ),
         true <-
           cursors ==
             Enum.sort(
               Enum.map(final.cursors, fn {activation, {watermark, revision}} ->
                 [activation, watermark, revision]
               end)
             ),
         do: :ok,
         else: (_ -> corrupt())
  rescue
    _ -> corrupt()
  end

  defp validate_rows(db, rows) do
    Enum.reduce_while(rows, {:ok, %{bases: %{}, cursors: %{}, clocks: %{}}}, fn row,
                                                                                {:ok, state} ->
      {record, revision} = record(row)

      with {:ok, activation, artifact, state} <-
             retained_basis(db, record.activation_revision, state),
           true <- Consideration.valid?(record, activation, artifact),
           {previous, _} =
             Map.get(
               state.cursors,
               activation.revision,
               {activation.watermark, activation.revision}
             ),
           true <- previous == record.previous_watermark,
           true <- Codec.integer?(revision, activation.revision + 1, Codec.maximum()),
           {:ok, [[current_revision]]} <- query(db, "SELECT value FROM meta WHERE key='revision'"),
           true <- revision <= current_revision,
           {:ok, [["schedule_occurrence_considered", expected_entity]]} <-
             query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
               revision
             ]),
           true <- expected_entity == entity(record),
           {:ok, snapshot, _} <- ActivationClock.decode(record.clock_document),
           boot = snapshot.scope["store_boot_epoch"],
           true <- snapshot.now_ms >= Map.get(state.clocks, boot, 0),
           :ok <- generation_at(db, activation, revision) do
        {:cont,
         {:ok,
          %{
            state
            | cursors: Map.put(state.cursors, activation.revision, {record.watermark, revision}),
              clocks: Map.put(state.clocks, boot, snapshot.now_ms)
          }}}
      else
        _ -> {:halt, corrupt()}
      end
    end)
  end

  defp retained_basis(db, revision, state) do
    case state.bases[revision] do
      {activation, artifact} ->
        {:ok, activation, artifact, state}

      nil ->
        with {:ok, activation} <- ScheduleLifecycle.retained_activation(db, revision),
             {:ok, artifact} <- ScheduleWriter.retained_admission(db, activation.admission),
             do:
               {:ok, activation, artifact,
                %{state | bases: Map.put(state.bases, revision, {activation, artifact})}}
    end
  end

  defp generation_at(db, activation, revision) do
    with {:ok, [[generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced','rule_policy_activated') AND revision<?",
             [revision]
           ),
         true <- generation == activation.generation,
         {:ok, [[latest]]} <-
           query(db, "SELECT MAX(revision) FROM schedule_lifecycle_operations WHERE revision<?", [
             revision
           ]),
         true <- latest == activation.revision,
         do: :ok,
         else: (_ -> corrupt())
  end

  defp cursor(db, activation) do
    case query(
           db,
           "SELECT considered_through FROM schedule_watermarks WHERE activation_revision=?",
           [activation.revision]
         ) do
      {:ok, []} -> {:ok, activation.watermark}
      {:ok, [[watermark]]} -> {:ok, watermark}
      _ -> corrupt()
    end
  end

  defp capacity(db, extra) do
    with {:ok, [[count, bytes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(clock_document AS BLOB))+COALESCE(length(CAST(occurrence_document AS BLOB)),0)+COALESCE(length(CAST(occurrence_id AS BLOB)),0)+COALESCE(length(CAST(causal_id AS BLOB)),0)+length(CAST(reason AS BLOB))),0) FROM schedule_considerations"
           ),
         do:
           if(count < @capacity and bytes + extra <= @byte_limit,
             do: :ok,
             else: {:error, :schedule_occurrence_capacity}
           )
  end

  defp record(row) do
    {values, [revision]} = Enum.split(row, length(Consideration.fields()))
    {Map.new(Enum.zip(Consideration.fields(), values)), revision}
  end

  defp receipt(record, revision, effect) do
    receipt = base_receipt(record, revision)

    if effect,
      do:
        Map.merge(receipt, %{
          state: effect.state,
          reason: effect.reason,
          revision: effect.revision,
          consideration_revision: revision,
          effect: effect
        }),
      else: receipt
  end

  defp maybe_open_effect(
         db,
         %{decision: "eligible"} = record,
         revision,
         activation,
         artifact,
         clock,
         limit
       ) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [27, 28] ->
        WotexHome.Durable.Store.ScheduleEffects.open(
          db,
          record,
          revision,
          activation,
          artifact,
          clock,
          limit
        )

      {:ok, [[26]]} ->
        {:ok, nil}

      _ ->
        corrupt()
    end
  end

  defp maybe_open_effect(_, _, _, _, _, _, _), do: {:ok, nil}

  defp retained_effect(db, revision) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [27, 28] ->
        WotexHome.Durable.Store.ScheduleEffects.original(db, revision)

      {:ok, [[26]]} ->
        {:ok, nil}

      _ ->
        corrupt()
    end
  end

  defp base_receipt(record, revision),
    do: %{
      activation_revision: record.activation_revision,
      occurrence_id: record.occurrence_id,
      causal_id: record.causal_id,
      state: if(record.decision == "idle", do: :missed, else: :blocked),
      decision: record.decision,
      reason: record.reason,
      previous_watermark: record.previous_watermark,
      watermark: record.watermark,
      missed_range: if(record.missed_lower, do: [record.missed_lower, record.missed_upper]),
      revision: revision
    }

  defp entity(%{occurrence_id: nil, activation_revision: revision}),
    do: "schedule-range:#{revision}"

  defp entity(%{occurrence_id: id}), do: id

  defp bytes(record),
    do:
      Enum.reduce(
        [
          record.clock_document,
          record.occurrence_document,
          record.occurrence_id,
          record.causal_id,
          record.reason
        ],
        0,
        fn value, sum -> sum + if(is_binary(value), do: byte_size(value), else: 0) end
      )

  defp occurrence_id?("occ:" <> digest), do: WotexHome.Profiles.Codec.digest?(digest)
  defp occurrence_id?(_), do: false

  defp actor(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, actor, permissions} <- Access.authenticate(db, hash),
         true <- "rule:review" in permissions,
         do: {:ok, actor},
         else: (
           false -> {:error, :permission_denied}
           error -> error
         )
  end

  defp corrupt, do: {:error, :corrupt_schedule_occurrence}
  defp policy({:error, reason}) when reason in @corrupt, do: {:rollback, reason}
  defp policy({:error, reason}) when is_atom(reason), do: {:rollback, {:policy, reason}}
  defp policy({:error, reason}), do: {:rollback, reason}
  defp policy(result), do: result
end
