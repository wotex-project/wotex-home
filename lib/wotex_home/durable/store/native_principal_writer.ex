defmodule WotexHome.Durable.Store.NativePrincipalWriter do
  @moduledoc "Store-owned native custody reconciliation; borrowed handle, verifier only."
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ControllerWriter, Journal}
  alias WotexHome.NativeSetup.Codec
  alias WotexHome.Recovery.ControllerCodec
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @event "native_principal_provisioned"
  @scope ~w(deployment_id owner_id authority_epoch)

  def identity(db) do
    with {:ok, %{state: "active"} = identity} <- ControllerWriter.identity(db),
         :ok <- validate_current(db, identity) do
      {:ok,
       %{
         "deployment_id" => identity.deployment_id,
         "owner_id" => identity.owner_id,
         "authority_epoch" => identity.authority_epoch,
         "store_revision" => identity.store_revision
       }}
    else
      {:ok, _} -> {:error, :source_retired}
      error -> error
    end
  end

  def ensure_tx(db, input) do
    with {:ok, _} <- Codec.encode("ensure", input),
         {:ok, identity} <- identity(db),
         true <- Map.take(identity, @scope) == Map.take(input, @scope),
         {:ok, permissions} <- Codec.permissions(input["role"]),
         {:ok, document} <- Registry.encode_permissions(permissions),
         {:ok, hash} <- Base.decode16(input["verifier"], case: :lower),
         principal = Codec.principal(input["authority_epoch"], input["role"]),
         {:ok, rows} <-
           query(
             db,
             "SELECT credential_hash,permissions,status FROM principals WHERE principal_id=?",
             [
               principal
             ]
           ) do
      case rows do
        [] -> create(db, input, principal, hash, document)
        [[^hash, ^document, "active"]] -> unchanged(db, input, principal)
        [_] -> {:rollback, {:policy, :native_custody_conflict}}
        _ -> {:rollback, :corrupt_native_setup}
      end
    else
      false -> {:rollback, {:policy, :native_owner_changed}}
      {:error, :invalid_native_setup_record} = error -> {:rollback, {:policy, elem(error, 1)}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_native_setup}
    end
  end

  @doc "Read only the exact original creation; never ensure missing custody."
  def existing(db, input) do
    with {:ok, _} <- Codec.encode("existing", input),
         {:ok, identity} <- identity(db),
         true <- Map.take(identity, @scope) == Map.take(input, @scope),
         {:ok, permissions} <- Codec.permissions(input["role"]),
         {:ok, document} <- Registry.encode_permissions(permissions),
         {:ok, hash} <- Base.decode16(input["verifier"], case: :lower),
         principal = Codec.principal(input["authority_epoch"], input["role"]),
         revision = input["creation_revision"],
         {:ok, rows} <-
           query(
             db,
             "SELECT p.credential_hash,p.permissions,p.status,a.revision FROM principals p LEFT JOIN authority_journal a ON a.entity_id=p.principal_id AND a.event_type=? WHERE p.principal_id=? ORDER BY a.revision LIMIT 2",
             [@event, principal]
           ) do
      case rows do
        [[^hash, ^document, "active", ^revision]] -> {:ok, receipt(input, principal, revision)}
        [] -> {:error, :native_custody_conflict}
        [_] -> {:error, :native_custody_conflict}
        _ -> {:error, :corrupt_native_setup}
      end
    else
      false -> {:error, :native_owner_changed}
      {:error, _} = error -> error
      _ -> {:error, :corrupt_native_setup}
    end
  end

  def validate(db) do
    with {:ok, identity} <- ControllerWriter.identity(db), do: validate_current(db, identity)
  end

  defp create(db, input, principal, hash, document) do
    with {:ok, []} <-
           query(db, "SELECT principal_id FROM principals WHERE credential_hash=?", [hash]),
         {:ok, revision} <- Journal.next_revision(db),
         {:ok, []} <-
           query(db, "INSERT INTO principals VALUES (?,?,?,'active')", [principal, hash, document]),
         :ok <- Journal.authority_event(db, revision, @event, principal),
         :ok <- validate(db) do
      {:commit, {:ok, receipt(input, principal, revision)}}
    else
      {:ok, [_]} -> {:rollback, {:policy, :native_custody_conflict}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_native_setup}
    end
  end

  defp unchanged(db, input, principal) do
    case query(db, "SELECT revision FROM authority_journal WHERE event_type=? AND entity_id=?", [
           @event,
           principal
         ]) do
      {:ok, [[revision]]} ->
        {:rollback, {:unchanged, {:ok, receipt(input, principal, revision)}}}

      _ ->
        {:rollback, :corrupt_native_setup}
    end
  end

  defp receipt(input, principal, revision),
    do:
      input
      |> Map.take(@scope ++ ["role"])
      |> Map.merge(%{"principal_id" => principal, "revision" => revision})

  defp validate_current(db, identity) do
    with {:ok, rows} <-
           query(db, """
           SELECT p.principal_id,p.credential_hash,p.permissions,p.status,COUNT(a.revision),MIN(a.revision)
           FROM principals p LEFT JOIN authority_journal a
             ON a.entity_id=p.principal_id AND a.event_type='native_principal_provisioned'
           WHERE p.principal_id GLOB 'native-setup-v1:*'
           GROUP BY p.principal_id ORDER BY p.principal_id LIMIT 261
           """),
         true <- length(rows) <= 260,
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM authority_journal a LEFT JOIN principals p ON p.principal_id=a.entity_id
           WHERE (a.event_type='native_principal_provisioned' AND
             (p.principal_id IS NULL OR a.entity_id NOT GLOB 'native-setup-v1:*'))
             OR (a.event_type='principal_provisioned' AND a.entity_id GLOB 'native-setup-v1:*')
           """),
         {:ok, windows} <- windows(db),
         true <- Enum.all?(rows, &valid_principal?(db, &1, identity, windows)),
         :ok <- WotexHome.Durable.Store.NativeTargetHistory.validate_if_current(db) do
      :ok
    else
      _ -> {:error, :corrupt_native_setup}
    end
  end

  defp windows(db) do
    with {:ok, [[document]]} <- query(db, "SELECT origin_document FROM controller_identity"),
         {:ok, origin} <- ControllerCodec.decode("origin", document),
         {:ok, retirements} <-
           query(
             db,
             "SELECT authority_epoch,revision FROM controller_retirements ORDER BY revision LIMIT 65"
           ),
         {:ok, [[version]]} <- query(db, "PRAGMA user_version"),
         {:ok, acceptances} <- acceptances(db, version) do
      starts = Map.new(acceptances, fn [epoch, revision] -> {epoch + 1, revision} end)
      starts = Map.put(starts, origin["authority_epoch"], origin["store_revision"])
      {:ok, {starts, Map.new(retirements, fn [epoch, revision] -> {epoch, revision} end)}}
    else
      _ -> {:error, :corrupt_native_setup}
    end
  end

  defp acceptances(_db, 21), do: {:ok, []}

  defp acceptances(db, version) when version in [22, 23, 24, 25, 26, 27, 28],
    do:
      query(
        db,
        "SELECT source_epoch,revision FROM controller_acceptances ORDER BY revision LIMIT 65"
      )

  defp acceptances(_, _), do: {:error, :corrupt_native_setup}

  defp valid_principal?(
         db,
         [principal, hash, document, status, 1, revision],
         identity,
         {starts, ends}
       ) do
    with ["native-setup-v1", number, role] <- String.split(principal, ":"),
         {epoch, ""} <- Integer.parse(number),
         true <- epoch > 0 and number == Integer.to_string(epoch),
         {:ok, permissions} <- Codec.permissions(role),
         {:ok, ^document} <- Registry.encode_permissions(permissions),
         true <- is_binary(hash) and byte_size(hash) == 32,
         {:ok, start} <- Map.fetch(starts, epoch),
         true <- is_integer(revision) and revision > start and revision <= identity.store_revision,
         true <- not Map.has_key?(ends, epoch) or revision < ends[epoch],
         true <- status in ["active", "revoked"],
         true <- irreversible_revocation?(db, principal, status),
         true <- epoch == identity.authority_epoch or status == "revoked",
         {:ok, targets} <- Access.allowed_targets(db, principal),
         true <- role == "operator" or MapSet.size(targets) == 0,
         true <- epoch == identity.authority_epoch or MapSet.size(targets) == 0 do
      true
    else
      _ -> false
    end
  end

  defp valid_principal?(_, _, _, _), do: false
  defp irreversible_revocation?(_db, _principal, "revoked"), do: true

  defp irreversible_revocation?(db, principal, "active") do
    query(
      db,
      "SELECT COUNT(*) FROM authority_journal WHERE event_type='principal_revoked' AND entity_id=?",
      [principal]
    ) == {:ok, [[0]]}
  end
end
