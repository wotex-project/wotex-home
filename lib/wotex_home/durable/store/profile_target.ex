defmodule WotexHome.Durable.Store.ProfileTarget do
  @moduledoc "Authenticated lifecycle read model; retained history is separate from current use."
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{ProfileGuard, ProfileWriter, QualificationHistory}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  def snapshot(db, target) do
    with :ok <- QualificationHistory.validate(db),
         {:ok, meta} <-
           query(
             db,
             "SELECT key,value FROM meta WHERE key IN ('revision','authority_epoch','profile_policy_generation','rule_generation')"
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT profile_ref,document,resource_revision,status FROM enrolled_things WHERE thing_id=?",
             [target]
           ),
         {:ok, state} <- target_state(db, target, rows) do
      pins = Map.new(meta, fn [key, value] -> {key, value} end)

      {:ok,
       Map.merge(state, %{
         target_id: target,
         store_revision: pins["revision"],
         authority_epoch: pins["authority_epoch"],
         policy_generation: pins["profile_policy_generation"],
         rule_generation: pins["rule_generation"]
       })}
    end
  end

  defp target_state(_db, _target, []) do
    {:ok,
     %{
       status: :absent,
       profile_ref: nil,
       declaration: nil,
       resource_revision: 0,
       binding_revision: 0,
       identity: nil,
       identity_status: :absent,
       selection_revision: 0,
       selection_generation: 0,
       selection_state: :absent,
       artifact_digest: nil,
       current_use: :target_unavailable,
       qualification_head: nil
     }}
  end

  defp target_state(db, target, [[profile, document, resource, status]])
       when status in ["active", "revoked"] do
    with {:ok, %{id: ^target, profile_ref: ^profile} = thing} <- Registry.decode_thing(document),
         {:ok, declaration} <- JSON.decode(document),
         {:ok, identity, binding, identity_status} <- identity(db, thing),
         {:ok, selection} <- selection(db, target),
         {:ok, qualification} <- qualification(db, target),
         {:ok, use} <- current_use(db, thing, resource, status) do
      {:ok,
       Map.merge(selection, %{
         status: status,
         profile_ref: profile,
         declaration: declaration,
         resource_revision: resource,
         binding_revision: binding,
         identity: identity,
         identity_status: identity_status,
         current_use: use,
         qualification_head: qualification
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp target_state(_, _, _), do: {:error, :corrupt_enrollment}

  defp identity(db, thing) do
    case ProfileWriter.reviewed_identity(db, thing) do
      {:ok, identity} ->
        {:ok, Map.drop(identity, [:revision]), identity.revision, :reviewed}

      {:error, :review_binding_unavailable} ->
        case query(db, "SELECT revision FROM enrollment_bindings WHERE thing_id=?", [thing.id]) do
          {:ok, [[revision]]} -> {:ok, nil, revision, :review_required}
          {:ok, []} -> {:ok, nil, nil, :review_required}
          _ -> {:error, :corrupt_enrollment}
        end

      error ->
        error
    end
  end

  defp selection(db, target) do
    case query(
           db,
           "SELECT c.generation,c.selection_revision,c.state,h.artifact_digest FROM profile_current c JOIN profile_selection_history h ON h.revision=c.selection_revision WHERE c.target_id=?",
           [target]
         ) do
      {:ok, []} ->
        {:ok,
         %{
           selection_revision: 0,
           selection_generation: 0,
           selection_state: :absent,
           artifact_digest: nil
         }}

      {:ok, [[generation, revision, state, digest]]} ->
        {:ok,
         %{
           selection_revision: revision,
           selection_generation: generation,
           selection_state: state,
           artifact_digest: digest
         }}

      _ ->
        {:error, :corrupt_profile_ledger}
    end
  end

  defp qualification(db, target) do
    fields =
      ~w(profile_ref resource_revision identity_digest basis_digest registry_digest runtime_digest evidence_ref status revision)

    case query(
           db,
           "SELECT #{Enum.join(fields, ",")} FROM profile_qualifications WHERE thing_id=?",
           [target]
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [values]} -> {:ok, Map.new(Enum.zip(fields, values))}
      _ -> {:error, :corrupt_qualification_history}
    end
  end

  defp current_use(_, _, _, "revoked"), do: {:ok, :target_unavailable}

  defp current_use(db, thing, resource, "active") do
    case ProfileGuard.current(db, thing, resource) do
      {:ok, _} ->
        {:ok, :usable}

      {:error, reason} = error ->
        if reason in ProfileGuard.denials(), do: {:ok, reason}, else: error
    end
  end
end
