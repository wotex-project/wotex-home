defmodule WotexHome.Durable.Store.CausalLedger do
  @moduledoc """
  Durable, single-effect causal roots for explicit requests and distinct schedule occurrences.

  The root identity is the immutable receipt's principal/epoch/operation tuple,
  not a caller-supplied reusable token. Accepting a queued intent reserves its
  only effect. Cancelling, fencing, settling or deleting an execution never
  refunds that reservation. A reservation is not evidence of physical cause.

  This stateless collaborator borrows the Store transaction. It grants no rule
  authority, opens no connection, owns no clock and performs no device I/O.
  Historical roots retain an explicit legacy marker; a missing old queue event
  cannot be manufactured into current execution provenance.
  """

  import WotexHome.Durable.Store.SQL, only: [query: 3, query: 2]

  @execution_root """
  SELECT r.origin, r.created_revision, r.reserved_effects, r.reservation_revision,
    e.admission_revision, q.revision, c.revision,
    (SELECT COUNT(*) FROM request_journal j
      WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
        AND j.operation_id=r.operation_id AND j.disposition='queued'),
    (SELECT MIN(j.revision) FROM request_journal j
      WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
        AND j.operation_id=r.operation_id)
  FROM request_causal_roots r
  JOIN request_execution e USING (principal_id, authority_epoch, operation_id)
  LEFT JOIN request_journal q ON q.revision=r.reservation_revision
    AND q.principal_id=r.principal_id AND q.authority_epoch=r.authority_epoch
    AND q.operation_id=r.operation_id AND q.disposition='queued' AND q.reason IS NULL
  LEFT JOIN request_journal c ON c.revision=r.created_revision
    AND c.principal_id=r.principal_id AND c.authority_epoch=r.authority_epoch
    AND c.operation_id=r.operation_id AND c.disposition IN ('held', 'rejected')
  WHERE r.principal_id=? AND r.authority_epoch=? AND r.operation_id=?
  """

  @doc "Closed software profile for this non-chaining explicit-request path."
  def profile,
    do: %{profile: "home-explicit-request-cause-v1", max_effects: 1, max_depth: 1}

  @doc "Separate one-occurrence, one-effect temporal provenance; no chaining or inherited explicit-request authority."
  def temporal_profile,
    do: %{profile: "home-single-schedule-cause-v1", max_effects: 1, max_depth: 1}

  @doc "Bind a new request root with its distinct origin in the receipt's creation transaction."
  def open(db, principal_id, epoch, operation_id, revision, origin \\ "explicit_request")
      when origin in ["explicit_request", "schedule_occurrence"] do
    case query(
           db,
           "INSERT INTO request_causal_roots (principal_id, authority_epoch, operation_id, origin, created_revision, reserved_effects, reservation_revision) VALUES (?, ?, ?, ?, ?, 0, NULL)",
           [principal_id, epoch, operation_id, origin, revision]
         ) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  @doc "Reserve the one depth-one intent atomically with its queue event."
  def reserve(db, receipt, revision) do
    identity = [receipt.principal_id, receipt.authority_epoch, receipt.operation_id]

    with {:ok, [[origin, created, count, reserved]]} <- root(db, identity) do
      cond do
        valid_origin?(origin, created) and positive_integer?(revision) and count == 0 and
          is_nil(reserved) and (origin == "legacy_request" or created < revision) ->
          with {:ok, []} <-
                 query(
                   db,
                   "UPDATE request_causal_roots SET reserved_effects=1, reservation_revision=? WHERE principal_id=? AND authority_epoch=? AND operation_id=? AND reserved_effects=0 AND reservation_revision IS NULL",
                   [revision | identity]
                 ),
               {:ok, [[1]]} <- query(db, "SELECT changes()") do
            :ok
          else
            {:error, reason} -> {:error, reason}
            _ -> {:error, :corrupt_receipt}
          end

        valid_origin?(origin, created) and count == 1 and
            (positive_integer?(reserved) or (origin == "legacy_request" and is_nil(reserved))) ->
          {:error, :causal_budget_exhausted}

        true ->
          {:error, :corrupt_receipt}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  @doc "Require the original intent reservation again before claim and handoff."
  def execution_guard(db, receipt) do
    case query(
           db,
           @execution_root,
           [receipt.principal_id, receipt.authority_epoch, receipt.operation_id]
         ) do
      {:ok,
       [[origin, created, 1, reserved, admission, queued_event, creation_event, queues, first]]} ->
        cond do
          not valid_origin?(origin, created) ->
            {:error, :corrupt_receipt}

          origin == "legacy_request" and is_nil(reserved) ->
            {:error, :causal_provenance_unavailable}

          positive_integer?(reserved) and reserved == admission and queued_event == reserved and
            queues == 1 and
              (origin == "legacy_request" or
                 (created == creation_event and created == first and created < reserved)) ->
            :ok

          true ->
            {:error, :corrupt_receipt}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp root(db, identity),
    do:
      query(
        db,
        "SELECT origin, created_revision, reserved_effects, reservation_revision FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
        identity
      )

  defp valid_origin?("explicit_request", revision), do: positive_integer?(revision)
  defp valid_origin?("schedule_occurrence", revision), do: positive_integer?(revision)
  defp valid_origin?("legacy_request", nil), do: true
  defp valid_origin?(_, _), do: false

  defp positive_integer?(value),
    do: is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807
end
