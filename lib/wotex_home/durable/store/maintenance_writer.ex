defmodule WotexHome.Durable.Store.MaintenanceWriter do
  @moduledoc """
  Durable host-maintenance barrier under the single Store writer.

  Beginning maintenance fences the active rule generation and invalidates
  pending work in the same transaction as the persistent barrier. Ending it
  permits new requests but never reactivates a rule, replays an effect, installs
  an artifact or restores a database. Observations and recovery reads continue.
  """
  alias WotexHome.{Id, Permissions}
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ExecutionWriter, Journal, RequestInvalidator, RuleWriter}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807
  @capacity 1_024
  @columns "principal_id, authority_epoch, operation_id, action, expected_revision, begin_revision, revision, fence_revision, rule_generation, affected_requests, unknown_outcomes"

  def change(db, credential, epoch, operation, expected, action, begin_revision) do
    policy(fn ->
      with true <-
             integer?(epoch) and epoch > 0 and Id.valid?(operation) and integer?(expected) and
               expected < @max_i64 and action in ["begin", "end"] and integer?(begin_revision),
           true <-
             (action == "begin" and begin_revision == 0) or
               (action == "end" and begin_revision > 0),
           {:ok, principal} <- actor(db, credential),
           {:ok, rows} <-
             query(
               db,
               "SELECT #{@columns} FROM host_maintenance_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
               [principal, epoch, operation]
             ) do
        case rows do
          [[_, _, _, ^action, ^expected, ^begin_revision | _] = row] ->
            with :ok <- validate_row(db, row), do: {:rollback, {:unchanged, {:ok, receipt(row)}}}

          [_] ->
            {:error, :maintenance_operation_conflict}

          [] ->
            new_change(db, principal, epoch, operation, expected, action, begin_revision)

          _ ->
            {:error, :corrupt_maintenance}
        end
      else
        false -> {:error, :invalid_maintenance_operation}
        error -> error
      end
    end)
  end

  defp new_change(db, principal, epoch, operation, expected, action, begin_revision) do
    with {:ok, [[revision, current_epoch, generation]]} <- meta(db),
         :ok <- equal(current_epoch, epoch, :stale_authority_epoch),
         :ok <- equal(revision, expected, :resnapshot_required),
         {:ok, active} <- active(db),
         :ok <-
           equal(
             active,
             begin_revision,
             if(action == "begin", do: :maintenance_active, else: :maintenance_changed)
           ),
         {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM host_maintenance_operations"),
         true <- count < @capacity,
         :ok <- RuleWriter.validate(db),
         {:ok, fence, next_generation, affected, unknown} <-
           barrier(db, expected, epoch, generation, action),
         {:ok, final} <- Journal.next_revision(db),
         :ok <- Journal.authority_event(db, final, event(action), "host:maintenance"),
         row = [
           principal,
           epoch,
           operation,
           action,
           expected,
           begin_revision,
           final,
           fence,
           next_generation,
           affected,
           unknown
         ],
         {:ok, []} <-
           query(
             db,
             "INSERT INTO host_maintenance_operations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
             row
           ),
         :ok <- validate_row(db, row),
         {:ok, []} <-
           query(db, "UPDATE meta SET value=? WHERE key='maintenance_revision'", [
             if(action == "begin", do: final, else: 0)
           ]),
         {:ok, [[1]]} <- query(db, "SELECT changes()") do
      {:commit, {:ok, receipt(row)}}
    else
      false -> {:error, :maintenance_capacity}
      error -> error
    end
  end

  defp barrier(db, expected, epoch, _generation, "begin") do
    with {:ok, pending} <- RequestInvalidator.pending_execution_rows(db, :all),
         {:commit, {:ok, result}} <- ExecutionWriter.fence_rule_generation_tx(db, expected, epoch) do
      unknown = Enum.count(pending, &(List.last(&1) in ["dispatching", "protocol_accepted"]))
      {:ok, expected + 1, result.rule_generation, result.affected_requests, unknown}
    else
      {:rollback, {:policy, reason}} -> {:error, reason}
      {:rollback, reason} -> {:error, reason}
      error -> error
    end
  end

  defp barrier(_db, _expected, _epoch, generation, "end"), do: {:ok, 0, generation, 0, 0}

  @doc "Repeated before new ordinary requests, rule work, queue, claim and handoff."
  def guard(db) do
    case active(db) do
      {:ok, 0} -> :ok
      {:ok, _} -> {:error, :maintenance_active}
      error -> error
    end
  end

  @doc "Validate the existing barrier without granting its caller host-maintenance permission."
  def require_active(db) do
    case active(db) do
      {:ok, 0} -> {:error, :maintenance_required}
      {:ok, revision} -> {:ok, revision}
      error -> error
    end
  end

  def status(db, credential) do
    with {:ok, _} <- actor(db, credential),
         {:ok, revision} <- active(db),
         {:ok, [[store_revision, epoch, generation]]} <- meta(db) do
      {:ok,
       %{
         authority_epoch: epoch,
         store_revision: store_revision,
         rule_generation: generation,
         begin_revision: revision,
         state: if(revision == 0, do: :normal, else: :maintenance)
       }}
    end
  end

  def operation_status(db, credential, epoch, operation) do
    with true <- integer?(epoch) and epoch > 0 and Id.valid?(operation),
         {:ok, principal} <- actor(db, credential),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM host_maintenance_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [row] -> with :ok <- validate_row(db, row), do: {:ok, receipt(row)}
        _ -> {:error, :corrupt_maintenance}
      end
    else
      false -> {:error, :invalid_maintenance_operation}
      error -> error
    end
  end

  defp active(db) do
    with {:ok, [[active]]} <- query(db, "SELECT value FROM meta WHERE key='maintenance_revision'"),
         true <- integer?(active),
         {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM host_maintenance_operations"),
         true <- count in 0..@capacity,
         {:ok, [[^count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('host_maintenance_started', 'host_maintenance_ended', 'controller_destination_accepted')"
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM host_maintenance_operations ORDER BY revision DESC LIMIT 1"
           ) do
      case rows do
        [] when active == 0 ->
          {:ok, 0}

        [[_, _, _, action, _, _, revision | _] = row] ->
          with :ok <- validate_row(db, row),
               true <- active == if(action in ["begin", "transfer"], do: revision, else: 0),
               do: {:ok, active},
               else: (_ -> {:error, :corrupt_maintenance})

        _ ->
          {:error, :corrupt_maintenance}
      end
    else
      _ -> {:error, :corrupt_maintenance}
    end
  end

  @doc "Full read-only history/marker gate for startup and encrypted backup."
  def validate(db) do
    with {:ok, _} <- active(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM host_maintenance_operations ORDER BY revision LIMIT 1025"
           ) do
      Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, previous} ->
        [_, _, _, action, _, begin_revision, revision | _] = row

        with :ok <- validate_row(db, row),
             true <- begin_revision == previous do
          {:cont, {:ok, if(action in ["begin", "transfer"], do: revision, else: 0)}}
        else
          _ -> {:halt, {:error, :corrupt_maintenance}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        _ -> {:error, :corrupt_maintenance}
      end
    else
      _ -> {:error, :corrupt_maintenance}
    end
  end

  defp validate_row(
         db,
         [
           principal,
           epoch,
           operation,
           "transfer",
           expected,
           predecessor,
           revision,
           fence,
           generation,
           0,
           0
         ] = row
       ) do
    with {:ok, [[version]]} when version in [22, 23, 24, 25, 26] <-
           query(db, "PRAGMA user_version"),
         {:ok, [accepted]} <-
           query(
             db,
             "SELECT #{WotexHome.Durable.Store.ControllerHistory.acceptance_columns()} FROM controller_acceptances WHERE revision=?",
             [revision]
           ),
         {:ok, record} <- WotexHome.Recovery.TransferAcceptanceRecord.audit(accepted),
         receipt = record.receipt,
         true <-
           [principal, epoch, operation, expected, predecessor, revision, fence, generation] ==
             Enum.map(
               ~w(principal_id authority_epoch operation_id retirement_revision source_maintenance_revision revision fence_revision rule_generation),
               &receipt[&1]
             ),
         {:ok, [[current_revision, current_epoch, current_generation]]} <- meta(db),
         true <-
           revision <= current_revision and epoch <= current_epoch and
             generation <= current_generation,
         {:ok, [["controller_destination_accepted", entity]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         true <- entity == "controller:" <> receipt["deployment_id"],
         :ok <- predecessor(db, "transfer", predecessor, revision),
         {:ok, [[action, previous_epoch, previous_generation]]} <-
           query(
             db,
             "SELECT action,authority_epoch,rule_generation FROM host_maintenance_operations WHERE revision=?",
             [predecessor]
           ),
         true <-
           action in ["begin", "transfer"] and previous_epoch == epoch - 1 and
             previous_generation == generation - 1,
         :ok <- history_link(db, "begin", 0, fence, generation, epoch),
         :ok <- barrier_counts(db, "begin", fence, revision, 0, 0),
         true <- length(row) == 11 do
      :ok
    else
      _ -> {:error, :corrupt_maintenance}
    end
  end

  defp validate_row(db, [
         principal,
         epoch,
         operation,
         action,
         expected,
         begin_revision,
         revision,
         fence,
         generation,
         affected,
         unknown
       ]) do
    with true <-
           Id.valid?(principal) and Id.valid?(operation) and epoch in 1..@max_i64 and
             action in ["begin", "end"],
         true <-
           Enum.all?(
             [epoch, expected, begin_revision, revision, fence, generation, affected, unknown],
             &integer?/1
           ),
         true <- unknown <= affected and affected <= 1024,
         true <-
           if(action == "begin",
             do:
               begin_revision == 0 and fence == expected + 1 and
                 revision == expected + affected + 2 and generation > 0,
             else:
               begin_revision > 0 and begin_revision <= expected and fence == 0 and
                 revision == expected + 1 and affected == 0 and unknown == 0
           ),
         {:ok, [[current_revision, current_epoch, current_generation]]} <- meta(db),
         true <-
           revision <= current_revision and epoch <= current_epoch and
             generation <= current_generation,
         {:ok, [[type, "host:maintenance"]]} <-
           query(db, "SELECT event_type, entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         true <- type == event(action),
         {:ok, [[^generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced', 'rule_policy_activated') AND revision<=?",
             [revision]
           ),
         :ok <- predecessor(db, action, begin_revision, revision),
         :ok <- history_link(db, action, begin_revision, fence, generation, epoch),
         :ok <- barrier_counts(db, action, fence, revision, affected, unknown) do
      :ok
    else
      _ -> {:error, :corrupt_maintenance}
    end
  end

  defp validate_row(_db, _row), do: {:error, :corrupt_maintenance}

  defp predecessor(db, action, begin_revision, revision) do
    case {action, begin_revision,
          query(
            db,
            "SELECT action, revision FROM host_maintenance_operations WHERE revision<? ORDER BY revision DESC LIMIT 1",
            [revision]
          )} do
      {"begin", 0, {:ok, []}} ->
        :ok

      {"begin", 0, {:ok, [["end", _]]}} ->
        :ok

      {"end", expected, {:ok, [["begin", actual]]}} when expected == actual ->
        :ok

      {"end", expected, {:ok, [["transfer", actual]]}} when expected == actual ->
        :ok

      {"transfer", expected, {:ok, [[action, actual]]}}
      when action in ["begin", "transfer"] and expected == actual ->
        :ok

      _ ->
        {:error, :corrupt_maintenance}
    end
  end

  defp history_link(db, "begin", 0, fence, generation, _epoch) do
    with {:ok, [["rule_generation_fenced", "rules:empty"]]} <-
           query(db, "SELECT event_type, entity_id FROM authority_journal WHERE revision=?", [
             fence
           ]),
         {:ok, [[^generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_generation_fenced', 'rule_policy_activated') AND revision<=?",
             [fence]
           ) do
      :ok
    else
      _ -> {:error, :corrupt_maintenance}
    end
  end

  defp history_link(db, "end", begin_revision, 0, _generation, epoch) do
    case query(
           db,
           "SELECT action, authority_epoch FROM host_maintenance_operations WHERE revision=?",
           [begin_revision]
         ) do
      {:ok, [[action, ^epoch]]} when action in ["begin", "transfer"] -> :ok
      _ -> {:error, :corrupt_maintenance}
    end
  end

  defp barrier_counts(db, "begin", fence, revision, affected, unknown) do
    case query(
           db,
           "SELECT COUNT(*), COALESCE(SUM(disposition='outcome_unknown'), 0) FROM request_journal WHERE revision>? AND revision<? AND reason IN ('rule_generation_fenced', 'rule_generation_fenced_after_handoff')",
           [fence, revision]
         ) do
      {:ok, [[^affected, ^unknown]]} -> :ok
      _ -> {:error, :corrupt_maintenance}
    end
  end

  defp barrier_counts(_db, "end", _fence, _revision, 0, 0), do: :ok

  defp actor(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- Permissions.valid?(permissions) and "host:maintain" in permissions do
      {:ok, principal}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp meta(db) do
    case query(
           db,
           "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch'), (SELECT value FROM meta WHERE key='rule_generation')"
         ) do
      {:ok, [[revision, epoch, generation]]} = result ->
        if integer?(revision) and integer?(epoch) and epoch > 0 and integer?(generation),
          do: result,
          else: {:error, :corrupt_maintenance}

      _ ->
        {:error, :corrupt_maintenance}
    end
  end

  defp event("begin"), do: "host_maintenance_started"
  defp event("end"), do: "host_maintenance_ended"
  defp integer?(value), do: is_integer(value) and value in 0..@max_i64
  defp equal(value, value, _), do: :ok
  defp equal(_, _, reason), do: {:error, reason}

  defp receipt([
         principal,
         epoch,
         operation,
         action,
         _expected,
         begin_revision,
         revision,
         _fence,
         generation,
         affected,
         unknown
       ]) do
    %{
      principal_id: principal,
      authority_epoch: epoch,
      operation_id: operation,
      action: action,
      begin_revision: if(action in ["begin", "transfer"], do: revision, else: begin_revision),
      revision: revision,
      rule_generation: generation,
      affected_requests: affected,
      unknown_outcomes: unknown,
      state: if(action in ["begin", "transfer"], do: :maintenance, else: :normal)
    }
  end

  defp policy(fun) do
    case fun.() do
      {:error, reason}
      when reason in [
             :corrupt_maintenance,
             :corrupt_rule_admission,
             :corrupt_receipt,
             :corrupt_principal,
             :corrupt_enrollment,
             :corrupt_invariant
           ] ->
        {:rollback, reason}

      {:error, reason}
      when reason in [
             :invalid_maintenance_operation,
             :maintenance_operation_conflict,
             :maintenance_active,
             :maintenance_changed,
             :maintenance_capacity,
             :stale_authority_epoch,
             :resnapshot_required,
             :stale_store_revision,
             :generation_exhausted,
             :pending_capacity,
             :permission_denied,
             :unauthorized,
             :invalid_credential
           ] ->
        {:rollback, {:policy, reason}}

      {:error, _} ->
        {:rollback, :store_unavailable}

      other ->
        other
    end
  end
end
