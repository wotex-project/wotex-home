defmodule WotexHome.Durable.Store.ProfileByteContext do
  @moduledoc """
  Store-call-local byte checks, prepared outside the authority transaction.

  Only Store invokes prepare/3 and clear/1 on its owned connection. The TEMP
  rows contain verified digest commitments, never artifact bytes or durable
  authority. Runtime guards require them; archive integrity uses retained rows
  without treating missing external bytes as corruption. Clear before and after
  each call so verification cannot survive a reply, retry, exception or restart.
  """

  alias WotexHome.Profiles.{Codec, Custody}
  alias WotexHome.Lifx.ProfileBasis
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @guarded ~w(native_target_change inspect_held_power inspect_held_color record record_batch commit_lifx_refresh authorize_source_epoch lifx_refresh_basis rule_facts_live set_invariant admit_rule activate_rule invoke_rule submit_request settle_held_power_noop settle_held_color_noop admit_held_power claim_queued_power claim_lifx_power handoff_claimed_power settle_power_readback reconcile_unknown_power qualify_lifx_power)a

  def initialize(db) do
    case query(
           db,
           "CREATE TEMP TABLE profile_byte_checks (artifact_digest TEXT PRIMARY KEY, projection_digest TEXT NOT NULL, registry_digest TEXT NOT NULL, runtime_digest TEXT NOT NULL)"
         ) do
      {:ok, []} -> :ok
      _ -> {:error, :profile_context_unavailable}
    end
  end

  def clear(db) do
    case query(db, "DELETE FROM temp.profile_byte_checks") do
      {:ok, []} -> :ok
      _ -> {:error, :profile_context_unavailable}
    end
  end

  def prepare(db, custody, request) do
    with :ok <- clear(db) do
      if guarded?(request), do: verify_current(db, custody), else: :ok
    end
  end

  @doc "Authenticated catalogue reads may check retained artifacts outside a transaction."
  def prepare_catalogue(db, custody) do
    with :ok <- clear(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT artifact_digest,projection_digest,registry_digest FROM portable_profiles ORDER BY artifact_digest LIMIT 65"
           ),
         true <- length(rows) <= 64 and Enum.all?(rows, &valid_row?/1) do
      retain_checks(db, custody, rows)
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  def artifact_available?(db, digest, projection, registry) do
    case query(
           db,
           "SELECT projection_digest,registry_digest FROM temp.profile_byte_checks WHERE artifact_digest=?",
           [digest]
         ) do
      {:ok, [[^projection, ^registry]]} -> true
      _ -> false
    end
  end

  def available?(db, digest, projection, registry, runtime) do
    case query(
           db,
           "SELECT projection_digest,registry_digest,runtime_digest FROM temp.profile_byte_checks WHERE artifact_digest=?",
           [digest]
         ) do
      {:ok, [[^projection, ^registry, ^runtime]]} -> :ok
      {:ok, [[^projection, ^registry, _]]} -> {:error, :profile_basis_changed}
      {:ok, _} -> {:error, :profile_artifact_unavailable}
      _ -> {:error, :profile_artifact_unavailable}
    end
  end

  defp guarded?(request) when is_tuple(request) and tuple_size(request) > 0,
    do: elem(request, 0) in @guarded

  defp guarded?(_), do: false

  defp verify_current(db, custody) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT DISTINCT p.artifact_digest,p.projection_digest,p.registry_digest FROM profile_current c JOIN profile_selection_history h ON h.revision=c.selection_revision JOIN portable_profiles p ON p.artifact_digest=h.artifact_digest WHERE c.state='selected' ORDER BY p.artifact_digest LIMIT 65"
           ),
         true <- length(rows) <= 64 and Enum.all?(rows, &valid_row?/1) do
      retain_checks(db, custody, rows)
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp retain_checks(db, custody, rows) do
    {available, runtime} = verified(custody, rows)

    Enum.reduce_while(available, :ok, fn [digest, projection, registry], :ok ->
      case query(db, "INSERT INTO temp.profile_byte_checks VALUES (?,?,?,?)", [
             digest,
             projection,
             registry,
             runtime
           ]) do
        {:ok, []} -> {:cont, :ok}
        _ -> {:halt, {:error, :profile_context_unavailable}}
      end
    end)
  end

  defp valid_row?([raw, projection, registry]),
    do: Enum.all?([raw, projection, registry], &Codec.digest?/1)

  defp valid_row?(_), do: false

  defp verified(_custody, []), do: {[], nil}
  defp verified(nil, _rows), do: {[], nil}

  defp verified(custody, rows) do
    with {:ok, available} <- Custody.verify_many(custody, rows),
         true <- is_list(available) and Enum.all?(available, &(&1 in rows)) do
      runtime =
        case ProfileBasis.runtime_digest() do
          {:ok, digest} -> digest
          _ -> "unavailable"
        end

      {available, runtime}
    else
      _ -> {[], nil}
    end
  catch
    :exit, _ -> {[], nil}
  end
end
