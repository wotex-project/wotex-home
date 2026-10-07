defmodule WotexHome.Durable.Store.RefreshWriter do
  @moduledoc """
  Scoped enrolled-LIFX read basis and transactional report commit.

  Authority authenticates before asking the capture owner for fresh identity
  and reports; this module repeats the binding, declaration, grant and resource
  checks before composing ObservationWriter. It cannot discover, send, retain a
  connection or turn a read into dispatch authority.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.ObservationWriter
  alias WotexHome.Semantics.Thing
  import WotexHome.Durable.Store.SQL, only: [query: 3]

  import WotexHome.Durable.Store.Access,
    only: [authenticate: 2, allowed_targets: 2, usable_thing: 2]

  @profile_denials WotexHome.Durable.Store.ProfileGuard.denials()
  @max_i64 9_223_372_036_854_775_807

  def lifx_refresh_basis_result(db, credential, thing_id) do
    with true <- Id.valid?(thing_id),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, basis} <- lifx_refresh_basis_query(db, hash, thing_id) do
      {:ok, basis}
    else
      false ->
        {:error, :invalid_target}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :refresh_unavailable,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      {:error, reason} when reason in @profile_denials or reason == :corrupt_profile_ledger ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp lifx_refresh_basis_query(db, hash, thing_id) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, thing_id),
         {:ok, %Thing{} = thing, resource_revision} <- usable_thing(db, thing_id),
         {:ok, stable_id, binding_revision} <- lifx_stable_binding(db, thing) do
      {:ok,
       %{
         stable_id: stable_id,
         binding_revision: binding_revision,
         thing: thing,
         resource_revision: resource_revision
       }}
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lifx_stable_binding(db, %Thing{id: thing_id, profile_ref: profile_ref}) do
    case query(
           db,
           "SELECT stable_id, profile_ref, digest_version, revision FROM enrollment_bindings WHERE thing_id = ?",
           [thing_id]
         ) do
      {:ok, [[stable_id, ^profile_ref, 2, revision]]} ->
        if valid_lifx_stable_id?(stable_id) and is_integer(revision) and revision in 1..@max_i64,
          do: {:ok, stable_id, revision},
          else: {:error, :corrupt_enrollment}

      {:ok, []} ->
        {:error, :refresh_unavailable}

      {:ok, [[_stable_id, _binding_profile, digest_version, _revision]]}
      when digest_version in [1, 2] ->
        {:error, :refresh_unavailable}

      {:ok, _} ->
        {:error, :corrupt_enrollment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def commit_lifx_refresh_tx(
        db,
        hash,
        stable_id,
        binding_revision,
        resource_revision,
        thing,
        pairs,
        store_clock
      ) do
    case lifx_refresh_basis_query(db, hash, thing.id) do
      {:ok,
       %{
         stable_id: ^stable_id,
         binding_revision: ^binding_revision,
         resource_revision: ^resource_revision,
         thing: ^thing
       }} ->
        ObservationWriter.record_lifx_refresh_batch(db, pairs, store_clock)

      {:ok, _changed_basis} ->
        {:rollback, {:policy, :stale_refresh_basis}}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :refresh_unavailable
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  def valid_lifx_stable_id?("lifx:" <> serial) when byte_size(serial) == 12,
    do: Regex.match?(~r/\A[0-9a-f]{12}\z/, serial)

  def valid_lifx_stable_id?(_stable_id), do: false
end
