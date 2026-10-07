defmodule WotexHome.Durable.Store.Access do
  @moduledoc """
  Stateless authenticated-principal and active-Thing reads for Store domains.

  The functions receive the Store-owned SQLite handle synchronously. They do
  not retain it, open a connection, start a transaction or perform writes.
  Persisted rows are decoded through the closed registries and fail closed when
  their shape no longer matches the Store contract.
  """

  alias WotexHome.Id
  alias WotexHome.Durable.Registry
  alias WotexHome.Semantics.Thing

  import WotexHome.Durable.Store.SQL, only: [query: 3]

  @max_i64 9_223_372_036_854_775_807

  @doc "Authenticates one credential hash and decodes its active permission set."
  @spec authenticate(term(), binary()) ::
          {:ok, String.t(), [String.t()]} | {:error, :unauthorized | :corrupt_principal | term()}
  def authenticate(db, hash) when is_binary(hash) do
    case query(
           db,
           "SELECT principal_id, permissions, status FROM principals WHERE credential_hash = ?",
           [hash]
         ) do
      {:ok, [[principal_id, permissions_json, "active"]]} ->
        with true <- Id.valid?(principal_id),
             {:ok, permissions} <- Registry.decode_permissions(permissions_json),
             :ok <- native_integrity(db, principal_id) do
          {:ok, principal_id, permissions}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :corrupt_principal}
        end

      {:ok, []} ->
        {:error, :unauthorized}

      {:ok, [[_principal_id, _permissions, "revoked"]]} ->
        {:error, :unauthorized}

      {:ok, _} ->
        {:error, :corrupt_principal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def authenticate(_db, _hash), do: {:error, :unauthorized}

  defp native_integrity(db, principal) do
    if WotexHome.NativeSetup.Codec.reserved?(principal),
      do: WotexHome.Durable.Store.NativePrincipalWriter.validate(db),
      else: :ok
  end

  @doc "Loads and validates one active enrolled Thing and resource revision."
  @spec enrolled_thing(term(), String.t()) ::
          {:ok, Thing.t(), non_neg_integer()}
          | {:error, :target_unavailable | :corrupt_enrollment | term()}
  def enrolled_thing(db, target_id) when is_binary(target_id) do
    case query(
           db,
           "SELECT profile_ref, document, resource_revision, status FROM enrolled_things WHERE thing_id = ?",
           [target_id]
         ) do
      {:ok, [[profile_ref, document, resource_revision, "active"]]} ->
        with true <- Id.valid?(target_id),
             {:ok, %Thing{id: ^target_id, profile_ref: ^profile_ref} = thing} <-
               Registry.decode_thing(document),
             true <-
               is_integer(resource_revision) and resource_revision >= 0 and
                 resource_revision <= @max_i64 do
          {:ok, thing, resource_revision}
        else
          _ -> {:error, :corrupt_enrollment}
        end

      {:ok, []} ->
        {:error, :target_unavailable}

      {:ok, [[_profile_ref, _document, _resource_revision, "revoked"]]} ->
        {:error, :target_unavailable}

      {:ok, _} ->
        {:error, :corrupt_enrollment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enrolled_thing(_db, _target_id), do: {:error, :target_unavailable}

  @doc "Runtime declaration with current profile/trust/call-local byte checks."
  def usable_thing(db, target_id) do
    with {:ok, thing, resource} <- enrolled_thing(db, target_id),
         {:ok, _} <- WotexHome.Durable.Store.ProfileGuard.current(db, thing, resource) do
      {:ok, thing, resource}
    end
  end

  @doc "Returns the exact bounded target grant set for one principal."
  @spec allowed_targets(term(), String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, :corrupt_principal | term()}
  def allowed_targets(db, principal_id) when is_binary(principal_id) do
    case query(
           db,
           "SELECT thing_id FROM principal_targets WHERE principal_id = ? ORDER BY thing_id LIMIT 33",
           [principal_id]
         ) do
      {:ok, rows} when length(rows) <= 32 ->
        if Enum.all?(rows, fn
             [target_id] -> Id.valid?(target_id)
             _ -> false
           end) do
          {:ok, MapSet.new(Enum.map(rows, fn [target_id] -> target_id end))}
        else
          {:error, :corrupt_principal}
        end

      {:ok, _rows} ->
        {:error, :corrupt_principal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def allowed_targets(_db, _principal_id), do: {:error, :corrupt_principal}

  @doc "Decodes the permissions of one active principal by stable ID."
  @spec active_principal_permissions(term(), String.t()) ::
          {:ok, [String.t()]} | {:error, :principal_unavailable | :corrupt_principal | term()}
  def active_principal_permissions(db, principal_id) when is_binary(principal_id) do
    case query(db, "SELECT permissions, status FROM principals WHERE principal_id = ?", [
           principal_id
         ]) do
      {:ok, [[document, "active"]]} ->
        with true <- Id.valid?(principal_id),
             {:ok, permissions} <- Registry.decode_permissions(document),
             :ok <- native_integrity(db, principal_id) do
          {:ok, permissions}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :corrupt_principal}
        end

      {:ok, []} ->
        {:error, :principal_unavailable}

      {:ok, [[_document, "revoked"]]} ->
        {:error, :principal_unavailable}

      {:ok, _} ->
        {:error, :corrupt_principal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def active_principal_permissions(_db, _principal_id), do: {:error, :principal_unavailable}
end
