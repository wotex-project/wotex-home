defmodule WotexHome.Durable.Store.OverrideWriter do
  @moduledoc """
  Stateless operator-override transactions for the single Store writer.

  The Store owns the clock origin, call validation, transaction and SQLite
  connection. This module receives only validated monotonic values, the active
  boot epoch and the Store-owned handle for one synchronous call. It performs
  no device I/O and retains no process or database state.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, Journal}
  alias WotexHome.Rules.OverrideLease
  alias WotexHome.Semantics.{Capability, Thing}

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  import Access, only: [allowed_targets: 2, authenticate: 2, enrolled_thing: 2]
  import Journal, only: [authority_event: 4, next_revision: 1]

  @max_i64 9_223_372_036_854_775_807

  @spec owned_override_operation_ids(term(), String.t(), [OverrideLease.t()]) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, :corrupt_override}
  def owned_override_operation_ids(db, principal_id, leases) do
    Enum.reduce_while(leases, {:ok, %{}}, fn lease, {:ok, found} ->
      if lease.operator_id == principal_id do
        case query(
               db,
               "SELECT o.operation_id FROM operator_override_operations o JOIN operator_override_leases l ON l.revision = o.issue_revision WHERE l.target_id = ? AND o.operator_id = ? AND o.revoke_revision IS NULL",
               [lease.target_id, principal_id]
             ) do
          {:ok, [[operation_id]]} ->
            if Id.valid?(operation_id),
              do: {:cont, {:ok, Map.put(found, lease.target_id, operation_id)}},
              else: {:halt, {:error, :corrupt_override}}

          {:ok, []} ->
            {:cont, {:ok, found}}

          _ ->
            {:halt, {:error, :corrupt_override}}
        end
      else
        {:cont, {:ok, found}}
      end
    end)
  end

  @spec issue_override_operation_tx(
          term(),
          binary(),
          pos_integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          String.t()
        ) :: tuple()
  def issue_override_operation_tx(
        db,
        hash,
        epoch,
        operation_id,
        target_id,
        basis_revision,
        duration_ms,
        now_ms,
        boot_epoch
      ) do
    with {:ok, operator_id, _permissions} <- authenticate(db, hash),
         {:ok, rows} <- select_override_operation(db, operator_id, epoch, operation_id) do
      case rows do
        [[^target_id, ^basis_revision, ^duration_ms | _] = row] ->
          case override_operation_receipt(
                 db,
                 row,
                 operator_id,
                 epoch,
                 operation_id,
                 boot_epoch,
                 now_ms
               ) do
            {:ok, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
            {:error, reason} -> {:rollback, reason}
          end

        [_other] ->
          {:rollback, {:policy, :override_operation_conflict}}

        [] ->
          with {:ok, ^operator_id} <- override_actor(db, hash, target_id),
               :ok <- override_operation_capacity(db),
               {:ok, nil} <- active_override_for_target(db, target_id, epoch, boot_epoch, now_ms),
               {:commit, {:ok, lease, revision}} <-
                 issue_override_lease_tx(
                   db,
                   hash,
                   target_id,
                   epoch,
                   basis_revision,
                   now_ms,
                   duration_ms,
                   boot_epoch
                 ),
               {:ok, []} <-
                 query(
                   db,
                   "INSERT INTO operator_override_operations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
                   [
                     operator_id,
                     epoch,
                     operation_id,
                     target_id,
                     basis_revision,
                     duration_ms,
                     lease.start_ms,
                     lease.expires_ms,
                     revision
                   ]
                 ) do
            {:commit,
             {:ok,
              %{
                operator_id: operator_id,
                authority_epoch: epoch,
                operation_id: operation_id,
                target_id: target_id,
                basis_revision: basis_revision,
                duration_ms: duration_ms,
                issue_revision: revision,
                revoke_revision: nil,
                active: true,
                remaining_ms: duration_ms
              }}}
          else
            {:ok, %OverrideLease{}} ->
              {:rollback, {:policy, :override_conflict}}

            {:rollback, reason} ->
              {:rollback, reason}

            {:error, reason} when reason in [:override_operation_capacity] ->
              {:rollback, {:policy, reason}}

            {:error, reason} when reason in [:permission_denied, :unauthorized] ->
              {:rollback, {:policy, reason}}

            {:error, reason} ->
              {:rollback, reason}

            _ ->
              {:rollback, :corrupt_override}
          end

        _ ->
          {:rollback, :corrupt_override}
      end
    else
      {:error, :unauthorized} -> {:rollback, {:policy, :unauthorized}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_override}
    end
  end

  @spec override_operation_status_query(
          term(),
          binary(),
          pos_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, map()} | :not_found | {:error, atom()}
  def override_operation_status_query(db, hash, epoch, operation_id, boot_epoch, now_ms) do
    with {:ok, operator_id, _permissions} <- authenticate(db, hash),
         {:ok, rows} <- select_override_operation(db, operator_id, epoch, operation_id) do
      case rows do
        [] ->
          :not_found

        [row] ->
          override_operation_receipt(
            db,
            row,
            operator_id,
            epoch,
            operation_id,
            boot_epoch,
            now_ms
          )

        _ ->
          {:error, :corrupt_override}
      end
    end
  end

  @spec revoke_override_operation_tx(
          term(),
          binary(),
          pos_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: tuple()
  def revoke_override_operation_tx(db, hash, epoch, operation_id, boot_epoch, now_ms) do
    with {:ok, operator_id, _permissions} <- authenticate(db, hash),
         {:ok, rows} <- select_override_operation(db, operator_id, epoch, operation_id) do
      case rows do
        [] ->
          {:rollback, {:unchanged, :not_found}}

        [row] ->
          case override_operation_receipt(
                 db,
                 row,
                 operator_id,
                 epoch,
                 operation_id,
                 boot_epoch,
                 now_ms
               ) do
            {:ok, %{revoke_revision: revision} = receipt} when is_integer(revision) ->
              {:rollback, {:unchanged, {:ok, receipt}}}

            {:ok, %{active: false}} ->
              {:rollback, {:policy, :override_unavailable}}

            {:ok, %{active: true, target_id: target_id}} ->
              with {:commit, {:ok, revision}} <-
                     revoke_override_lease_tx(db, hash, target_id, epoch, boot_epoch),
                   {:ok, [[_, _, _, _, _, _, ^revision]]} <-
                     select_override_operation(db, operator_id, epoch, operation_id),
                   {:ok, receipt} <-
                     override_operation_receipt(
                       db,
                       List.replace_at(row, 6, revision),
                       operator_id,
                       epoch,
                       operation_id,
                       boot_epoch,
                       now_ms
                     ) do
                {:commit, {:ok, receipt}}
              else
                {:rollback, reason} -> {:rollback, reason}
                {:error, reason} -> {:rollback, reason}
                _ -> {:rollback, :corrupt_override}
              end

            {:error, reason} ->
              {:rollback, reason}
          end

        _ ->
          {:rollback, :corrupt_override}
      end
    else
      {:error, :unauthorized} -> {:rollback, {:policy, :unauthorized}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_override}
    end
  end

  defp select_override_operation(db, operator_id, epoch, operation_id) do
    query(
      db,
      "SELECT target_id, basis_revision, duration_ms, start_ms, expires_ms, issue_revision, revoke_revision FROM operator_override_operations WHERE operator_id = ? AND authority_epoch = ? AND operation_id = ?",
      [operator_id, epoch, operation_id]
    )
  end

  defp override_operation_capacity(db) do
    case query(db, "SELECT COUNT(*) FROM operator_override_operations") do
      {:ok, [[count]]} when is_integer(count) and count < 65_536 ->
        :ok

      {:ok, [[count]]} when is_integer(count) and count >= 65_536 ->
        {:error, :override_operation_capacity}

      _ ->
        {:error, :corrupt_override}
    end
  end

  defp override_operation_receipt(
         db,
         [
           target_id,
           basis_revision,
           duration_ms,
           start_ms,
           expires_ms,
           issue_revision,
           revoke_revision
         ],
         operator_id,
         epoch,
         operation_id,
         boot_epoch,
         now_ms
       ) do
    with true <-
           Id.valid?(target_id) and valid_stored_integer?(basis_revision) and
             is_integer(duration_ms) and duration_ms in 1..86_400_000 and
             valid_stored_integer?(start_ms) and valid_stored_integer?(expires_ms) and
             expires_ms - start_ms == duration_ms and
             valid_stored_integer?(issue_revision) and issue_revision >= 1 and
             (is_nil(revoke_revision) or
                (valid_stored_integer?(revoke_revision) and revoke_revision > issue_revision)),
         {:ok, active_lease} <-
           active_override_for_target(db, target_id, epoch, boot_epoch, now_ms),
         {:ok, current_revision} <-
           query(db, "SELECT revision FROM operator_override_leases WHERE target_id = ?", [
             target_id
           ]) do
      active =
        is_nil(revoke_revision) and
          match?(%OverrideLease{operator_id: ^operator_id}, active_lease) and
          current_revision == [[issue_revision]] and active_lease.start_ms == start_ms and
          active_lease.expires_ms == expires_ms

      {:ok,
       %{
         operator_id: operator_id,
         authority_epoch: epoch,
         operation_id: operation_id,
         target_id: target_id,
         basis_revision: basis_revision,
         duration_ms: duration_ms,
         issue_revision: issue_revision,
         revoke_revision: revoke_revision,
         active: active,
         remaining_ms: if(active, do: max(0, expires_ms - now_ms), else: 0)
       }}
    else
      _ -> {:error, :corrupt_override}
    end
  end

  defp override_operation_receipt(_, _, _, _, _, _, _), do: {:error, :corrupt_override}

  @spec issue_override_lease_tx(
          term(),
          binary(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          String.t()
        ) :: tuple()
  def issue_override_lease_tx(
        db,
        hash,
        target_id,
        authority_epoch,
        basis_revision,
        now_ms,
        duration_ms,
        boot_epoch
      ) do
    with {:ok, operator_id} <- override_actor(db, hash, target_id),
         {:ok, thing, ^basis_revision} <- enrolled_thing(db, target_id),
         true <- override_target?(thing),
         {:ok, [[^authority_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, prior} <-
           query(db, "SELECT target_id FROM operator_override_leases WHERE target_id = ?", [
             target_id
           ]),
         :ok <- override_capacity(db, prior),
         :ok <-
           available_override(
             db,
             target_id,
             operator_id,
             authority_epoch,
             boot_epoch,
             now_ms
           ),
         {:ok, lease} <-
           OverrideLease.new(%{
             "target_id" => target_id,
             "operator_id" => operator_id,
             "authority_epoch" => authority_epoch,
             "start_ms" => now_ms,
             "expires_ms" => now_ms + duration_ms,
             "basis_revision" => basis_revision
           }),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO operator_override_leases VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(target_id) DO UPDATE SET operator_id=excluded.operator_id, authority_epoch=excluded.authority_epoch, boot_epoch=excluded.boot_epoch, start_ms=excluded.start_ms, expires_ms=excluded.expires_ms, basis_revision=excluded.basis_revision, revision=excluded.revision",
             [
               target_id,
               operator_id,
               authority_epoch,
               boot_epoch,
               now_ms,
               now_ms + duration_ms,
               basis_revision,
               revision
             ]
           ),
         :ok <- authority_event(db, revision, "override_lease_issued", target_id) do
      {:commit, {:ok, lease, revision}}
    else
      false ->
        {:rollback, {:policy, :unsupported_override_target}}

      {:ok, %Thing{}, _revision} ->
        {:rollback, {:policy, :stale_resource_revision}}

      {:ok, [[_other_epoch]]} ->
        {:rollback, {:policy, :stale_authority_epoch}}

      {:error, reason}
      when reason in [
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :override_conflict,
             :override_capacity,
             :stale_resource_revision
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_override}
    end
  end

  @spec revoke_override_lease_tx(term(), binary(), String.t(), pos_integer(), String.t()) ::
          tuple()
  def revoke_override_lease_tx(db, hash, target_id, authority_epoch, boot_epoch) do
    with {:ok, operator_id} <- override_actor(db, hash, target_id),
         {:ok, [[^operator_id, ^authority_epoch, ^boot_epoch, issue_revision]]} <-
           query(
             db,
             "SELECT operator_id, authority_epoch, boot_epoch, revision FROM operator_override_leases WHERE target_id = ?",
             [target_id]
           ),
         {:ok, [[^authority_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "DELETE FROM operator_override_leases WHERE target_id = ?", [target_id]),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE operator_override_operations SET revoke_revision = ? WHERE issue_revision = ? AND revoke_revision IS NULL",
             [revision, issue_revision]
           ),
         :ok <- authority_event(db, revision, "override_lease_revoked", target_id) do
      {:commit, {:ok, revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :override_unavailable}}

      {:ok, [[_operator, _epoch, _boot, _revision]]} ->
        {:rollback, {:policy, :override_unavailable}}

      {:ok, [[_other_epoch]]} ->
        {:rollback, {:policy, :stale_authority_epoch}}

      {:error, reason} when reason in [:unauthorized, :permission_denied] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_override}
    end
  end

  @spec active_override_leases_query(
          term(),
          binary(),
          [String.t()],
          non_neg_integer(),
          String.t()
        ) :: {:ok, [OverrideLease.t()]} | {:error, atom()}
  def active_override_leases_query(db, hash, target_ids, now_ms, boot_epoch) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, grants} <- allowed_targets(db, principal_id),
         true <- Enum.all?(target_ids, &MapSet.member?(grants, &1)),
         {:ok, [[authority_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'") do
      Enum.reduce_while(target_ids, {:ok, []}, fn target_id, {:ok, leases} ->
        case active_override_for_target(db, target_id, authority_epoch, boot_epoch, now_ms) do
          {:ok, nil} -> {:cont, {:ok, leases}}
          {:ok, lease} -> {:cont, {:ok, [lease | leases]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, leases} -> {:ok, Enum.reverse(leases)}
        error -> error
      end
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  @spec clear_override_for_target(term(), String.t()) :: :ok | {:error, term()}
  def clear_override_for_target(db, target_id) do
    case query(db, "DELETE FROM operator_override_leases WHERE target_id = ?", [target_id]) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  @spec clear_override_for_principal(term(), String.t()) :: :ok | {:error, term()}
  def clear_override_for_principal(db, principal_id) do
    case query(db, "DELETE FROM operator_override_leases WHERE operator_id = ?", [principal_id]) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  @spec clear_override_for_grant(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear_override_for_grant(db, principal_id, target_id) do
    case query(
           db,
           "DELETE FROM operator_override_leases WHERE operator_id = ? AND target_id = ?",
           [principal_id, target_id]
         ) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  defp override_capacity(_db, [_]), do: :ok

  defp override_capacity(db, []) do
    case query(db, "SELECT COUNT(*) FROM operator_override_leases") do
      {:ok, [[count]]} when is_integer(count) and count < 4_096 ->
        :ok

      {:ok, [[count]]} when is_integer(count) and count >= 4_096 ->
        {:error, :override_capacity}

      _ ->
        {:error, :corrupt_override}
    end
  end

  defp override_capacity(_db, _), do: {:error, :corrupt_override}

  defp available_override(db, target_id, current_operator, authority_epoch, boot_epoch, now_ms) do
    case active_override_for_target(db, target_id, authority_epoch, boot_epoch, now_ms) do
      {:ok, nil} -> :ok
      {:ok, %OverrideLease{operator_id: ^current_operator}} -> :ok
      {:ok, %OverrideLease{}} -> {:error, :override_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp override_actor(db, hash, target_id) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "control:ordinary" in permissions,
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, target_id) do
      {:ok, principal_id}
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp override_target?(%Thing{role: "Light"} = thing) do
    case Thing.capability(thing, "power") do
      {:ok, %Capability{value_kind: "boolean", risk_class: "ordinary", operations: operations}} ->
        "write" in operations

      _ ->
        false
    end
  end

  defp override_target?(_), do: false

  defp active_override_for_target(db, target_id, authority_epoch, boot_epoch, now_ms) do
    case query(
           db,
           "SELECT l.operator_id, l.authority_epoch, l.boot_epoch, l.start_ms, l.expires_ms, l.basis_revision, p.status, t.status, t.resource_revision, t.document, g.principal_id FROM operator_override_leases l JOIN principals p ON p.principal_id = l.operator_id JOIN enrolled_things t ON t.thing_id = l.target_id LEFT JOIN principal_targets g ON g.principal_id = l.operator_id AND g.thing_id = l.target_id WHERE l.target_id = ?",
           [target_id]
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok,
       [
         [
           operator_id,
           lease_epoch,
           lease_boot,
           start_ms,
           expires_ms,
           basis_revision,
           operator_status,
           target_status,
           resource_revision,
           document,
           grant
         ]
       ]} ->
        with {:ok, lease} <-
               OverrideLease.new(%{
                 "target_id" => target_id,
                 "operator_id" => operator_id,
                 "authority_epoch" => lease_epoch,
                 "start_ms" => start_ms,
                 "expires_ms" => expires_ms,
                 "basis_revision" => basis_revision
               }),
             true <- Id.valid?(lease_boot),
             {:ok, thing} <- Registry.decode_thing(document),
             true <- thing.id == target_id do
          if operator_status == "active" and target_status == "active" and
               grant == operator_id and resource_revision == basis_revision and
               lease_boot == boot_epoch and OverrideLease.active?(lease, authority_epoch, now_ms) and
               override_target?(thing),
             do: {:ok, lease},
             else: {:ok, nil}
        else
          _ -> {:error, :corrupt_override}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_override}
    end
  end

  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64
end
