defmodule WotexHome.Durable.Store.RequestLedger do
  @moduledoc """
  Canonical request receipts and held outbox transitions for the single writer.

  Store supplies its connection only inside a synchronous transaction. This
  collaborator owns no process, connection lifecycle, clock or transport.
  An exact retry returns the original disposition without renewing authority.
  """

  alias WotexHome.Policy
  alias WotexHome.Durable.Store.MaintenanceWriter
  alias WotexHome.Policy.Context
  alias WotexHome.Durable.Receipt
  alias WotexHome.Semantics.Value

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  import WotexHome.Durable.Store.Access,
    only: [authenticate: 2, usable_thing: 2, allowed_targets: 2]

  import WotexHome.Durable.Store.Journal, only: [next_revision: 1, request_event: 7]
  import WotexHome.Durable.Store.ObservationCodec, only: [encode_value: 1]

  import WotexHome.Durable.Store.RequestInvalidator,
    only: [reject_held: 5, invalidate_execution_row: 6]

  @max_i64 9_223_372_036_854_775_807
  @execution_dispositions %{
    "queued" => :queued,
    "claimed" => :claimed,
    "dispatching" => :dispatching,
    "protocol_accepted" => :protocol_accepted,
    "observed" => :observed,
    "contradicted" => :contradicted,
    "failed" => :failed,
    "outcome_unknown" => :outcome_unknown
  }

  @doc "Checks a persisted execution disposition against the closed receipt vocabulary."
  @spec execution_disposition?(term()) :: boolean()
  def execution_disposition?(disposition), do: Map.has_key?(@execution_dispositions, disposition)

  def submit_request_tx(db, hash, mutation, receipt_limit) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, rows} <-
           select_request(db, principal_id, mutation.authority_epoch, mutation.operation_id) do
      case rows do
        [] ->
          with :ok <- MaintenanceWriter.guard(db),
               :ok <- receipt_capacity(db, receipt_limit),
               {:ok, thing, resource_revision} <- usable_thing(db, mutation.target_id),
               {:ok, allowed_targets} <- allowed_targets(db, principal_id),
               {:ok, [[store_epoch]]} <-
                 query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'") do
            context = %Context{
              principal_id: principal_id,
              permissions: permissions,
              allowed_targets: allowed_targets,
              authority_epoch: store_epoch,
              resource_revision: resource_revision,
              enrollment_valid: true,
              profile_valid: true,
              invariants: :allow
            }

            write_request(db, principal_id, mutation, thing, context)
          else
            {:error, :corrupt_maintenance} -> {:rollback, :corrupt_maintenance}
            {:error, :corrupt_enrollment} -> {:rollback, :corrupt_enrollment}
            {:error, :corrupt_profile_ledger} -> {:rollback, :corrupt_profile_ledger}
            {:error, reason} -> {:rollback, {:policy, reason}}
          end

        [row] ->
          prior_request(row, principal_id, mutation)
      end
    else
      {:error, reason} when reason in [:corrupt_principal, :corrupt_enrollment] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp receipt_capacity(db, limit) do
    case query(db, "SELECT COUNT(*) FROM request_receipts") do
      {:ok, [[count]]} when is_integer(count) and count < limit -> :ok
      {:ok, [[count]]} when is_integer(count) -> {:error, :receipt_capacity}
      {:ok, _} -> {:error, :corrupt_receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_request_tx(db, hash, authority_epoch, operation_id) do
    with {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, rows} <- select_request(db, principal_id, authority_epoch, operation_id) do
      case rows do
        [] ->
          {:rollback, {:unchanged, :not_found}}

        [row] ->
          with {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
            case receipt.disposition do
              :held -> cancel_held_tx(db, receipt)
              :queued -> cancel_queued_tx(db, receipt)
              :rejected -> {:rollback, {:unchanged, {:ok, receipt}}}
              _ -> {:rollback, {:policy, :request_not_held}}
            end
          else
            {:error, reason} -> {:rollback, reason}
          end
      end
    else
      {:error, reason} when reason in [:corrupt_principal, :corrupt_receipt] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp cancel_held_tx(db, receipt) do
    case reject_held(
           db,
           receipt.principal_id,
           receipt.authority_epoch,
           receipt.operation_id,
           "cancelled"
         ) do
      {:ok, revision} ->
        {:commit,
         {:ok, %{receipt | disposition: :rejected, reason: "cancelled", revision: revision}}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp cancel_queued_tx(db, receipt) do
    case invalidate_execution_row(
           db,
           receipt.principal_id,
           receipt.authority_epoch,
           receipt.operation_id,
           "queued",
           "cancelled_before_claim"
         ) do
      {:ok, revision} ->
        {:commit,
         {:ok,
          %{
            receipt
            | disposition: :rejected,
              reason: "cancelled_before_claim",
              revision: revision
          }}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  def select_request(db, principal_id, authority_epoch, operation_id) do
    query(
      db,
      "SELECT expected_revision, target_id, capability_key, value_kind, value_a, value_b, profile_ref, disposition, reason, revision FROM request_receipts WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
      [principal_id, authority_epoch, operation_id]
    )
  end

  defp prior_request(row, principal_id, mutation) do
    {:ok, value} = Value.new(mutation.value)
    {kind, a, b} = encode_value(value)
    [expected_revision, target_id, capability_key, old_kind, old_a, old_b | _] = row

    if {expected_revision, target_id, capability_key, old_kind, old_a, old_b} ==
         {mutation.expected_revision, mutation.target_id, mutation.capability_key, kind, a, b} do
      case decode_receipt(principal_id, mutation.authority_epoch, mutation.operation_id, row) do
        {:ok, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
        {:error, reason} -> {:rollback, reason}
      end
    else
      {:rollback, {:policy, :operation_id_conflict}}
    end
  end

  defp write_request(db, principal_id, mutation, thing, context) do
    with {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, {disposition, reason}} <-
           request_decision(db, principal_id, store_epoch, mutation, thing, context),
         {:ok, new_revision} <- next_revision(db) do
      {:ok, value} = Value.new(mutation.value)
      {kind, a, b} = encode_value(value)

      params = [
        principal_id,
        mutation.authority_epoch,
        mutation.operation_id,
        mutation.expected_revision,
        mutation.target_id,
        mutation.capability_key,
        kind,
        a,
        b,
        thing.profile_ref,
        disposition,
        reason,
        new_revision
      ]

      with {:ok, []} <-
             query(
               db,
               "INSERT INTO request_receipts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               params
             ),
           :ok <- maybe_hold_request(db, principal_id, mutation, disposition, new_revision),
           :ok <-
             request_event(
               db,
               new_revision,
               principal_id,
               mutation.authority_epoch,
               mutation.operation_id,
               disposition,
               reason
             ),
           :ok <-
             WotexHome.Durable.Store.CausalLedger.open(
               db,
               principal_id,
               mutation.authority_epoch,
               mutation.operation_id,
               new_revision
             ) do
        receipt = %Receipt{
          principal_id: principal_id,
          authority_epoch: mutation.authority_epoch,
          operation_id: mutation.operation_id,
          disposition: if(disposition == "held", do: :held, else: :rejected),
          reason: reason,
          revision: new_revision
        }

        {:commit, {:ok, receipt}}
      else
        {:error, error} -> {:rollback, error}
      end
    else
      {:error, error} -> {:rollback, error}
    end
  end

  defp request_decision(_db, _principal_id, store_epoch, mutation, _thing, _context)
       when store_epoch != mutation.authority_epoch,
       do: {:ok, {"rejected", "stale_authority_epoch"}}

  defp request_decision(db, principal_id, _store_epoch, mutation, thing, context) do
    case Policy.check(mutation, thing, context) do
      :ok -> held_capacity(db, principal_id)
      {:error, reason} -> {:ok, {"rejected", Atom.to_string(reason)}}
    end
  end

  defp held_capacity(db, principal_id) do
    with {:ok, [[principal_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_outbox WHERE principal_id = ?", [principal_id]),
         {:ok, [[global_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox") do
      if principal_count < 32 and global_count < 1_024,
        do: {:ok, {"held", nil}},
        else: {:ok, {"rejected", "pending_capacity"}}
    end
  end

  defp maybe_hold_request(_db, _principal_id, _mutation, "rejected", _revision), do: :ok

  defp maybe_hold_request(db, principal_id, mutation, "held", revision) do
    case query(db, "INSERT INTO request_outbox VALUES (?, ?, ?, 'held', ?)", [
           principal_id,
           mutation.authority_epoch,
           mutation.operation_id,
           revision
         ]) do
      {:ok, []} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  def decode_receipt(principal_id, authority_epoch, operation_id, [
        _expected,
        _target,
        _capability,
        _kind,
        _a,
        _b,
        _profile,
        disposition,
        reason,
        revision
      ]) do
    case {disposition, reason, revision} do
      {"held", nil, revision}
      when is_integer(revision) and revision >= 0 and revision <= @max_i64 ->
        {:ok,
         %Receipt{
           principal_id: principal_id,
           authority_epoch: authority_epoch,
           operation_id: operation_id,
           disposition: :held,
           reason: reason,
           revision: revision
         }}

      {"rejected", reason, revision}
      when is_binary(reason) and is_integer(revision) and revision >= 0 and revision <= @max_i64 ->
        {:ok,
         %Receipt{
           principal_id: principal_id,
           authority_epoch: authority_epoch,
           operation_id: operation_id,
           disposition: :rejected,
           reason: reason,
           revision: revision
         }}

      {state, reason, revision}
      when is_binary(state) and (is_nil(reason) or is_binary(reason)) and
             is_integer(revision) and revision >= 0 and revision <= @max_i64 ->
        case Map.fetch(@execution_dispositions, state) do
          {:ok, value} ->
            {:ok,
             %Receipt{
               principal_id: principal_id,
               authority_epoch: authority_epoch,
               operation_id: operation_id,
               disposition: value,
               reason: reason,
               revision: revision
             }}

          :error ->
            {:error, :corrupt_receipt}
        end

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  def decode_receipt(_principal_id, _authority_epoch, _operation_id, _row),
    do: {:error, :corrupt_receipt}
end
