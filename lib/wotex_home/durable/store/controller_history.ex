defmodule WotexHome.Durable.Store.ControllerHistory do
  @moduledoc "Read-only alternating schema 22 ownership history; borrowed Store handle only."
  alias WotexHome.Durable.Store.MaintenanceWriter
  alias WotexHome.Recovery.{ControllerCodec, TransferAcceptanceRecord}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "principal_id,source_epoch,operation_id,input_document,receipt_document,review_document,isolation_package,isolation_document,issuer_policy_document,domain_document,revision"

  def acceptance_columns, do: @columns

  def validate(db, retirements, origin, state, head, owner, epoch, revision) do
    with {:ok, acceptances} <-
           query(db, "SELECT #{@columns} FROM controller_acceptances ORDER BY revision LIMIT 65"),
         true <- length(retirements) + length(acceptances) <= 64,
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal a LEFT JOIN controller_acceptances c ON c.revision=a.revision WHERE a.event_type='controller_destination_accepted' AND c.revision IS NULL"
           ),
         transitions =
           Enum.map(retirements, &{:retire, &1}) ++ Enum.map(acceptances, &{:accept, &1}),
         transitions = Enum.sort_by(transitions, fn {_, row} -> List.last(row) end),
         initial = %{
           state: "active",
           head: 0,
           owner: origin["owner_id"],
           epoch: origin["authority_epoch"],
           revision: origin["store_revision"],
           retirement: nil
         },
         {:ok, final} <-
           Enum.reduce_while(transitions, {:ok, initial}, fn {kind, row}, {:ok, current} ->
             case transition(db, kind, row, origin["deployment_id"], current) do
               {:ok, next} -> {:cont, {:ok, next}}
               _ -> {:halt, corrupt()}
             end
           end),
         true <-
           {final.state, final.head, final.owner, final.epoch} == {state, head, owner, epoch} and
             final.revision <= revision,
         :ok <- current_barrier(db, final, revision) do
      :ok
    else
      _ -> corrupt()
    end
  end

  defp transition(
         db,
         :retire,
         [principal, epoch, operation, input_document, receipt_document, revision],
         deployment,
         %{state: "active"} = current
       ) do
    with {:ok, input} <- ControllerCodec.decode("operation", input_document),
         {:ok, receipt} <- ControllerCodec.decode("retirement", receipt_document),
         true <-
           Map.take(receipt, Map.keys(input)) == input and
             {principal, epoch, operation, revision} ==
               {receipt["principal_id"], receipt["authority_epoch"], receipt["operation_id"],
                receipt["revision"]},
         true <-
           {epoch, receipt["deployment_id"], receipt["source_owner_id"]} ==
             {current.epoch, deployment, current.owner} and
             receipt["expected_revision"] >= current.revision,
         true <-
           receipt["maintenance_revision"] >= current.head and receipt["maintenance_revision"] > 0,
         {:ok, [["[\"host:transfer\"]"]]} <-
           query(db, "SELECT permissions FROM principals WHERE principal_id=?", [principal]),
         :ok <- event(db, revision, "controller_source_retired", "controller:" <> deployment),
         {:ok, [[action, ^epoch]]} <-
           query(
             db,
             "SELECT action,authority_epoch FROM host_maintenance_operations WHERE revision=?",
             [receipt["maintenance_revision"]]
           ),
         true <- action in ["begin", "transfer"] do
      {:ok,
       %{current | state: "retired", head: revision, revision: revision, retirement: receipt}}
    else
      _ -> corrupt()
    end
  end

  defp transition(
         db,
         :accept,
         row,
         deployment,
         %{state: "retired", retirement: retired} = current
       ) do
    with {:ok, record} <- TransferAcceptanceRecord.audit(row),
         receipt = record.receipt,
         true <-
           receipt["deployment_id"] == deployment and
             receipt["source_owner_id"] == current.owner and
             receipt["source_epoch"] == current.epoch and
             receipt["retirement_revision"] == current.head and
             receipt["destination_owner_id"] == retired["destination_owner_id"] and
             receipt["source_maintenance_revision"] == retired["maintenance_revision"],
         {:ok, [[source_generation]]} <-
           query(db, "SELECT rule_generation FROM host_maintenance_operations WHERE revision=?", [
             retired["maintenance_revision"]
           ]),
         true <- source_generation == receipt["source_rule_generation"],
         :ok <-
           event(
             db,
             receipt["revision"],
             "controller_destination_accepted",
             "controller:" <> deployment
           ),
         :ok <- event(db, receipt["fence_revision"], "rule_generation_fenced", "rules:empty"),
         :ok <-
           event(
             db,
             receipt["principal_revision"],
             "principal_provisioned",
             receipt["principal_id"]
           ),
         :ok <- principal(db, record),
         {:ok,
          [
            [
              principal,
              epoch,
              operation,
              "transfer",
              expected,
              predecessor,
              final,
              fence,
              generation,
              0,
              0
            ]
          ]} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,operation_id,action,expected_revision,begin_revision,revision,fence_revision,rule_generation,affected_requests,unknown_outcomes FROM host_maintenance_operations WHERE revision=?",
             [receipt["revision"]]
           ),
         true <-
           [principal, epoch, operation, expected, predecessor, final, fence, generation] ==
             Enum.map(
               ~w(principal_id authority_epoch operation_id retirement_revision source_maintenance_revision revision fence_revision rule_generation),
               &receipt[&1]
             ) do
      {:ok,
       %{
         current
         | state: "active",
           owner: receipt["destination_owner_id"],
           epoch: receipt["authority_epoch"],
           head: receipt["revision"],
           revision: receipt["revision"],
           retirement: nil
       }}
    else
      _ -> corrupt()
    end
  end

  defp transition(_, _, _, _, _), do: corrupt()

  defp principal(db, %{receipt: receipt, review: review}) do
    with {:ok, [[hash, permissions]]} <-
           query(db, "SELECT credential_hash,permissions FROM principals WHERE principal_id=?", [
             receipt["principal_id"]
           ]),
         true <- permissions == review["permissions_document"],
         true <- is_binary(hash) and byte_size(hash) == 32,
         {:ok, [[rotations]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE revision>? AND event_type='principal_credential_rotated' AND entity_id=?",
             [receipt["principal_revision"], receipt["principal_id"]]
           ),
         true <- rotations > 0 or Base.encode16(hash, case: :lower) == review["credential_hash"] do
      :ok
    else
      _ -> corrupt()
    end
  end

  defp current_barrier(db, %{state: "retired", revision: revision, retirement: receipt}, revision) do
    with {:ok, active} <- MaintenanceWriter.require_active(db),
         true <- active == receipt["maintenance_revision"],
         do: :ok,
         else: (_ -> corrupt())
  end

  defp current_barrier(_db, %{state: "active"}, _), do: :ok
  defp current_barrier(_, _, _), do: corrupt()

  defp event(db, revision, type, entity) do
    case query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
           revision
         ]) do
      {:ok, [[^type, ^entity]]} -> :ok
      _ -> corrupt()
    end
  end

  defp corrupt, do: {:error, :corrupt_controller_history}
end
