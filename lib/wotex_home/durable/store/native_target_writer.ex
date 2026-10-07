defmodule WotexHome.Durable.Store.NativeTargetWriter do
  @moduledoc "Original native target-access transactions on the single Store's borrowed handle."
  alias WotexHome.NativeSetup.{TargetBasis, TargetCodec}

  alias WotexHome.Durable.Store.{
    Journal,
    MaintenanceWriter,
    NativePrincipalWriter,
    NativeTargetHistory,
    OverrideWriter,
    ProfileTarget,
    RequestInvalidator
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @original ~w(deployment_id owner_id authority_epoch creation_revision verifier)
  @maximum 9_223_372_036_854_775_807
  @denials ~w(invalid_native_target_record native_owner_changed native_custody_conflict native_target_unavailable native_target_changed native_target_exists native_target_missing native_target_capacity native_operation_conflict revision_conflict maintenance_active source_retired revision_exhausted outcome_unknown)a

  def status(db, input) do
    with {:ok, _} <- TargetCodec.encode("status", input),
         {:ok, principal} <- actor(db, input),
         :ok <- NativeTargetHistory.validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM native_target_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] -> :not_found
        [[document]] -> TargetCodec.decode("receipt", document)
        _ -> corrupt()
      end
    end
  end

  def change_tx(db, action, input, guard) when action in ["grant", "revoke"] do
    result =
      with :ok <- check_guard(guard),
           {:ok, document} <- TargetCodec.encode(action, input),
           {:ok, principal} <- actor(db, input),
           :ok <- NativeTargetHistory.validate(db),
           {:ok, rows} <-
             query(
               db,
               "SELECT input_document,receipt_document FROM native_target_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
               [principal, input["authority_epoch"], input["operation_id"]]
             ) do
        case rows do
          [[^document, receipt]] ->
            case TargetCodec.decode("receipt", receipt) do
              {:ok, receipt} ->
                case check_guard(guard) do
                  :ok -> {:rollback, {:unchanged, {:ok, receipt}}}
                  error -> error
                end

              _ ->
                corrupt()
            end

          [[_, _]] ->
            {:error, :native_operation_conflict}

          [] ->
            change(db, action, input, principal, document, guard)

          _ ->
            corrupt()
        end
      end

    case result do
      {:error, reason} when reason in @denials -> {:rollback, {:policy, reason}}
      {:error, reason} -> {:rollback, reason}
      other -> other
    end
  end

  def change_tx(_db, _action, _input, _guard),
    do: {:rollback, {:policy, :invalid_native_target_record}}

  defp actor(db, input) do
    original = input |> Map.take(@original) |> Map.put("role", "operator")

    with {:ok, receipt} <- NativePrincipalWriter.existing(db, original),
         do: {:ok, receipt["principal_id"]}
  end

  defp change(db, action, input, principal, document, guard) do
    with :ok <- MaintenanceWriter.guard(db),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key='revision'"),
         :ok <- equal(revision, input["expected_revision"], :revision_conflict),
         {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM native_target_operations"),
         true <- is_integer(count) and count < 1_024,
         :ok <- desired(db, action, input, principal),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,operation_id FROM request_outbox WHERE state='held' AND principal_id=? ORDER BY authority_epoch,operation_id LIMIT 1025",
             [principal]
           ),
         {:ok, execution} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,operation_id,state FROM request_execution WHERE principal_id=? AND state IN ('queued','claimed','dispatching','protocol_accepted') ORDER BY authority_epoch,operation_id LIMIT 1025",
             [principal]
           ),
         affected = length(held) + length(execution),
         unknown =
           Enum.count(execution, fn [_, _, _, state] ->
             state in ["dispatching", "protocol_accepted"]
           end),
         true <- affected <= 1_024 and revision <= @maximum - affected - 1,
         {:ok, change} <- Journal.next_revision(db),
         :ok <- mutate_target(db, action, principal, input["target_id"]),
         :ok <- OverrideWriter.clear_override_for_principal(db, principal),
         reason = NativeTargetHistory.event(action),
         :ok <-
           Journal.authority_event(
             db,
             change,
             reason,
             NativeTargetHistory.entity(
               principal,
               input["authority_epoch"],
               input["operation_id"]
             )
           ),
         {:ok, _} <- RequestInvalidator.reject_held_batch(db, held, reason),
         {:ok, final} <-
           RequestInvalidator.invalidate_execution_for(db, {:principal, principal}, reason),
         true <- final == change + affected,
         {:ok, digest} <- TargetCodec.digest(action, input),
         receipt =
           input
           |> Map.take(
             ~w(deployment_id owner_id authority_epoch operation_id target_id expected_revision)
           )
           |> Map.merge(%{
             "principal_id" => principal,
             "action" => action,
             "input_digest" => digest,
             "change_revision" => change,
             "final_revision" => final,
             "affected_requests" => affected,
             "unknown_outcomes" => unknown
           }),
         {:ok, encoded} <- TargetCodec.encode("receipt", receipt),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO native_target_operations (#{NativeTargetHistory.columns()}) VALUES (?,?,?,?,?,?,?)",
             [
               principal,
               input["authority_epoch"],
               input["operation_id"],
               action,
               document,
               encoded,
               change
             ]
           ),
         :ok <- NativeTargetHistory.validate(db),
         :ok <- check_guard(guard),
         do: {:commit, {:ok, receipt}},
         else: (
           false -> {:error, :native_target_capacity}
           {:error, _} = error -> error
           _ -> corrupt()
         )
  end

  defp desired(db, "grant", input, principal) do
    with {:ok, snapshot} <- ProfileTarget.snapshot(db, input["target_id"]),
         :ok <- TargetBasis.validate(input, snapshot),
         {:ok, [[count]]} <-
           query(db, "SELECT COUNT(*) FROM principal_targets WHERE principal_id=?", [principal]),
         true <- is_integer(count) and count < 32,
         {:ok, rows} <-
           query(
             db,
             "SELECT thing_id FROM principal_targets WHERE principal_id=? AND thing_id=?",
             [principal, input["target_id"]]
           ) do
      case rows do
        [] -> :ok
        [[_]] -> {:error, :native_target_exists}
        _ -> corrupt()
      end
    else
      false -> {:error, :native_target_capacity}
      {:error, _} = error -> error
      _ -> corrupt()
    end
  end

  defp desired(db, "revoke", input, principal) do
    case query(db, "SELECT thing_id FROM principal_targets WHERE principal_id=? AND thing_id=?", [
           principal,
           input["target_id"]
         ]) do
      {:ok, [[_]]} -> :ok
      {:ok, []} -> {:error, :native_target_missing}
      _ -> corrupt()
    end
  end

  defp mutate_target(db, "grant", principal, target) do
    with {:ok, []} <- query(db, "INSERT INTO principal_targets VALUES (?,?)", [principal, target]),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp mutate_target(db, "revoke", principal, target) do
    with {:ok, []} <-
           query(db, "DELETE FROM principal_targets WHERE principal_id=? AND thing_id=?", [
             principal,
             target
           ]),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp equal(value, value, _), do: :ok
  defp equal(_, _, reason), do: {:error, reason}
  defp corrupt, do: {:error, :corrupt_native_target_history}

  def check_guard(guard) when is_function(guard, 0) do
    if guard.() == :ok, do: :ok, else: {:error, :outcome_unknown}
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  def check_guard(_), do: {:error, :outcome_unknown}
end
