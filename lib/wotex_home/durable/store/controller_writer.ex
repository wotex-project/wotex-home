defmodule WotexHome.Durable.Store.ControllerWriter do
  @moduledoc "Store-owned local ownership and permanent source retirement; no physical isolation."
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, ControllerHistory, Journal, MaintenanceWriter}
  alias WotexHome.Recovery.ControllerCodec
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @columns "principal_id,authority_epoch,operation_id,input_document,receipt_document,revision"

  def bootstrap(db) do
    with {:ok, [[revision, epoch]]} <- meta(db),
         deployment = random_identity(),
         owner = random_identity(),
         {:ok, document} <-
           ControllerCodec.encode("origin", %{
             "deployment_id" => deployment,
             "owner_id" => owner,
             "authority_epoch" => epoch,
             "store_revision" => revision,
             "provenance" => "local_bootstrap"
           }),
         {:ok, []} <-
           query(db, "INSERT INTO controller_identity VALUES (1,?,?,?,'active',0)", [
             deployment,
             document,
             owner
           ]) do
      :ok
    else
      _ -> corrupt()
    end
  end

  @doc "Complete read-only head/history gate, repeated on every Store call and archive."
  def identity(db) do
    with {:ok, [[version]]} when version in [21, 22] <- query(db, "PRAGMA user_version"),
         {:ok, [[deployment, document, owner, state, head]]} <-
           query(
             db,
             "SELECT deployment_id,origin_document,owner_id,state,head_revision FROM controller_identity WHERE singleton=1"
           ),
         {:ok, [[1]]} <- query(db, "SELECT COUNT(*) FROM controller_identity"),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM principals p WHERE INSTR(p.permissions,'\"host:transfer\"')>0 AND (p.permissions!='[\"host:transfer\"]' OR EXISTS (SELECT 1 FROM principal_targets t WHERE t.principal_id=p.principal_id))"
           ),
         {:ok, origin} <- ControllerCodec.decode("origin", document),
         true <- deployment == origin["deployment_id"],
         {:ok, [[revision, epoch]]} <- meta(db),
         true <-
           is_integer(revision) and is_integer(epoch) and epoch > 0 and
             revision >= origin["store_revision"],
         {:ok, rows} <-
           query(db, "SELECT #{@columns} FROM controller_retirements ORDER BY revision LIMIT 65"),
         :ok <- complete_history(db, version, rows, origin, revision, state, head, owner, epoch),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal a LEFT JOIN controller_retirements r ON r.revision=a.revision WHERE a.event_type='controller_source_retired' AND r.revision IS NULL"
           ) do
      {:ok,
       %{
         deployment_id: deployment,
         owner_id: owner,
         authority_epoch: epoch,
         store_revision: revision,
         state: state,
         retirement_revision: head
       }}
    else
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, _} <- identity(db), do: :ok
  end

  @doc "Trusted source export reads the exact retained receipt, never caller scope."
  def source_receipt(db) do
    with {:ok, %{state: "retired", retirement_revision: revision}} <- identity(db),
         {:ok, [[document]]} <-
           query(db, "SELECT receipt_document FROM controller_retirements WHERE revision=?", [
             revision
           ]) do
      decode_receipt(document)
    else
      {:ok, %{state: "active"}} -> {:error, :source_not_retired}
      _ -> corrupt()
    end
  end

  def status(db, credential) do
    with {:ok, _} <- actor(db, credential), do: identity(db)
  end

  def operation_status(db, credential, epoch, operation) do
    with true <-
           is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807 and
             WotexHome.Id.valid?(operation),
         {:ok, principal} <- actor(db, credential),
         {:ok, _} <- identity(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM controller_retirements WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[document]] -> decode_receipt(document)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_controller_record}
      error -> error
    end
  end

  def retire(db, credential, input) do
    policy(fn ->
      with {:ok, document} <- ControllerCodec.encode("operation", input),
           {:ok, principal} <- actor(db, credential),
           {:ok, identity} <- identity(db),
           {:ok, rows} <-
             query(
               db,
               "SELECT input_document,receipt_document FROM controller_retirements WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
               [principal, input["authority_epoch"], input["operation_id"]]
             ) do
        case rows do
          [[^document, receipt]] ->
            with {:ok, result} <- decode_receipt(receipt),
                 do: {:rollback, {:unchanged, {:ok, result}}}

          [[_, _]] ->
            {:error, :controller_operation_conflict}

          [] ->
            new_retirement(db, principal, input, document, identity)

          _ ->
            corrupt()
        end
      end
    end)
  end

  defp new_retirement(db, principal, input, document, identity) do
    with :ok <- equal(identity.state, "active", :source_retired),
         :ok <- equal(identity.authority_epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- equal(identity.store_revision, input["expected_revision"], :resnapshot_required),
         false <- identity.owner_id == input["destination_owner_id"],
         {:ok, maintenance} <- MaintenanceWriter.require_active(db),
         :ok <- capacity(db),
         {:ok, revision} <- Journal.next_revision(db),
         receipt =
           Map.merge(input, %{
             "principal_id" => principal,
             "deployment_id" => identity.deployment_id,
             "source_owner_id" => identity.owner_id,
             "maintenance_revision" => maintenance,
             "revision" => revision
           }),
         {:ok, receipt_document} <- ControllerCodec.encode("retirement", receipt),
         :ok <-
           Journal.authority_event(
             db,
             revision,
             "controller_source_retired",
             "controller:" <> identity.deployment_id
           ),
         {:ok, []} <-
           query(db, "INSERT INTO controller_retirements VALUES (?,?,?,?,?,?)", [
             principal,
             input["authority_epoch"],
             input["operation_id"],
             document,
             receipt_document,
             revision
           ]),
         {:ok, []} <-
           query(
             db,
             "UPDATE controller_identity SET state='retired',head_revision=? WHERE singleton=1 AND state='active' AND head_revision=?",
             [revision, identity.retirement_revision]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- validate(db) do
      {:commit, {:ok, receipt}}
    else
      true -> {:error, :invalid_destination_owner}
      error -> error
    end
  end

  defp complete_history(db, 21, rows, origin, revision, state, head, owner, epoch) do
    if owner == origin["owner_id"] and epoch == origin["authority_epoch"],
      do: history(db, rows, origin, revision, state, head),
      else: corrupt()
  end

  defp complete_history(db, 22, rows, origin, revision, state, head, owner, epoch),
    do: ControllerHistory.validate(db, rows, origin, state, head, owner, epoch, revision)

  defp capacity(db) do
    case query(
           db,
           "SELECT (SELECT COUNT(*) FROM controller_retirements)+(SELECT COUNT(*) FROM controller_acceptances)"
         ) do
      {:ok, [[count]]} when count < 64 ->
        :ok

      {:ok, _} ->
        {:error, :controller_history_capacity}

      {:error, _} ->
        case query(db, "PRAGMA user_version") do
          {:ok, [[21]]} -> :ok
          _ -> corrupt()
        end
    end
  end

  defp history(_db, [], _origin, _revision, "active", 0), do: :ok

  defp history(
         db,
         [[principal, epoch, operation, input_document, receipt_document, revision]],
         origin,
         revision,
         "retired",
         revision
       ) do
    with {:ok, input} <- ControllerCodec.decode("operation", input_document),
         {:ok, receipt} <- ControllerCodec.decode("retirement", receipt_document),
         true <- Map.take(receipt, Map.keys(input)) == input,
         true <-
           receipt["principal_id"] == principal and receipt["authority_epoch"] == epoch and
             receipt["operation_id"] == operation,
         true <-
           epoch == origin["authority_epoch"] and receipt["revision"] == revision and
             revision > origin["store_revision"],
         true <-
           receipt["deployment_id"] == origin["deployment_id"] and
             receipt["source_owner_id"] == origin["owner_id"],
         {:ok, [["controller_source_retired", entity]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         true <- entity == "controller:" <> origin["deployment_id"],
         {:ok, [[permissions]]} <-
           query(db, "SELECT permissions FROM principals WHERE principal_id=?", [principal]),
         {:ok, permissions} <- Registry.decode_permissions(permissions),
         true <- "host:transfer" in permissions,
         {:ok, maintenance} <- MaintenanceWriter.require_active(db),
         true <- maintenance == receipt["maintenance_revision"],
         {:ok, [["begin", ^epoch]]} <-
           query(
             db,
             "SELECT action,authority_epoch FROM host_maintenance_operations WHERE revision=?",
             [maintenance]
           ) do
      :ok
    else
      _ -> corrupt()
    end
  end

  defp history(_, _, _, _, _, _), do: corrupt()

  defp decode_receipt(document) do
    case ControllerCodec.decode("retirement", document) do
      {:ok, value} -> {:ok, value}
      _ -> corrupt()
    end
  end

  defp actor(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- "host:transfer" in permissions do
      {:ok, principal}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp random_identity, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  defp equal(value, value, _), do: :ok
  defp equal(_, _, error), do: {:error, error}
  defp corrupt, do: {:error, :corrupt_controller_history}

  defp policy(fun) do
    case fun.() do
      {:error, reason}
      when reason in [
             :invalid_controller_record,
             :invalid_destination_owner,
             :controller_operation_conflict,
             :source_retired,
             :stale_authority_epoch,
             :resnapshot_required,
             :maintenance_required,
             :unauthorized,
             :permission_denied,
             :invalid_credential,
             :controller_history_capacity
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      result ->
        result
    end
  end
end
