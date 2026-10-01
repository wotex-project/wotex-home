defmodule WotexHome.Durable.Store.ReviewReadModel do
  @moduledoc """
  Bounded durable projection used by rule-candidate review.

  The Store invokes this module synchronously while it owns the supplied
  database handle. The module retains no state, performs no writes and cannot
  become a second SQLite owner.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.Access
  alias WotexHome.Semantics.Thing

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  import Access, only: [authenticate: 2]

  @max_i64 9_223_372_036_854_775_807

  @spec inputs(Exqlite.Sqlite3.db(), binary()) ::
          {:ok, %{String.t() => Thing.t()}, non_neg_integer()} | {:error, atom()}
  def inputs(db, credential) do
    with {:ok, things, _resources, revision} <- basis(db, credential) do
      {:ok, things, revision}
    end
  end

  @doc "Exact declaration/resource snapshot for immutable candidate retention."
  def basis(db, credential) do
    with {:ok, principal_id} <- principal(db, credential),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, rows} <- catalogue_rows(db, principal_id, "", 33),
         true <- rows != [] and length(rows) <= 32,
         {:ok, things} <- review_things(rows) do
      resources =
        Enum.map(rows, fn [id, _profile, document, resource_revision] ->
          %{"thing_id" => id, "document" => document, "resource_revision" => resource_revision}
        end)

      {:ok, things, resources, revision}
    else
      false ->
        {:error, :review_scope_unavailable}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  @spec current(Exqlite.Sqlite3.db(), binary(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def current(db, credential, watermark) do
    with true <- is_integer(watermark) and watermark >= 0 and watermark <= @max_i64,
         {:ok, _principal_id} <- principal(db, credential),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- matching_watermark(watermark, revision) do
      :ok
    else
      false ->
        {:error, :invalid_review_watermark}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :resnapshot_required
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  @doc "Authenticate the current reviewer; a recorded result never authenticates its reader."
  def principal(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "rule:review" in permissions do
      {:ok, principal_id}
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp catalogue_rows(db, principal_id, after_id, limit) do
    query(
      db,
      "SELECT t.thing_id, t.profile_ref, t.document, t.resource_revision FROM enrolled_things t JOIN principal_targets g ON g.thing_id = t.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND t.thing_id > ? ORDER BY t.thing_id LIMIT ?",
      [principal_id, after_id, limit]
    )
  end

  defp review_things(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn
      [thing_id, profile_ref, document, revision], {:ok, things} ->
        case Registry.decode_thing(document) do
          {:ok, %Thing{id: ^thing_id, profile_ref: ^profile_ref} = thing}
          when is_integer(revision) and revision >= 0 ->
            {:cont, {:ok, Map.put(things, thing_id, thing)}}

          _ ->
            {:halt, {:error, :corrupt_enrollment}}
        end
    end)
  end

  defp matching_watermark(revision, revision), do: :ok
  defp matching_watermark(_watermark, _revision), do: {:error, :resnapshot_required}
end
