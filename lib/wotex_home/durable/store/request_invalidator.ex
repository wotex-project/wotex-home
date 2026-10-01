defmodule WotexHome.Durable.Store.RequestInvalidator do
  @moduledoc """
  Shared invalidation transitions for held and in-flight Store requests.

  Enrollment, principal grants, rule fences and explicit cancellation use the
  same transition code so pre-handoff work is rejected while work that may
  have crossed the handoff boundary becomes `outcome_unknown`. The Store owns
  the surrounding transaction and database handle.
  """

  alias WotexHome.Durable.Store.Journal

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  import Journal, only: [next_revision: 1, request_event: 7]

  @type scope ::
          :all
          | {:thing, String.t()}
          | {:principal, String.t()}
          | {:target_grant, String.t(), String.t()}

  @doc "Selects held requests for one Thing in deterministic order."
  @spec held_for_thing(term(), String.t()) :: {:ok, list()} | {:error, term()}
  def held_for_thing(db, thing_id) do
    query(
      db,
      "SELECT o.principal_id, o.authority_epoch, o.operation_id FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE o.state = 'held' AND r.disposition = 'held' AND r.target_id = ? ORDER BY o.principal_id, o.authority_epoch, o.operation_id",
      [thing_id]
    )
  end

  @doc "Rejects a previously selected bounded held-request set."
  @spec reject_held_batch(term(), list(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reject_held_batch(db, held, reason) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      Enum.reduce_while(held, {:ok, revision}, fn
        [principal_id, authority_epoch, operation_id], {:ok, _revision} ->
          case reject_held(db, principal_id, authority_epoch, operation_id, reason) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, error} -> {:halt, {:error, error}}
          end

        _, _ ->
          {:halt, {:error, :corrupt_receipt}}
      end)
    end
  end

  @doc "Invalidates every nonterminal execution row in one authority scope."
  @spec invalidate_execution_for(term(), scope(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def invalidate_execution_for(db, scope, reason) do
    with {:ok, rows} <- pending_execution_rows(db, scope),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      Enum.reduce_while(rows, {:ok, revision}, fn
        [principal_id, epoch, operation_id, state], {:ok, _last} ->
          case invalidate_execution_row(db, principal_id, epoch, operation_id, state, reason) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, error} -> {:halt, {:error, error}}
          end

        _, _ ->
          {:halt, {:error, :corrupt_receipt}}
      end)
    end
  end

  @doc "Selects bounded pending execution rows for a supported invalidation scope."
  @spec pending_execution_rows(term(), scope()) :: {:ok, list()} | {:error, term()}
  def pending_execution_rows(db, {:thing, thing_id}) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE target_id = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY principal_id, authority_epoch, operation_id",
      [thing_id]
    )
  end

  def pending_execution_rows(db, :all) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY principal_id, authority_epoch, operation_id LIMIT 1025"
    )
  end

  def pending_execution_rows(db, {:principal, principal_id}) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE principal_id = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY authority_epoch, operation_id",
      [principal_id]
    )
  end

  def pending_execution_rows(db, {:target_grant, principal_id, thing_id}) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE principal_id = ? AND target_id = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY authority_epoch, operation_id",
      [principal_id, thing_id]
    )
  end

  @doc "Applies one checked invalidation transition to an execution row."
  @spec invalidate_execution_row(
          term(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def invalidate_execution_row(db, principal_id, epoch, operation_id, state, reason)
      when state in ["queued", "claimed"] do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = ?",
             [principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'rejected', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = ?",
             [reason, revision, principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- request_event(db, revision, principal_id, epoch, operation_id, "rejected", reason) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
    end
  end

  def invalidate_execution_row(db, principal_id, epoch, operation_id, state, reason)
      when state in ["dispatching", "protocol_accepted"] do
    reason = reason <> "_after_handoff"

    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = 'outcome_unknown', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = ?",
             [revision, principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'outcome_unknown', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = ?",
             [reason, revision, principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             epoch,
             operation_id,
             "outcome_unknown",
             reason
           ) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
    end
  end

  def invalidate_execution_row(_db, _principal_id, _epoch, _operation_id, _state, _reason),
    do: {:error, :corrupt_receipt}

  @doc "Rejects one held request and removes its outbox row at one revision."
  @spec reject_held(term(), String.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reject_held(db, principal_id, authority_epoch, operation_id, reason) do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'held'",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'rejected', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'held'",
             [reason, revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             "rejected",
             reason
           ) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
    end
  end
end
