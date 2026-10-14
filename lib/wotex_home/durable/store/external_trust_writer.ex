defmodule WotexHome.Durable.Store.ExternalTrustWriter do
  @moduledoc "Stateless exact external closure approvals, revocations and historical correspondence."
  alias WotexHome.Durable.Store.{
    Access,
    AuthoringObjects,
    ExternalInspections,
    Journal,
    MaintenanceWriter,
    ProfileWriter
  }

  alias WotexHome.Profiles.{ExternalArtifact, ExternalInspection, ExternalTrust}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @maximum 9_223_372_036_854_775_807
  @columns "principal_id,authority_epoch,operation_id,input_document,outcome_document,receipt_document,revision"
  @artifacts "artifact_digest,id,version,inspection_principal,inspection_epoch,inspection_operation,artifact_document,first_approval_revision"
  @policy ~w(unauthorized invalid_credential permission_denied external_trust_conflict stale_authority_epoch resnapshot_required maintenance_required external_trust_changed external_policy_changed external_already_approved external_already_revoked stale_external_reference external_trust_capacity external_artifact_mismatch external_label_conflict revision_exhausted invalid_external_trust)a
  def columns, do: @columns
  def artifact_columns, do: @artifacts

  def prepare(db, credential, document) do
    with {:ok, input} <- ExternalTrust.decode(document),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_external_trust_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[^document, r]] ->
          with {:ok, receipt} <- ExternalTrust.decode_receipt(r), do: {:ok, :existing, receipt}

        [_] ->
          {:error, :external_trust_conflict}

        _ ->
          corrupt()
      end
    end
  end

  def current_basis(db, principal, input) do
    with {:ok, [[revision, epoch, policy]]} <- meta(db),
         :ok <- same(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- same(revision, input["expected_revision"], :resnapshot_required),
         :ok <- same(policy, input["expected_policy_generation"], :external_policy_changed),
         {:ok, _} <- MaintenanceWriter.require_active(db),
         {:ok, previous} <- cursor(db, input["artifact_digest"]),
         :ok <- same(previous.revision, input["expected_trust_revision"], :external_trust_changed),
         :ok <- desired(input["action"], previous.action),
         true <- previous.generation < @maximum and policy < @maximum,
         {:ok, document} <- ExternalTrust.encode(input),
         :ok <- capacity(db, byte_size(document), 0),
         :ok <- artifact_capacity(db, input),
         {:ok, context} <- inspection_context(db, principal, input),
         do: {:ok, Map.merge(context, %{previous: previous, policy: policy})},
         else: (
           false -> {:error, :revision_exhausted}
           error -> error
         )
  end

  defp inspection_context(_, _, %{"action" => "revoke"}), do: {:ok, %{}}

  defp inspection_context(db, principal, input) do
    with {:ok, original} <-
           ExternalInspections.retained_original(db, principal, input["inspection_ref"]),
         true <- original.receipt["revision"] <= input["expected_revision"],
         {:ok, records} <- ExternalInspections.owned_records(db, principal, original.input),
         do: {:ok, Map.put(original, :objects, records)},
         else: (
           false -> {:error, :stale_external_reference}
           error -> error
         )
  end

  def retain_tx(db, credential, document, outcome_document) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, context} <- current_basis(db, principal, input),
         {:ok, outcome} <- ExternalTrust.decode_outcome(outcome_document),
         :ok <- correspondence(input, outcome, context),
         :ok <- capacity(db, byte_size(document), byte_size(outcome_document)),
         {:ok, next} <- Journal.next_revision(db),
         :ok <-
           Journal.authority_event(db, next, event(input["action"]), input["artifact_digest"]),
         {:ok, first} <- retain_artifact(db, principal, input, outcome, next),
         receipt =
           receipt(
             input,
             outcome,
             document,
             outcome_document,
             next,
             first,
             context.previous.generation + 1,
             context.policy + 1
           ),
         {:ok, receipt_document} <- ExternalTrust.encode_receipt(receipt),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_external_trust_operations (#{@columns}) VALUES (?,?,?,?,?,?,?)",
             [
               principal,
               input["authority_epoch"],
               input["operation_id"],
               document,
               outcome_document,
               receipt_document,
               next
             ]
           ),
         {:ok, []} <-
           query(db, "UPDATE meta SET value=? WHERE key='external_profile_policy_generation'", [
             context.policy + 1
           ]),
         :ok <- WotexHome.Durable.Store.ExternalTargets.withdraw_if_current(db, next),
         :ok <- validate(db),
         do: {:commit, {:ok, receipt}},
         else: (
           {:ok, :existing, r} -> {:rollback, {:unchanged, {:ok, r}}}
           {:error, r} when r in @policy -> {:rollback, {:policy, r}}
           :not_found -> {:rollback, {:policy, :stale_external_reference}}
           {:error, r} -> {:rollback, r}
           _ -> {:rollback, :corrupt_external_trust}
         )
  end

  def status(db, credential, epoch, operation) do
    with true <- is_integer(epoch) and epoch in 1..@maximum and WotexHome.Id.valid?(operation),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_external_trust_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[r]] -> ExternalTrust.decode_receipt(r)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_external_trust}
      error -> error
    end
  end

  def catalogue(db, credential) do
    with {:ok, _} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, [[revision, epoch, policy]]} <- meta(db),
         {:ok, artifacts} <-
           query(
             db,
             "SELECT artifact_digest,id,version FROM profile_external_artifacts ORDER BY id,version"
           ),
         {:ok, operations} <-
           query(
             db,
             "SELECT principal_id,receipt_document FROM profile_external_trust_operations ORDER BY revision"
           ),
         latest =
           Enum.reduce(operations, %{}, fn [p, d], acc ->
             {:ok, r} = ExternalTrust.decode_receipt(d)
             Map.put(acc, r["artifact_digest"], {p, r})
           end) do
      items =
        Enum.map(artifacts, fn [digest, id, version] ->
          {principal, r} = latest[digest]

          active =
            case Access.active_principal_permissions(db, principal) do
              {:ok, permissions} -> "profile:manage" in permissions
              _ -> false
            end

          state =
            cond do
              r["action"] == "revoke" -> "revoked"
              active -> "approved"
              true -> "author_unavailable"
            end

          %{
            "artifact_digest" => digest,
            "id" => id,
            "version" => version,
            "trust_revision" => r["revision"],
            "trust_generation" => r["trust_generation"],
            "trust_author" => principal,
            "state" => state,
            "reader_basis_sha256" => r["reader_basis_sha256"]
          }
        end)

      {:ok,
       %{
         "authority_epoch" => epoch,
         "store_revision" => revision,
         "policy_generation" => policy,
         "items" => items
       }}
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [33, 34, 35] -> validate(db)
      {:ok, [[v]]} when v in 4..32 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- ExternalInspections.validate(db),
         {:ok, [[maximum, epoch, policy]]} <- meta(db),
         true <- is_integer(policy) and policy in 0..1024,
         {:ok, artifacts} <- artifacts(db),
         {:ok, inspections} <- inspections(db),
         {:ok, objects} <- objects(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_external_trust_operations ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1024,
         {:ok, links} <-
           query(
             db,
             "SELECT o.revision,j.event_type,j.entity_id,p.principal_id FROM profile_external_trust_operations o LEFT JOIN authority_journal j ON j.revision=o.revision LEFT JOIN principals p ON p.principal_id=o.principal_id ORDER BY o.revision LIMIT 1025"
           ),
         true <- length(links) == length(rows),
         links = Map.new(links, fn [r, e, d, p] -> {r, {e, d, p}} end),
         {:ok, history, ^policy} <-
           validate_rows(rows, links, artifacts, inspections, objects, maximum, epoch),
         true <- map_size(history) == map_size(artifacts),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('external_profile_approved','external_profile_revoked')"
           ),
         true <- count == length(rows),
         :ok <- capacity(db, 0, 0, false),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp artifacts(db) do
    with {:ok, rows} <- query(db, "SELECT #{@artifacts} FROM profile_external_artifacts LIMIT 65"),
         true <- length(rows) <= 64 do
      Enum.reduce_while(rows, {:ok, %{}}, fn [digest, id, version, p, epoch, op, document, first],
                                             {:ok, acc} ->
        with {:ok, data} <- ExternalArtifact.decode(document),
             {:ok, ^digest} <- ExternalArtifact.identity(data),
             true <- data["id"] == id and data["version"] == version,
             do:
               {:cont,
                {:ok,
                 Map.put(acc, digest, %{
                   document: document,
                   data: data,
                   principal: p,
                   epoch: epoch,
                   operation: op,
                   first: first
                 })}},
             else: (_ -> {:halt, corrupt()})
      end)
    else
      _ -> corrupt()
    end
  end

  defp inspections(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,operation_id,input_document,result_document,receipt_document FROM profile_external_inspections LIMIT 1025"
           ) do
      Enum.reduce_while(rows, {:ok, %{}}, fn [p, epoch, op, i, r, s], {:ok, acc} ->
        with {:ok, input} <- ExternalInspection.decode(i),
             {:ok, receipt} <- ExternalInspection.decode_receipt(s),
             do:
               {:cont,
                {:ok,
                 Map.put(acc, {p, epoch, op}, %{
                   input: input,
                   result_document: r,
                   receipt: receipt
                 })}},
             else: (_ -> {:halt, corrupt()})
      end)
    end
  end

  defp objects(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{AuthoringObjects.object_columns()} FROM profile_authoring_objects LIMIT 1025"
           ),
         do:
           {:ok,
            Map.new(rows, fn [p, d, k, h, bytes, _] ->
              {{p, d},
               %{
                 "kind" => k,
                 "object_digest" => d,
                 "payload_sha256" => h,
                 "payload_bytes" => bytes
               }}
            end)}
  end

  defp validate_rows(rows, links, artifacts, inspections, objects, maximum, epoch) do
    Enum.reduce_while(rows, {:ok, %{}, 0}, fn [
                                                p,
                                                original_epoch,
                                                op,
                                                input_doc,
                                                outcome_doc,
                                                receipt_doc,
                                                revision
                                              ],
                                              {:ok, history, policy} ->
      with {:ok, i} <- ExternalTrust.decode(input_doc),
           {:ok, o} <- ExternalTrust.decode_outcome(outcome_doc),
           {:ok, r} <- ExternalTrust.decode_receipt(receipt_doc),
           true <-
             original_epoch in 1..epoch and revision in 1..maximum and
               i["authority_epoch"] == original_epoch and i["operation_id"] == op and
               i["expected_revision"] == revision - 1,
           true <- links[revision] == {event(i["action"]), i["artifact_digest"], p},
           artifact when is_map(artifact) <- artifacts[i["artifact_digest"]],
           previous =
             Map.get(history, i["artifact_digest"], %{revision: 0, generation: 0, action: nil}),
           :ok <- desired(i["action"], previous.action),
           true <-
             i["expected_trust_revision"] == previous.revision and
               i["expected_policy_generation"] == policy,
           true <- i["action"] == o["action"] and i["artifact_digest"] == o["artifact_digest"],
           :ok <- history_outcome(p, i, o, artifact, inspections, objects, revision, previous),
           true <-
             r ==
               receipt(
                 i,
                 o,
                 input_doc,
                 outcome_doc,
                 revision,
                 artifact.first,
                 previous.generation + 1,
                 policy + 1
               ),
           do:
             {:cont,
              {:ok,
               Map.put(history, i["artifact_digest"], %{
                 revision: revision,
                 generation: previous.generation + 1,
                 action: i["action"]
               }), policy + 1}},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp history_outcome(_, %{"action" => "revoke"}, _, _, _, _, _, _), do: :ok

  defp history_outcome(p, i, o, artifact, inspections, objects, revision, previous) do
    ref = i["inspection_ref"]

    with true <- o["inspection_ref"] == ref and o["artifact_document"] == artifact.document,
         original when is_map(original) <-
           inspections[{p, ref["authority_epoch"], ref["operation_id"]}],
         true <-
           Enum.all?(
             ~w(authority_epoch operation_id revision input_sha256 result_sha256),
             &(original.receipt[&1] == ref[&1])
           ),
         true <-
           original.receipt["revision"] <= i["expected_revision"] and
             original.result_document == o["inspection_document"],
         :ok <- manifest_matches(artifact.data, original.input, objects, p),
         true <-
           previous.revision != 0 or
             (artifact.first == revision and artifact.principal == p and
                artifact.epoch == ref["authority_epoch"] and
                artifact.operation == ref["operation_id"]),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp manifest_matches(data, input, objects, principal) do
    i = input["inspection"]

    requested =
      [{i["envelope_ref"], nil}, {i["profile"]["object_ref"], i["profile"]["reference"]}] ++
        Enum.map(i["definitions"], &{&1["object_ref"], &1["reference"]})

    expected =
      Enum.map(requested, fn {h, ref} ->
        case objects[{principal, h["object_digest"]}] do
          nil -> nil
          object -> Map.put(object, "reference", ref)
        end
      end)

    if data["objects"] == expected, do: :ok, else: corrupt()
  end

  defp correspondence(input, outcome, context) do
    valid =
      input["action"] == outcome["action"] and
        input["artifact_digest"] == outcome["artifact_digest"] and
        (input["action"] == "revoke" or
           (input["inspection_ref"] == outcome["inspection_ref"] and
              context.result_document == outcome["inspection_document"]))

    if valid, do: :ok, else: {:error, :external_artifact_mismatch}
  end

  defp retain_artifact(db, principal, input, outcome, next) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT artifact_document,first_approval_revision FROM profile_external_artifacts WHERE artifact_digest=?",
             [input["artifact_digest"]]
           ) do
      case rows do
        [[document, first]] ->
          if input["action"] == "revoke" or document == outcome["artifact_document"],
            do: {:ok, first},
            else: {:error, :external_artifact_mismatch}

        [] ->
          with "approve" <- input["action"],
               {:ok, artifact} <- ExternalArtifact.decode(outcome["artifact_document"]),
               {:ok, []} <-
                 query(
                   db,
                   "SELECT artifact_digest FROM profile_external_artifacts WHERE id=? AND version=?",
                   [artifact["id"], artifact["version"]]
                 ),
               ref = input["inspection_ref"],
               {:ok, []} <-
                 query(
                   db,
                   "INSERT INTO profile_external_artifacts (#{@artifacts}) VALUES (?,?,?,?,?,?,?,?)",
                   [
                     input["artifact_digest"],
                     artifact["id"],
                     artifact["version"],
                     principal,
                     ref["authority_epoch"],
                     ref["operation_id"],
                     outcome["artifact_document"],
                     next
                   ]
                 ),
               do: {:ok, next},
               else: (
                 {:ok, [_ | _]} -> {:error, :external_label_conflict}
                 {:error, reason} -> {:error, reason}
                 _ -> {:error, :external_artifact_mismatch}
               )

        _ ->
          corrupt()
      end
    end
  end

  defp cursor(db, digest) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_external_trust_operations ORDER BY revision DESC LIMIT 1025"
           ) do
      Enum.reduce_while(rows, {:ok, %{revision: 0, generation: 0, action: nil}}, fn [document],
                                                                                    _ ->
        case ExternalTrust.decode_receipt(document) do
          {:ok, r} ->
            if r["artifact_digest"] == digest,
              do:
                {:halt,
                 {:ok,
                  %{
                    revision: r["revision"],
                    generation: r["trust_generation"],
                    action: r["action"]
                  }}},
              else: {:cont, {:ok, %{revision: 0, generation: 0, action: nil}}}

          _ ->
            {:halt, corrupt()}
        end
      end)
    end
  end

  defp desired("approve", "approve"), do: {:error, :external_already_approved}
  defp desired("revoke", "revoke"), do: {:error, :external_already_revoked}
  defp desired("revoke", nil), do: :not_found
  defp desired(_, _), do: :ok

  defp artifact_capacity(db, input) do
    with {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM profile_external_artifacts"),
         {:ok, existing} <-
           query(
             db,
             "SELECT artifact_digest FROM profile_external_artifacts WHERE artifact_digest=?",
             [input["artifact_digest"]]
           ),
         true <- count + if(existing == [] and input["action"] == "approve", do: 1, else: 0) <= 64,
         do: :ok,
         else: (_ -> {:error, :external_trust_capacity})
  end

  defp capacity(db, input, outcome, new? \\ true) do
    with {:ok, [[count, inputs, outcomes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(outcome_document AS BLOB))),0) FROM profile_external_trust_operations"
           ),
         true <-
           count + if(new?, do: 1, else: 0) <= 1024 and inputs + input <= 4_194_304 and
             outcomes + outcome <= 4_194_304,
         do: :ok,
         else: (_ -> {:error, :external_trust_capacity})
  end

  defp receipt(input, outcome, document, outcome_document, revision, first, generation, policy) do
    basis =
      if outcome["action"] == "approve" do
        {:ok, i} = ExternalInspection.decode_result(outcome["inspection_document"])
        i["reader_basis_sha256"]
      end

    %{
      "authority_epoch" => input["authority_epoch"],
      "operation_id" => input["operation_id"],
      "revision" => revision,
      "input_sha256" => sha(document),
      "action" => input["action"],
      "artifact_digest" => input["artifact_digest"],
      "previous_trust_revision" => input["expected_trust_revision"],
      "trust_generation" => generation,
      "policy_generation" => policy,
      "artifact_first_approval_revision" => first,
      "reader_basis_sha256" => basis,
      "outcome_sha256" => sha(outcome_document)
    }
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='external_profile_policy_generation')"
      )

  defp same(v, v, _), do: :ok
  defp same(_, _, error), do: {:error, error}
  defp event("approve"), do: "external_profile_approved"
  defp event("revoke"), do: "external_profile_revoked"
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp corrupt, do: {:error, :corrupt_external_trust}
end
