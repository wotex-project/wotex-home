defmodule WotexHome.Durable.Store.ExplicitPower do
  @moduledoc "Store-derived explicit power work and scoped read capture. Owns no bearer, timer, connection or transport."

  alias WotexHome.Id
  alias WotexHome.Durable.Receipt

  alias WotexHome.Durable.Store.{
    Access,
    Integrity,
    MaintenanceWriter,
    ObservationWriter,
    ProfilePins,
    RefreshWriter,
    RequestLedger,
    RuleWriter
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @max 9_223_372_036_854_775_807
  @denials ~w(invalid_guard_input not_explicit_request stale_refresh_basis refresh_unavailable)a

  def pending(db, after_revision) when is_integer(after_revision) and after_revision in 0..@max do
    with :ok <- Integrity.validate_snapshot(db),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, rows} <-
           query(
             db,
             """
             SELECT r.principal_id,r.authority_epoch,r.operation_id,c.created_revision
             FROM request_receipts r JOIN request_causal_roots c USING(principal_id,authority_epoch,operation_id)
             WHERE c.origin='explicit_request' AND c.created_revision>? AND
                   r.disposition IN ('held','queued') AND r.capability_key='power' AND r.value_kind='boolean'
             ORDER BY c.created_revision LIMIT 17
             """,
             [after_revision]
           ) do
      selected = Enum.take(rows, 16)

      {:ok,
       %{
         requests:
           Enum.map(selected, fn [principal, epoch, operation, created] ->
             %{
               principal_id: principal,
               authority_epoch: epoch,
               operation_id: operation,
               created_revision: created
             }
           end),
         next_revision:
           case List.last(selected) do
             nil -> after_revision
             [_, _, _, created] -> created
           end,
         has_more: length(rows) > 16
       }}
    else
      error -> normalize(error)
    end
  end

  def pending(_, _), do: {:error, :invalid_guard_input}

  def refresh_basis(db, principal, epoch, operation, clock) do
    with :ok <- valid_identity(principal, epoch, operation),
         :ok <- Integrity.validate_snapshot(db),
         :ok <- MaintenanceWriter.guard(db),
         :ok <- explicit_origin(db, principal, epoch, operation),
         {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         true <- "control:ordinary" in permissions,
         {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
         {:ok, receipt} <- RequestLedger.decode_receipt(principal, epoch, operation, row),
         :ok <- held(receipt),
         {:ok, expected, target, profile} <- power_shape(row),
         {:ok, [[current_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key='authority_epoch'"),
         :ok <- same(epoch, current_epoch, :stale_authority_epoch),
         {:ok, basis} <-
           RefreshWriter.lifx_refresh_basis_for_principal(db, principal, permissions, target),
         :ok <- same(expected, basis.resource_revision, :stale_resource_revision),
         :ok <- same(profile, basis.thing.profile_ref, :stale_refresh_basis),
         :ok <-
           ProfilePins.require_current(
             db,
             :request,
             basis.thing,
             basis.resource_revision,
             {principal, epoch, operation}
           ),
         :ok <- RuleWriter.execution_guard(db, principal, epoch, operation, clock) do
      {:ok, Map.put(basis, :receipt, receipt)}
    else
      false -> {:error, :permission_denied}
      {:ok, []} -> {:error, :not_found}
      error -> normalize(error)
    end
  end

  def commit_refresh(db, basis, pairs, clock) do
    case repeat_basis(db, basis, clock) do
      :ok ->
        ObservationWriter.record_lifx_refresh_batch(
          db,
          pairs,
          WotexHome.Durable.Store.ClockContext.receipt(clock)
        )

      {:error, reason} ->
        if policy_denial?(reason), do: {:rollback, {:policy, reason}}, else: {:rollback, reason}
    end
  end

  def repeat_basis(db, %{receipt: %Receipt{} = receipt} = basis, clock) do
    with {:ok, current} <-
           refresh_basis(
             db,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             clock
           ),
         do: same(current, basis, :stale_refresh_basis)
  end

  def repeat_basis(_, _, _), do: {:error, :invalid_guard_input}

  def policy_denial?(reason),
    do: reason in @denials or WotexHome.Durable.Store.ExecutionWriter.inspection_policy?(reason)

  defp valid_identity(principal, epoch, operation) do
    if Id.valid?(principal) and Id.valid?(operation) and is_integer(epoch) and epoch in 0..@max,
      do: :ok,
      else: {:error, :invalid_guard_input}
  end

  defp held(%{disposition: :held}), do: :ok
  defp held(_), do: {:error, :request_not_held}
  defp same(value, value, _), do: :ok
  defp same(_, _, reason), do: {:error, reason}

  defp power_shape([expected, target, "power", "boolean", a, nil, profile | _])
       when a in ["0", "1"],
       do: {:ok, expected, target, profile}

  defp power_shape(_), do: {:error, :unsupported_capability}

  defp explicit_origin(db, principal, epoch, operation) do
    case query(
           db,
           "SELECT origin FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, [["explicit_request"]]} ->
        :ok

      {:ok, [[origin]]} when origin in ["legacy_request", "schedule_occurrence"] ->
        {:error, :not_explicit_request}

      {:ok, []} ->
        {:error, :not_found}

      error ->
        normalize(error)
    end
  end

  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :store_unavailable}
end
