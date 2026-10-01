defmodule WotexHome.Durable.Store.PrincipalWriter do
  @moduledoc """
  Principal and target-grant transactions for the single Store writer.

  The Store validates inputs, generates credentials and owns the transaction.
  This collaborator persists only credential hashes, applies target-grant
  changes, clears affected override leases and invalidates pending work at
  shared journal revisions. It retains no database or process state.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Journal, OverrideWriter, RequestInvalidator}

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  import Journal, only: [authority_event: 4, next_revision: 1]
  import OverrideWriter, only: [clear_override_for_grant: 3, clear_override_for_principal: 2]
  import RequestInvalidator, only: [invalidate_execution_for: 3, reject_held_batch: 3]

  @spec provision_principal_tx(term(), String.t(), binary(), String.t(), [String.t()], binary()) ::
          tuple()
  def provision_principal_tx(db, principal_id, hash, permissions_json, target_ids, credential) do
    with {:ok, []} <-
           query(db, "SELECT principal_id FROM principals WHERE principal_id = ?", [principal_id]),
         :ok <- active_targets(db, target_ids),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "INSERT INTO principals VALUES (?, ?, ?, 'active')", [
             principal_id,
             hash,
             permissions_json
           ]),
         :ok <- insert_targets(db, principal_id, target_ids),
         :ok <- authority_event(db, revision, "principal_provisioned", principal_id) do
      {:commit, {:ok, credential, revision}}
    else
      {:ok, _existing} -> {:rollback, {:policy, :principal_exists}}
      {:error, reason} -> {:rollback, reason}
    end
  end

  @spec revoke_principal_tx(term(), String.t()) :: tuple()
  def revoke_principal_tx(db, principal_id) do
    case query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]) do
      {:ok, [["active"]]} ->
        with {:ok, held} <-
               query(
                 db,
                 "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
                 [principal_id]
               ),
             {:ok, revision} <- next_revision(db),
             :ok <- clear_override_for_principal(db, principal_id),
             {:ok, []} <-
               query(db, "UPDATE principals SET status = 'revoked' WHERE principal_id = ?", [
                 principal_id
               ]),
             :ok <- authority_event(db, revision, "principal_revoked", principal_id),
             {:ok, _held_revision} <- reject_held_batch(db, held, "principal_revoked"),
             {:ok, final_revision} <-
               invalidate_execution_for(db, {:principal, principal_id}, "principal_revoked") do
          {:commit, {:ok, final_revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :principal_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  @spec revoke_target_grant_tx(term(), String.t(), String.t()) :: tuple()
  def revoke_target_grant_tx(db, principal_id, thing_id) do
    with {:ok, [["active"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]),
         {:ok, [[^thing_id]]} <-
           query(
             db,
             "SELECT thing_id FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, held} <-
           query(
             db,
             "SELECT o.principal_id, o.authority_epoch, o.operation_id FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE o.state = 'held' AND r.disposition = 'held' AND o.principal_id = ? AND r.target_id = ? ORDER BY o.authority_epoch, o.operation_id",
             [principal_id, thing_id]
           ),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_grant(db, principal_id, thing_id),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           authority_event(db, revision, "target_grant_revoked", "#{principal_id}/#{thing_id}"),
         {:ok, _held_revision} <- reject_held_batch(db, held, "target_grant_revoked"),
         {:ok, final_revision} <-
           invalidate_execution_for(
             db,
             {:target_grant, principal_id, thing_id},
             "target_grant_revoked"
           ) do
      {:commit, {:ok, final_revision}}
    else
      {:ok, _} -> {:rollback, {:policy, :target_grant_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
    end
  end

  @spec rotate_principal_credential_tx(term(), String.t(), binary(), binary()) :: tuple()
  def rotate_principal_credential_tx(db, principal_id, hash, credential) do
    with {:ok, [["active"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
             [principal_id]
           ),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_principal(db, principal_id),
         {:ok, []} <-
           query(
             db,
             "UPDATE principals SET credential_hash = ? WHERE principal_id = ? AND status = 'active'",
             [hash, principal_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "principal_credential_rotated", principal_id),
         {:ok, _held_revision} <- reject_held_batch(db, held, "credential_rotated"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, {:principal, principal_id}, "credential_rotated") do
      {:commit, {:ok, credential, final_revision}}
    else
      {:ok, _} -> {:rollback, {:policy, :principal_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
    end
  end

  @spec grant_target_and_rotate_tx(term(), String.t(), String.t(), binary(), binary()) :: tuple()
  def grant_target_and_rotate_tx(db, principal_id, thing_id, hash, credential) do
    with {:ok, [[permissions_json, "active"]]} <-
           query(db, "SELECT permissions, status FROM principals WHERE principal_id = ?", [
             principal_id
           ]),
         {:ok, _permissions} <- Registry.decode_permissions(permissions_json),
         {:ok, [["active"]]} <-
           query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [thing_id]),
         {:ok, [[grant_count]]} <-
           query(db, "SELECT COUNT(*) FROM principal_targets WHERE principal_id = ?", [
             principal_id
           ]),
         true <- is_integer(grant_count) and grant_count < 32,
         {:ok, []} <-
           query(
             db,
             "SELECT thing_id FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
             [principal_id]
           ),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_principal(db, principal_id),
         {:ok, []} <-
           query(db, "INSERT INTO principal_targets VALUES (?, ?)", [principal_id, thing_id]),
         {:ok, []} <-
           query(
             db,
             "UPDATE principals SET credential_hash = ? WHERE principal_id = ? AND status = 'active'",
             [hash, principal_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           authority_event(
             db,
             revision,
             "target_granted_credential_rotated",
             "#{principal_id}/#{thing_id}"
           ),
         {:ok, _held_revision} <- reject_held_batch(db, held, "credential_rotated"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, {:principal, principal_id}, "credential_rotated") do
      {:commit, {:ok, credential, final_revision}}
    else
      false -> {:rollback, {:policy, :target_grant_capacity}}
      {:ok, [[_thing_id]]} -> {:rollback, {:policy, :target_grant_exists}}
      {:ok, _} -> {:rollback, {:policy, :principal_or_target_unavailable}}
      {:error, :corrupt_principal} -> {:rollback, :corrupt_principal}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
    end
  end

  defp active_targets(db, target_ids) do
    Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
      case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [target_id]) do
        {:ok, [["active"]]} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, {:policy, :target_unavailable}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_targets(db, principal_id, target_ids) do
    Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
      case query(db, "INSERT INTO principal_targets VALUES (?, ?)", [principal_id, target_id]) do
        {:ok, []} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
