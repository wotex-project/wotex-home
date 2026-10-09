defmodule WotexHome.Durable.Store.PairingWriter do
  @moduledoc "Store-owned one-use invitation/association history; borrowed connection, verifier only."
  alias WotexHome.ControllerConnections.{ConsumptionCodec, ReviewCodec}
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{ControllerWriter, MaintenanceWriter, PrincipalWriter}
  alias WotexHome.Recovery.{ControllerCodec, TransferAcceptanceCodec}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "controller_id,invitation_id,client_id,request_id,request_digest,authority_epoch,principal_id,approval_document,receipt_document,credential_hash,revision"
  @capacity 1_024

  def columns, do: @columns

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[28]]} -> validate(db)
      {:ok, [[version]]} when version in 4..27 -> :ok
      _ -> corrupt()
    end
  end

  def consumed(db, invitation) do
    with :ok <- validate(db),
         {:ok, rows} <-
           query(db, "SELECT 1 FROM controller_pairings WHERE invitation_id=?", [invitation]) do
      case rows do
        [] -> :available
        [[1]] -> :consumed
        _ -> corrupt()
      end
    end
  end

  def commit_tx(db, boot, approval, credential, hash) do
    with {:ok, document} <- ReviewCodec.encode("approval", approval),
         :ok <- validate(db),
         :available <- consumed(db, approval["invitation_id"]),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, %{state: "active"} = identity} <- ControllerWriter.identity(db),
         true <- approval["store_boot"] == boot,
         true <-
           {approval["deployment_id"], approval["owner_id"], approval["authority_epoch"]} ==
             {identity.deployment_id, identity.owner_id, identity.authority_epoch},
         :ok <-
           equal(approval["expected_revision"], identity.store_revision, :resnapshot_required),
         {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM controller_pairings"),
         true <- count < @capacity,
         {:ok, permissions} <- Registry.encode_permissions(approval["permissions"]),
         principal = ConsumptionCodec.principal(approval),
         {:commit, {:ok, ^credential, revision}} <-
           PrincipalWriter.provision_principal_tx(
             db,
             principal,
             hash,
             permissions,
             approval["target_ids"],
             credential
           ),
         receipt = %{"approval" => approval, "principal_id" => principal, "revision" => revision},
         {:ok, receipt_document} <- ConsumptionCodec.encode(receipt),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO controller_pairings VALUES (?,?,?,?,?,?,?,?,?,CAST(? AS BLOB),?)",
             [
               approval["controller_id"],
               approval["invitation_id"],
               approval["client_id"],
               approval["request_id"],
               approval["request_digest"],
               approval["authority_epoch"],
               principal,
               document,
               receipt_document,
               hash,
               revision
             ]
           ),
         :ok <- validate(db) do
      {:commit, {:ok, receipt, credential}}
    else
      :consumed ->
        {:rollback, {:policy, :invitation_consumed}}

      false ->
        {:rollback, {:policy, :pairing_unavailable}}

      {:error, :invalid_controller_pairing_review} ->
        {:rollback, {:policy, :pairing_unavailable}}

      {:error, reason} when reason in [:maintenance_active, :resnapshot_required] ->
        {:rollback, {:policy, reason}}

      {:rollback, _} = refusal ->
        refusal

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_controller_pairing}
    end
  end

  @doc "Trusted exact original status; the original and current disposition are separate."
  def status(db, lookup) do
    with true <- ConsumptionCodec.lookup?(lookup),
         :ok <- validate(db),
         {:ok, identity} <- ControllerWriter.identity(db),
         {:ok, rows} <-
           query(db, "SELECT receipt_document FROM controller_pairings WHERE invitation_id=?", [
             lookup["invitation_id"]
           ]) do
      case rows do
        [] ->
          :not_found

        [[document]] ->
          with {:ok, receipt} <- ConsumptionCodec.decode(document),
               true <- Map.take(receipt["approval"], ConsumptionCodec.original_fields()) == lookup,
               {:ok, [[status]]} <-
                 query(db, "SELECT status FROM principals WHERE principal_id=?", [
                   receipt["principal_id"]
                 ]) do
            disposition =
              if identity.state == "retired" and status == "active",
                do: "source_retired",
                else: status

            {:ok,
             %{original: receipt, status: disposition, store_revision: identity.store_revision}}
          else
            false -> {:error, :pairing_original_conflict}
            _ -> corrupt()
          end

        _ ->
          corrupt()
      end
    else
      false -> {:error, :invalid_controller_pairing_consumption}
      error -> error
    end
  end

  def revoke_tx(db, lookup, expected) do
    with {:ok, %{original: receipt, status: status} = current} <- status(db, lookup) do
      if status == "revoked" do
        {:rollback, {:unchanged, {:ok, current}}}
      else
        with true <- is_integer(expected) and expected >= 0,
             :ok <- equal(current.store_revision, expected, :resnapshot_required),
             {:commit, {:ok, _}} <-
               PrincipalWriter.revoke_principal_tx(db, receipt["principal_id"]),
             {:ok, next} <- status(db, lookup),
             do: {:commit, {:ok, next}},
             else: (
               false -> {:rollback, {:policy, :pairing_unavailable}}
               {:error, :resnapshot_required} -> {:rollback, {:policy, :resnapshot_required}}
               {:rollback, _} = refusal -> refusal
               {:error, reason} -> {:rollback, reason}
               _ -> {:rollback, :corrupt_controller_pairing}
             )
      end
    else
      :not_found ->
        {:rollback, {:policy, :pairing_unavailable}}

      {:error, reason}
      when reason in [:pairing_original_conflict, :invalid_controller_pairing_consumption] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  @doc "Complete immutable association/journal/authority audit; no current credential is returned."
  def validate(db) do
    with {:ok, identity} <- ControllerWriter.identity(db),
         {:ok, windows} <- windows(db),
         {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM controller_pairings"),
         true <- count in 0..@capacity,
         {:ok, [[^count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM principals WHERE principal_id LIKE 'paired-controller-v1:%'"
           ),
         {:ok, [[^count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='principal_provisioned' AND entity_id LIKE 'paired-controller-v1:%'"
           ),
         {:ok, rows} <-
           query(db, "SELECT #{@columns} FROM controller_pairings ORDER BY revision LIMIT 1025"),
         true <- length(rows) == count and Enum.all?(rows, &valid_row?(db, &1, identity, windows)) do
      :ok
    else
      _ -> corrupt()
    end
  end

  defp valid_row?(
         db,
         [
           controller,
           invitation,
           client,
           request,
           digest,
           epoch,
           principal,
           document,
           receipt_document,
           verifier,
           revision
         ],
         identity,
         {starts, ends}
       ) do
    with {:ok, approval} <- ReviewCodec.decode("approval", document),
         {:ok, receipt} <- ConsumptionCodec.decode(receipt_document),
         true <-
           receipt == %{
             "approval" => approval,
             "principal_id" => principal,
             "revision" => revision
           },
         true <-
           [controller, invitation, client, request, digest, epoch] ==
             Enum.map(
               ~w(controller_id invitation_id client_id request_id request_digest authority_epoch),
               &approval[&1]
             ),
         true <- is_binary(verifier) and byte_size(verifier) == 32,
         true <- approval["deployment_id"] == identity.deployment_id,
         {:ok, {owner, start}} <- Map.fetch(starts, epoch),
         true <- approval["owner_id"] == owner and approval["expected_revision"] >= start,
         true <-
           revision <= identity.store_revision and
             (not Map.has_key?(ends, epoch) or revision < ends[epoch]),
         {:ok, [["principal_provisioned", ^principal]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         {:ok, [[hash, permissions, status]]} <-
           query(
             db,
             "SELECT credential_hash,permissions,status FROM principals WHERE principal_id=?",
             [principal]
           ),
         true <- is_binary(hash) and byte_size(hash) == 32 and status in ["active", "revoked"],
         {:ok, ^permissions} <- Registry.encode_permissions(approval["permissions"]),
         {:ok, targets} <-
           query(
             db,
             "SELECT thing_id FROM principal_targets WHERE principal_id=? ORDER BY thing_id",
             [principal]
           ),
         targets = Enum.map(targets, &hd/1),
         true <-
           targets == Enum.uniq(targets) and length(targets) <= 32 and
             Enum.all?(targets, &WotexHome.Id.valid?/1),
         true <-
           Enum.all?(
             approval["target_ids"],
             &(query(db, "SELECT COUNT(*) FROM enrolled_things WHERE thing_id=?", [&1]) ==
                 {:ok, [[1]]})
           ),
         true <-
           current?(db, approval, principal, revision, verifier, hash, status, targets, identity) do
      true
    else
      _ -> false
    end
  end

  defp valid_row?(_, _, _, _), do: false

  # Existing trusted principal changes keep current grants/credentials separate
  # from the original pairing. Their journal transitions must explain a change;
  # a consumed invitation never replays the old or current credential.
  defp current?(db, approval, principal, revision, verifier, hash, status, targets, identity) do
    if approval["authority_epoch"] < identity.authority_epoch do
      status == "revoked" and targets == []
    else
      original = approval["target_ids"]
      revocations = events(db, principal, revision, "principal_revoked", principal)

      hash_ok =
        hash == verifier or
          events(db, principal, revision, "principal_credential_rotated", principal) > 0 or
          events(
            db,
            principal,
            revision,
            "target_granted_credential_rotated",
            principal <> "/",
            true
          ) > 0

      hash_ok and
        ((status == "revoked" and revocations > 0) or (status == "active" and revocations == 0)) and
        grants_current?(db, principal, revision, original, targets)
    end
  end

  # Select the last trusted transition for every target, including formerly
  # granted targets absent from both the original approval and current rows.
  defp grants_current?(db, principal, revision, original, targets) do
    prefix = principal <> "/"

    case query(
           db,
           """
           SELECT a.event_type,a.entity_id FROM authority_journal a
           JOIN (
             SELECT MAX(revision) AS latest FROM authority_journal
             WHERE revision>? AND event_type IN ('target_granted_credential_rotated','target_grant_revoked')
               AND SUBSTR(entity_id,1,?)=? GROUP BY entity_id
           ) b ON a.revision=b.latest
           """,
           [revision, byte_size(prefix), prefix]
         ) do
      {:ok, rows} ->
        Enum.reduce_while(rows, {:ok, MapSet.new(original)}, fn [event, entity], {:ok, grants} ->
          target = binary_part(entity, byte_size(prefix), byte_size(entity) - byte_size(prefix))

          if WotexHome.Id.valid?(target) do
            next =
              if event == "target_granted_credential_rotated",
                do: MapSet.put(grants, target),
                else: MapSet.delete(grants, target)

            {:cont, {:ok, next}}
          else
            {:halt, :invalid}
          end
        end)
        |> case do
          {:ok, expected} -> expected == MapSet.new(targets)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp events(db, _principal, revision, event, entity, prefix? \\ false) do
    {selector, params} =
      if prefix?,
        do: {"SUBSTR(entity_id,1,?)=?", [byte_size(entity), entity]},
        else: {"entity_id=?", [entity]}

    case query(
           db,
           "SELECT COUNT(*) FROM authority_journal WHERE revision>? AND event_type=? AND #{selector}",
           [revision, event | params]
         ) do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> -1
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
         {:ok, acceptances} <-
           query(
             db,
             "SELECT receipt_document FROM controller_acceptances ORDER BY revision LIMIT 65"
           ) do
      Enum.reduce_while(
        acceptances,
        {:ok, %{origin["authority_epoch"] => {origin["owner_id"], origin["store_revision"]}}},
        fn [document], {:ok, starts} ->
          case TransferAcceptanceCodec.decode("acceptance", document) do
            {:ok, receipt} ->
              {:cont,
               {:ok,
                Map.put(
                  starts,
                  receipt["authority_epoch"],
                  {receipt["destination_owner_id"], receipt["revision"]}
                )}}

            _ ->
              {:halt, corrupt()}
          end
        end
      )
      |> case do
        {:ok, starts} ->
          {:ok, {starts, Map.new(retirements, fn [epoch, revision] -> {epoch, revision} end)}}

        error ->
          error
      end
    else
      _ -> corrupt()
    end
  end

  defp equal(value, value, _), do: :ok
  defp equal(_, _, reason), do: {:error, reason}
  defp corrupt, do: {:error, :corrupt_controller_pairing}
end
