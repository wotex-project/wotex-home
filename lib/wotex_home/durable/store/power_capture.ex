defmodule WotexHome.Durable.Store.PowerCapture do
  @moduledoc "Borrowed original-author LIFX read scope. Explicit and temporal origins remain separately required; no bearer, clock owner, connection or transport."
  alias WotexHome.Id

  alias WotexHome.Durable.Store.{
    Access,
    Integrity,
    MaintenanceWriter,
    ProfilePins,
    RefreshWriter,
    RequestLedger,
    RuleWriter
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @max 9_223_372_036_854_775_807

  def basis(db, principal, epoch, operation, clock, origin, phases)
      when origin in ["explicit_request", "schedule_occurrence"] and
             phases in [[:held], [:held, :queued]] do
    with :ok <- valid_identity(principal, epoch, operation),
         :ok <- Integrity.validate_snapshot(db),
         :ok <- MaintenanceWriter.guard(db),
         :ok <- required_origin(db, principal, epoch, operation, origin),
         {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         true <- allowed?(permissions, origin),
         {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
         {:ok, receipt} <- RequestLedger.decode_receipt(principal, epoch, operation, row),
         :ok <- pending_phase(receipt, phases),
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

  def basis(_, _, _, _, _, _, _), do: {:error, :invalid_guard_input}

  defp valid_identity(principal, epoch, operation) do
    if Id.valid?(principal) and Id.valid?(operation) and is_integer(epoch) and epoch in 0..@max,
      do: :ok,
      else: {:error, :invalid_guard_input}
  end

  defp pending_phase(%{disposition: phase}, phases) do
    if phase in phases, do: :ok, else: {:error, :request_not_held}
  end

  defp same(value, value, _), do: :ok
  defp same(_, _, reason), do: {:error, reason}

  defp power_shape([expected, target, "power", "boolean", a, nil, profile | _])
       when a in ["0", "1"],
       do: {:ok, expected, target, profile}

  defp power_shape(_), do: {:error, :unsupported_capability}

  defp required_origin(db, principal, epoch, operation, expected) do
    case query(
           db,
           "SELECT origin FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, [[^expected]]} ->
        :ok

      {:ok, [[other]]}
      when other in ["explicit_request", "legacy_request", "schedule_occurrence"] ->
        {:error,
         if(expected == "explicit_request",
           do: :not_explicit_request,
           else: :not_scheduled_request
         )}

      {:ok, []} ->
        {:error, :not_found}

      error ->
        normalize(error)
    end
  end

  defp allowed?(permissions, "explicit_request"), do: "control:ordinary" in permissions

  defp allowed?(permissions, "schedule_occurrence"),
    do: Enum.all?(~w(rule:review rule:manage control:ordinary), &(&1 in permissions))

  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :store_unavailable}
end
