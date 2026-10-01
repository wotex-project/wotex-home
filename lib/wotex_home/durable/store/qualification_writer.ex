defmodule WotexHome.Durable.Store.QualificationWriter do
  @moduledoc """
  Stateless LIFX profile-qualification transactions for the single Store writer.

  The Store verifies call shape and owns the surrounding transaction. This
  module rechecks the active principal, target grant, enrollment binding,
  declaration and pinned artifacts before returning a commit or rollback
  result. It never opens, closes or retains the supplied database handle.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, Journal}
  alias WotexHome.Lifx.{ProductRegistry, ProfileBasis}
  alias WotexHome.Qualification.Claims
  alias WotexHome.Semantics.{Capability, Thing}

  import WotexHome.Durable.Store.SQL, only: [query: 3]
  import Access, only: [allowed_targets: 2, authenticate: 2, enrolled_thing: 2]
  import Journal, only: [authority_event: 4, next_revision: 1]

  @doc "Commits one fully verified LIFX power-profile qualification."
  @spec qualify_lifx_power(term(), binary(), map(), map(), String.t()) :: tuple()
  def qualify_lifx_power(db, hash, verified, basis, claim_root) do
    with :ok <- qualification_actor(db, hash, verified.thing_id),
         :ok <- qualification_current_basis(db, verified, basis),
         :ok <- Claims.put(claim_root, verified),
         {:ok, existing} <-
           query(
             db,
             "SELECT evidence_ref, status, revision FROM profile_qualifications WHERE thing_id = ?",
             [verified.thing_id]
           ) do
      case existing do
        [] ->
          insert_power_qualification(db, verified)

        [[evidence_ref, "qualified", revision]]
        when evidence_ref == verified.evidence_ref ->
          {:rollback, {:unchanged, {:ok, revision}}}

        _ ->
          {:rollback, {:policy, :qualification_conflict}}
      end
    else
      {:error, reason}
      when reason in [
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :stale_resource_revision,
             :basis_changed,
             :qualification_conflict
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_enrollment}
    end
  end

  @doc "Revalidates a stored qualification before execution admission or handoff."
  @spec qualified_power_profile(term(), String.t(), String.t(), non_neg_integer(), map()) ::
          {:ok, String.t()} | {:error, atom()}
  def qualified_power_profile(db, target_id, profile_ref, resource_revision, qualification_state) do
    with {:ok,
          [
            [
              evidence_ref,
              registry_digest,
              runtime_digest,
              identity_digest,
              basis_digest,
              document
            ]
          ]} <-
           query(
             db,
             "SELECT q.evidence_ref, q.registry_digest, q.runtime_digest, q.identity_digest, q.basis_digest, t.document FROM profile_qualifications q JOIN enrollment_bindings b ON b.thing_id = q.thing_id JOIN enrolled_things t ON t.thing_id = q.thing_id JOIN principals p ON p.principal_id = b.operator_id WHERE q.thing_id = ? AND q.profile_ref = ? AND q.resource_revision = ? AND q.status = 'qualified' AND t.status = 'active' AND t.resource_revision = q.resource_revision AND b.digest_version = 2 AND b.identity_digest = q.identity_digest AND b.profile_ref = q.profile_ref AND p.status = 'active'",
             [target_id, profile_ref, resource_revision]
           ),
         true <- Id.valid?(evidence_ref) and is_binary(identity_digest),
         true <- registry_digest == ProductRegistry.pinned_digest(),
         {:ok, ^runtime_digest} <- ProfileBasis.runtime_digest(),
         {:ok, verified} <-
           Claims.verify(
             qualification_state.qualification_claim_root,
             evidence_ref,
             qualification_state.qualification_case_keys,
             qualification_state.qualification_decision_keys
           ),
         true <-
           verified.thing_id == target_id and verified.profile_ref == profile_ref and
             verified.resource_revision == resource_revision and
             verified.identity_digest == identity_digest and
             verified.basis_digest == basis_digest and
             verified.declaration_digest == qualification_digest(document) and
             verified.registry_digest == registry_digest and
             verified.runtime_digest == runtime_digest do
      {:ok, evidence_ref}
    else
      {:error, :runtime_artifact_unavailable} ->
        {:error, :runtime_artifact_unavailable}

      {:error, :qualification_artifact_unavailable} ->
        {:error, :qualification_artifact_unavailable}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :profile_unqualified}
    end
  end

  defp qualification_actor(db, hash, thing_id) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "qualify:profile" in permissions,
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, thing_id) do
      :ok
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp qualification_current_basis(db, verified, basis) do
    with {:ok, %Thing{} = thing, resource_revision} <- enrolled_thing(db, verified.thing_id),
         true <- resource_revision == verified.resource_revision,
         true <-
           thing.role == "Light" and thing.profile_ref == verified.profile_ref and
             map_size(thing.capabilities) == 1,
         {:ok, %Capability{} = power} <- Thing.capability(thing, "power"),
         true <-
           power.operations == ["read", "write"] and
             power.evidence_ref == basis.qualification_ref,
         {:ok, document} <- Registry.encode_thing(thing),
         true <-
           qualification_digest(document) == basis.declaration_digest and
             verified.registry_digest == ProductRegistry.pinned_digest(),
         {:ok,
          [
            [
              identity_digest,
              qualification_ref,
              profile_ref,
              digest_version,
              manufacturer,
              model,
              firmware,
              operator_status
            ]
          ]} <-
           query(
             db,
             "SELECT b.identity_digest, b.qualification_ref, b.profile_ref, b.digest_version, h.manufacturer, h.model, h.firmware, p.status FROM enrollment_bindings b JOIN enrollment_review_history h ON h.thing_id = b.thing_id AND h.revision = b.revision JOIN principals p ON p.principal_id = b.operator_id WHERE b.thing_id = ?",
             [verified.thing_id]
           ),
         true <-
           identity_digest == verified.identity_digest and
             qualification_ref == basis.qualification_ref and
             profile_ref == verified.profile_ref and digest_version == 2 and
             operator_status == "active",
         {vendor_id, product_id} <- basis.product,
         {major, minor} <- basis.firmware,
         true <-
           manufacturer == "lifx.vendor.#{vendor_id}" and
             model == "lifx.product.#{product_id}" and firmware == "#{major}.#{minor}" do
      :ok
    else
      false -> {:error, :basis_changed}
      {:ok, %Thing{}, _revision} -> {:error, :stale_resource_revision}
      {:ok, []} -> {:error, :basis_changed}
      :error -> {:error, :basis_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp insert_power_qualification(db, verified) do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_qualifications VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'qualified', ?)",
             [
               verified.thing_id,
               verified.profile_ref,
               verified.resource_revision,
               verified.identity_digest,
               verified.basis_digest,
               verified.registry_digest,
               verified.runtime_digest,
               verified.evidence_ref,
               revision
             ]
           ),
         :ok <- authority_event(db, revision, "profile_qualified", verified.thing_id) do
      {:commit, {:ok, revision}}
    else
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_enrollment}
    end
  end

  defp qualification_digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
