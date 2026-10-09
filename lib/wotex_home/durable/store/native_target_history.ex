defmodule WotexHome.Durable.Store.NativeTargetHistory do
  @moduledoc "Read-only original native access correspondence on a borrowed Store connection."
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{ControllerWriter, ProfileWriter}
  alias WotexHome.NativeSetup.{Codec, TargetCodec}
  alias WotexHome.Recovery.{ControllerCodec, TransferAcceptanceCodec}
  alias WotexHome.Semantics.Capability
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @fields ~w(principal_id authority_epoch operation_id action input_document receipt_document revision)
  @columns Enum.join(@fields, ",")
  def columns, do: @columns
  def event("grant"), do: "native_target_granted"
  def event("revoke"), do: "native_target_revoked"
  def entity(principal, epoch, operation), do: "#{principal}/#{epoch}/#{operation}"

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [23, 24, 25, 26, 27, 28] -> validate(db)
      {:ok, [[version]]} when version in 1..22 -> :ok
      _ -> corrupt()
    end
  end

  def withdraw_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [23, 24, 25, 26, 27, 28] -> withdraw_invalidated(db)
      {:ok, [[version]]} when version in 1..22 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, identity} <- ControllerWriter.identity(db),
         :ok <- ProfileWriter.validate(db),
         {:ok, owners} <- ownership_windows(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM native_target_operations ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1_024,
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('native_target_granted','native_target_revoked')"
           ),
         true <- count == length(rows),
         {:ok, records} <- records(db, rows, identity, owners),
         {:ok, expected} <- expected_targets(db, records, identity.authority_epoch),
         {:ok, actual} <-
           query(
             db,
             "SELECT p.principal_id,t.thing_id FROM principal_targets t JOIN principals p USING(principal_id) WHERE p.principal_id GLOB 'native-setup-v1:*' ORDER BY p.principal_id,t.thing_id"
           ),
         true <- MapSet.new(actual) == expected,
         true <- Enum.all?(Enum.frequencies_by(actual, &hd/1), fn {_, count} -> count <= 32 end),
         do: :ok,
         else: (_ -> corrupt())
  end

  # Called only inside the owning profile transition, after its history/current
  # projection has changed. It never adds a grant or rewrites an access receipt.
  def withdraw_invalidated(db) do
    with {:ok, identity} <- ControllerWriter.identity(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM native_target_operations ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1_024,
         {:ok, decoded} <- decode_rows(rows),
         {:ok, expected} <- expected_targets(db, decoded, identity.authority_epoch),
         {:ok, actual} <-
           query(
             db,
             "SELECT principal_id,thing_id FROM principal_targets WHERE principal_id GLOB 'native-setup-v1:*' ORDER BY principal_id,thing_id"
           ) do
      Enum.reduce_while(actual, :ok, fn [principal, target] = pair, :ok ->
        if MapSet.member?(expected, pair) do
          {:cont, :ok}
        else
          case query(db, "DELETE FROM principal_targets WHERE principal_id=? AND thing_id=?", [
                 principal,
                 target
               ]) do
            {:ok, []} -> {:cont, :ok}
            _ -> {:halt, corrupt()}
          end
        end
      end)
    else
      _ -> corrupt()
    end
  end

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, decoded} ->
      case decode_row(row) do
        {:ok, record} -> {:cont, {:ok, [record | decoded]}}
        _ -> {:halt, corrupt()}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp records(db, rows, identity, owners) do
    with {:ok, decoded} <- decode_rows(rows),
         true <- Enum.all?(decoded, &valid_record?(db, &1, identity, owners)),
         :ok <- access_chain(db, decoded),
         do: {:ok, decoded},
         else: (_ -> corrupt())
  end

  defp decode_row([
         principal,
         epoch,
         operation,
         action,
         input_document,
         receipt_document,
         revision
       ]) do
    with true <- action in ["grant", "revoke"],
         {:ok, input} <- TargetCodec.decode(action, input_document),
         {:ok, receipt} <- TargetCodec.decode("receipt", receipt_document),
         {:ok, digest} <- TargetCodec.digest(action, input),
         true <-
           principal == Codec.principal(epoch, "operator") and
             {principal, epoch, operation, action, revision} ==
               {receipt["principal_id"], receipt["authority_epoch"], receipt["operation_id"],
                receipt["action"], receipt["change_revision"]} and
             Map.take(input, ~w(deployment_id owner_id authority_epoch operation_id target_id)) ==
               Map.take(
                 receipt,
                 ~w(deployment_id owner_id authority_epoch operation_id target_id)
               ) and
             receipt["expected_revision"] == input["expected_revision"] and
             receipt["input_digest"] == digest,
         do: {:ok, %{input: input, receipt: receipt}},
         else: (_ -> corrupt())
  end

  defp decode_row(_), do: corrupt()

  defp valid_record?(db, %{input: input, receipt: receipt}, identity, owners) do
    principal = receipt["principal_id"]

    with {:ok, {owner, start, finish}} <- Map.fetch(owners, input["authority_epoch"]),
         true <-
           owner == input["owner_id"] and identity.deployment_id == input["deployment_id"] and
             input["creation_revision"] > start and
             receipt["change_revision"] > input["creation_revision"] and
             receipt["final_revision"] <= identity.store_revision and
             (finish == nil or receipt["final_revision"] < finish),
         {:ok, hash} <- Base.decode16(input["verifier"], case: :lower),
         {:ok, [[^hash]]} <-
           query(db, "SELECT credential_hash FROM principals WHERE principal_id=?", [principal]),
         {:ok, [[creation]]} <-
           query(
             db,
             "SELECT revision FROM authority_journal WHERE event_type='native_principal_provisioned' AND entity_id=?",
             [principal]
           ),
         true <- creation == input["creation_revision"],
         :ok <- normal_at(db, input["expected_revision"]),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='principal_revoked' AND entity_id=? AND revision<=?",
             [principal, input["expected_revision"]]
           ),
         expected_event = event(receipt["action"]),
         expected_entity = entity(principal, input["authority_epoch"], input["operation_id"]),
         {:ok, [[^expected_event, ^expected_entity]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             receipt["change_revision"]
           ]),
         :ok <- affected_history(db, receipt),
         :ok <- grant_history(db, input, receipt["action"]),
         do: true,
         else: (_ -> false)
  end

  defp affected_history(db, receipt) do
    reason = event(receipt["action"])

    with {:ok, rows} <-
           query(
             db,
             "SELECT revision,principal_id,disposition,reason FROM request_journal WHERE revision>? AND revision<=? ORDER BY revision LIMIT 1025",
             [receipt["change_revision"], receipt["final_revision"]]
           ),
         true <- length(rows) == receipt["affected_requests"],
         true <-
           Enum.with_index(rows, receipt["change_revision"] + 1)
           |> Enum.all?(fn {[revision, principal, state, why], expected} ->
             revision == expected and principal == receipt["principal_id"] and
               ((state == "rejected" and why == reason) or
                  (state == "outcome_unknown" and why == reason <> "_after_handoff"))
           end),
         true <-
           Enum.count(rows, fn [_, _, state, _] -> state == "outcome_unknown" end) ==
             receipt["unknown_outcomes"],
         do: :ok,
         else: (_ -> corrupt())
  end

  defp normal_at(db, revision) do
    case query(
           db,
           "SELECT action FROM host_maintenance_operations WHERE revision<=? ORDER BY revision DESC LIMIT 1",
           [revision]
         ) do
      {:ok, []} -> :ok
      {:ok, [["end"]]} -> :ok
      _ -> corrupt()
    end
  end

  defp access_chain(db, records) do
    Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, latest} ->
      pair = {record.receipt["principal_id"], record.input["target_id"]}
      previous = Map.get(latest, pair)

      present =
        if previous == nil,
          do: {:ok, false},
          else: present_at(db, previous, record.input["expected_revision"])

      case {record.receipt["action"], present} do
        {"grant", {:ok, false}} -> {:cont, {:ok, Map.put(latest, pair, record)}}
        {"revoke", {:ok, true}} -> {:cont, {:ok, Map.put(latest, pair, record)}}
        _ -> {:halt, corrupt()}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      _ -> corrupt()
    end
  end

  defp present_at(_db, %{receipt: %{"action" => "revoke"}}, _), do: {:ok, false}

  defp present_at(db, %{input: input, receipt: receipt}, revision) do
    with {:ok, selections} <-
           query(
             db,
             "SELECT state,generation,resource_revision,binding_revision,artifact_digest,trust_revision FROM profile_selection_history WHERE target_id=? AND revision<=? ORDER BY revision DESC LIMIT 1",
             [input["target_id"], revision]
           ),
         {:ok, trust} <-
           query(
             db,
             "SELECT action,final_revision FROM profile_operations WHERE artifact_digest=? AND action IN ('approve','revoke') AND final_revision<=? ORDER BY final_revision DESC LIMIT 1",
             [input["artifact_digest"], revision]
           ),
         {:ok, [[withdrawals]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE revision>? AND revision<=? AND ((event_type='target_grant_revoked' AND entity_id=?) OR (event_type IN ('thing_narrowed','thing_revoked','thing_enrollment_rereviewed') AND entity_id=?))",
             [
               receipt["change_revision"],
               revision,
               receipt["principal_id"] <> "/" <> input["target_id"],
               input["target_id"]
             ]
           ) do
      case {selections, trust} do
        {[["selected", generation, resource, binding, digest, trust_revision]],
         [["approve", trust_revision]]} ->
          {:ok,
           withdrawals == 0 and
             {generation, resource, binding, digest} ==
               {input["selection_generation"], input["resource_revision"],
                input["binding_revision"], input["artifact_digest"]}}

        _ ->
          {:ok, false}
      end
    else
      _ -> corrupt()
    end
  end

  defp grant_history(_db, _input, "revoke"), do: :ok

  defp grant_history(db, input, "grant") do
    with {:ok, [["selected", generation, resource, binding, digest, trust, document, selected]]} <-
           query(
             db,
             "SELECT state,generation,resource_revision,binding_revision,artifact_digest,trust_revision,thing_document,revision FROM profile_selection_history WHERE target_id=? AND revision<=? ORDER BY revision DESC LIMIT 1",
             [input["target_id"], input["expected_revision"]]
           ),
         true <-
           {generation, resource, binding, digest} ==
             {input["selection_generation"], input["resource_revision"],
              input["binding_revision"], input["artifact_digest"]},
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE entity_id=? AND revision>? AND revision<=? AND event_type IN ('thing_narrowed','thing_revoked','thing_enrollment_rereviewed')",
             [input["target_id"], selected, input["expected_revision"]]
           ),
         {:ok, [["approve", ^trust]]} <-
           query(
             db,
             "SELECT action,final_revision FROM profile_operations WHERE artifact_digest=? AND action IN ('approve','revoke') AND final_revision<=? ORDER BY final_revision DESC LIMIT 1",
             [digest, input["expected_revision"]]
           ),
         {:ok, %{id: target, role: "Light", capabilities: %{"power" => power} = capabilities}} <-
           Registry.decode_thing(document),
         true <-
           target == input["target_id"] and map_size(capabilities) == 1 and
             Capability.supports?(power, "write"),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp expected_targets(db, records, current_epoch) do
    latest =
      Enum.reduce(records, %{}, fn record, latest ->
        Map.put(latest, [record.receipt["principal_id"], record.input["target_id"]], record)
      end)

    Enum.reduce_while(latest, {:ok, MapSet.new()}, fn {pair, record}, {:ok, expected} ->
      case current?(db, record, current_epoch) do
        {:ok, true} -> {:cont, {:ok, MapSet.put(expected, pair)}}
        {:ok, false} -> {:cont, {:ok, expected}}
        _ -> {:halt, corrupt()}
      end
    end)
  end

  defp current?(_db, %{receipt: %{"action" => "revoke"}}, _epoch), do: {:ok, false}

  defp current?(db, %{input: input, receipt: receipt}, epoch) do
    if input["authority_epoch"] != epoch do
      {:ok, false}
    else
      with {:ok, [[status]]} <-
             query(db, "SELECT status FROM principals WHERE principal_id=?", [
               receipt["principal_id"]
             ]),
           {:ok, rows} <-
             query(
               db,
               """
               SELECT 1 FROM enrolled_things t JOIN enrollment_bindings b USING(thing_id)
               JOIN profile_current c ON c.target_id=t.thing_id
               JOIN profile_selection_history h ON h.revision=c.selection_revision
               WHERE t.thing_id=? AND t.status='active' AND t.resource_revision=? AND b.revision=?
                 AND c.state='selected' AND c.generation=? AND h.artifact_digest=? AND h.trust_revision=
                 (SELECT final_revision FROM profile_operations WHERE artifact_digest=h.artifact_digest AND action IN ('approve','revoke') ORDER BY final_revision DESC LIMIT 1)
                 AND NOT EXISTS (SELECT 1 FROM authority_journal a WHERE a.event_type='target_grant_revoked' AND a.entity_id=? AND a.revision>?)
               """,
               [
                 input["target_id"],
                 input["resource_revision"],
                 input["binding_revision"],
                 input["selection_generation"],
                 input["artifact_digest"],
                 receipt["principal_id"] <> "/" <> input["target_id"],
                 receipt["change_revision"]
               ]
             ),
           do: {:ok, status == "active" and rows == [[1]]},
           else: (_ -> corrupt())
    end
  end

  defp ownership_windows(db) do
    with {:ok, [[document]]} <- query(db, "SELECT origin_document FROM controller_identity"),
         {:ok, origin} <- ControllerCodec.decode("origin", document),
         {:ok, accepted} <-
           query(
             db,
             "SELECT receipt_document FROM controller_acceptances ORDER BY revision LIMIT 65"
           ),
         {:ok, retired} <-
           query(
             db,
             "SELECT receipt_document FROM controller_retirements ORDER BY revision LIMIT 65"
           ),
         {:ok, starts} <-
           decode_windows(accepted, :accept, %{
             origin["authority_epoch"] => {origin["owner_id"], origin["store_revision"], nil}
           }),
         do: decode_windows(retired, :retire, starts),
         else: (_ -> corrupt())
  end

  defp decode_windows(rows, kind, windows) do
    Enum.reduce_while(rows, {:ok, windows}, fn [document], {:ok, windows} ->
      decoded =
        if kind == :accept,
          do: TransferAcceptanceCodec.decode("acceptance", document),
          else: ControllerCodec.decode("retirement", document)

      case {kind, decoded} do
        {:accept, {:ok, receipt}} ->
          {:cont,
           {:ok,
            Map.put(
              windows,
              receipt["authority_epoch"],
              {receipt["destination_owner_id"], receipt["revision"], nil}
            )}}

        {:retire, {:ok, receipt}} ->
          case Map.fetch(windows, receipt["authority_epoch"]) do
            {:ok, {owner, start, nil}} ->
              {:cont,
               {:ok,
                Map.put(windows, receipt["authority_epoch"], {owner, start, receipt["revision"]})}}

            _ ->
              {:halt, corrupt()}
          end

        _ ->
          {:halt, corrupt()}
      end
    end)
  end

  defp corrupt, do: {:error, :corrupt_native_target_history}
end
