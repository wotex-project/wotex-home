defmodule WotexHome.Durable.Store.ThingReadModel do
  @moduledoc "Bounded current-scope inspection using the sole Store's receipt clock."
  alias WotexHome.{Id, Durable.Registry}
  alias WotexHome.Durable.Store.{Access, FactReadModel, ProfileGuard, StateReadModel}
  import WotexHome.Durable.Store.SQL, only: [query: 2]
  @profile_denials ProfileGuard.denials()

  def read(db, credential, id, {boot, now}) do
    with :ok <- identifier(id),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         :ok <- permission(permissions),
         {:ok, targets} <- Access.allowed_targets(db, principal),
         :ok <- granted(targets, id),
         {:ok, thing, resource} <- Access.enrolled_thing(db, id),
         {:ok, [[revision, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         true <-
           is_integer(revision) and revision >= resource and is_integer(epoch) and epoch >= 1,
         {:ok, document} <- Registry.encode_thing(thing),
         {:ok, declaration} <- JSON.decode(document),
         {:ok, profile} <- profile(db, thing, resource),
         {:ok, capabilities} <- capabilities(db, thing, profile, {boot, now}) do
      {:ok,
       %{
         format: "wotex-home.thing-current.v1",
         principal_id: principal,
         authority_epoch: epoch,
         store_revision: revision,
         store_boot_epoch: boot,
         sampled_monotonic_ms: now,
         resource_revision: resource,
         declaration: declaration,
         capabilities: capabilities
       }}
    else
      false -> {:error, :corrupt_value}
      error -> error
    end
  end

  defp identifier(id), do: if(Id.valid?(id), do: :ok, else: {:error, :invalid_thing_inspection})

  defp permission(permissions),
    do:
      if(Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
        do: :ok,
        else: {:error, :permission_denied}
      )

  defp granted(targets, id),
    do: if(MapSet.member?(targets, id), do: :ok, else: {:error, :permission_denied})

  defp profile(db, thing, resource) do
    case ProfileGuard.current(db, thing, resource) do
      {:ok, _} -> {:ok, "usable"}
      {:error, reason} when reason in @profile_denials -> {:ok, Atom.to_string(reason)}
      error -> error
    end
  end

  defp capabilities(db, thing, profile, clock) do
    Enum.reduce_while(Enum.sort(thing.capabilities), {:ok, []}, fn {key, capability},
                                                                   {:ok, entries} ->
      case FactReadModel.report_detail(db, thing.id, key, capability, clock) do
        {:ok, detail} ->
          report =
            if detail.observation do
              StateReadModel.observation_item(
                detail.observation,
                detail.revision,
                capability.profile_ref,
                capability.evidence_ref
              )
              |> Map.merge(%{
                "received_store_boot_epoch" => detail.receipt_epoch,
                "received_store_monotonic_ms" => detail.receipt_ms
              })
            end

          freshness = if profile == "usable", do: detail.freshness, else: "profile_unavailable"

          entry = %{
            key: key,
            current_value: if(freshness == "fresh", do: report["value"]),
            report: report,
            freshness: freshness,
            age_ms: detail.age_ms,
            remaining_ms: if(freshness == "fresh", do: detail.remaining_ms, else: 0),
            profile_status: profile
          }

          {:cont, {:ok, [entry | entries]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end
end
