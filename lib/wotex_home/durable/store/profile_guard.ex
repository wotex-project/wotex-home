defmodule WotexHome.Durable.Store.ProfileGuard do
  @moduledoc "Current profile selection/trust/byte guards for runtime Store domains."
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ProfileByteContext, ProfileWriter}
  alias WotexHome.Profiles.LedgerCodec
  import WotexHome.Durable.Store.SQL, only: [query: 3]

  @fields ~w(target_id generation principal_id authority_epoch operation_id previous_selection_revision previous_resource_revision previous_binding_revision artifact_digest projection_digest trust_revision state resource_revision binding_revision runtime_digest review_document thing_document revision)
  @columns Enum.map_join(@fields, ",", &("h." <> &1))
  @denials ~w(profile_selection_unavailable profile_selection_revoked profile_trust_changed profile_author_unavailable profile_artifact_unavailable profile_basis_changed)a
  def denials, do: @denials

  def current(db, thing, resource) do
    with :ok <- ProfileWriter.validate(db), do: current_valid(db, thing, resource)
  end

  defp current_valid(db, thing, resource) do
    case query(
           db,
           "SELECT #{@columns},c.generation,c.state,p.registry_digest FROM profile_current c LEFT JOIN profile_selection_history h ON h.revision=c.selection_revision LEFT JOIN portable_profiles p ON p.artifact_digest=h.artifact_digest WHERE c.target_id=?",
           [thing.id]
         ) do
      {:ok, []} ->
        compiled(db, thing)

      {:ok, [values]} when length(values) == 21 ->
        {fields, [generation, state, registry]} = Enum.split(values, 18)
        row = Map.new(Enum.zip(@fields, fields))

        with {:ok, _} <- LedgerCodec.encode("selection", row),
             true <-
               row["target_id"] == thing.id and row["generation"] == generation and
                 row["state"] == state,
             :ok <- selected(state),
             {:ok, selected_thing} <- Registry.decode_thing(row["thing_document"]),
             true <- selected_thing == thing and row["resource_revision"] == resource,
             {:ok, [["approve", trust, author]]} <-
               query(
                 db,
                 "SELECT action,final_revision,principal_id FROM profile_operations WHERE artifact_digest=? AND action IN ('approve','revoke') ORDER BY final_revision DESC LIMIT 1",
                 [row["artifact_digest"]]
               ),
             :ok <- same_trust(trust, row["trust_revision"]),
             {:ok, permissions} <- Access.active_principal_permissions(db, author),
             :ok <- author_allowed(permissions),
             :ok <-
               ProfileByteContext.available?(
                 db,
                 row["artifact_digest"],
                 row["projection_digest"],
                 registry,
                 row["runtime_digest"]
               ) do
          {:ok, pin(row)}
        else
          false -> {:error, :corrupt_profile_ledger}
          {:ok, [["revoke" | _]]} -> {:error, :profile_trust_changed}
          {:error, :principal_unavailable} -> {:error, :profile_author_unavailable}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :corrupt_profile_ledger}
        end

      _ ->
        {:error, :corrupt_profile_ledger}
    end
  end

  defp compiled(db, thing) do
    case query(db, "SELECT artifact_digest FROM portable_profiles WHERE id || ':' || version=?", [
           thing.profile_ref
         ]) do
      {:ok, []} -> {:ok, nil}
      {:ok, [_]} -> {:error, :profile_selection_unavailable}
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp pin(row) do
    %{
      "target_id" => row["target_id"],
      "artifact_digest" => row["artifact_digest"],
      "projection_digest" => row["projection_digest"],
      "selection_revision" => row["revision"],
      "selection_generation" => row["generation"],
      "trust_revision" => row["trust_revision"],
      "resource_revision" => row["resource_revision"]
    }
  end

  defp selected("selected"), do: :ok
  defp selected("revoked"), do: {:error, :profile_selection_revoked}
  defp selected(_), do: {:error, :corrupt_profile_ledger}
  defp same_trust(value, value), do: :ok
  defp same_trust(_, _), do: {:error, :profile_trust_changed}

  defp author_allowed(permissions),
    do: if("profile:manage" in permissions, do: :ok, else: {:error, :profile_author_unavailable})
end
