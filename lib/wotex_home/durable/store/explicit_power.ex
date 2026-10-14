defmodule WotexHome.Durable.Store.ExplicitPower do
  @moduledoc """
  Derives explicit Light-power work and commits its scoped fresh read reports.

  Pending selection follows retained revision order. Refresh/delivery basis
  functions resolve the original receipt, current author, target and exact
  profile; `commit_refresh/4` repeats the basis checks before publishing
  correlated observations. Repeat checks preserve original receipt identity.

  This Store collaborator owns no bearer, timer, connection or transport.
  Authority performs the read through the selected capture owner, and a fresh
  report remains separate from command admission, handoff and physical result.
  """

  alias WotexHome.Durable.Receipt

  alias WotexHome.Durable.Store.{
    Integrity,
    MaintenanceWriter,
    ObservationWriter
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @max 9_223_372_036_854_775_807
  @denials ~w(invalid_guard_input not_explicit_request stale_refresh_basis refresh_unavailable)a

  def pending(db, after_revision) when is_integer(after_revision) and after_revision in 0..@max do
    with :ok <- Integrity.validate_snapshot(db),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, [[window_revision]]} <- query(db, "SELECT value FROM meta WHERE key='revision'"),
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
         window_revision: window_revision,
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
    request_basis(db, principal, epoch, operation, clock, [:held])
  end

  def delivery_basis(db, principal, epoch, operation, clock),
    do: request_basis(db, principal, epoch, operation, clock, [:held, :queued])

  defp request_basis(db, principal, epoch, operation, clock, phases),
    do:
      WotexHome.Durable.Store.PowerCapture.basis(
        db,
        principal,
        epoch,
        operation,
        clock,
        "explicit_request",
        phases
      )

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

  defp same(value, value, _), do: :ok
  defp same(_, _, reason), do: {:error, reason}

  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :store_unavailable}
end
