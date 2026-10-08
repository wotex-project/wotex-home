defmodule WotexHome.Durable.Store.ProfileSelectionHistory do
  @moduledoc "Retained selection chains and original review links, without current byte authority."
  alias WotexHome.Durable.Registry
  alias WotexHome.Profiles.{LedgerCodec, Operation, Review}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @fields ~w(target_id generation principal_id authority_epoch operation_id previous_selection_revision previous_resource_revision previous_binding_revision artifact_digest projection_digest trust_revision state resource_revision binding_revision runtime_digest review_document thing_document revision)
  @columns Enum.join(@fields, ",")
  @copied ~w(artifact_digest projection_digest trust_revision binding_revision runtime_digest thing_document)

  def fields, do: @fields

  # The caller first validates canonical artifact/operation rows and the trust
  # timeline. This read-only domain adds both directions of selection ownership.
  def validate(db, artifacts, operations, revision, epoch) do
    with {:ok, values} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_selection_history ORDER BY revision LIMIT 2049"
           ),
         true <- length(values) <= 2_048,
         :ok <- history_dependencies(db, values),
         rows = Enum.map(values, &Map.new(Enum.zip(@fields, &1))),
         grouped = Enum.group_by(rows, & &1["target_id"]),
         true <- map_size(grouped) <= 64,
         true <-
           Enum.all?(grouped, fn {target, chain} ->
             valid_chain?(db, target, chain, artifacts, operations, revision, epoch)
           end),
         {:ok, [[event_count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('thing_profile_selected','thing_profile_selection_revoked')"
           ),
         true <- event_count == length(rows),
         {:ok, current} <-
           query(
             db,
             "SELECT target_id,generation,selection_revision,state FROM profile_current ORDER BY target_id LIMIT 65"
           ),
         true <- length(current) == map_size(grouped),
         true <- Enum.all?(current, fn values -> current_pointer?(values, grouped) end),
         true <-
           Enum.all?(operations, fn {_scope, parent} ->
             owned = Enum.filter(rows, &same_parent?(&1, parent))
             parent["changed_targets"] == length(owned) and parent_receipt?(db, parent, owned)
           end) do
      :ok
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp history_dependencies(_, []), do: :ok

  defp history_dependencies(db, _) do
    with :ok <- WotexHome.Durable.Store.EnrollmentSuccession.validate(db),
         :ok <- WotexHome.Durable.Store.MaintenanceWriter.validate(db),
         do: :ok
  end

  defp valid_chain?(db, target, chain, artifacts, operations, revision, epoch) do
    result =
      Enum.reduce_while(chain, {:ok, nil}, fn row, {:ok, previous} ->
        parent = operations[{row["principal_id"], row["authority_epoch"], row["operation_id"]}]

        with {:ok, _} <- LedgerCodec.encode("selection", row),
             true <- row["revision"] <= revision and row["authority_epoch"] <= epoch,
             %{} <- parent,
             true <-
               row["revision"] > parent["expected_revision"] and
                 row["revision"] <= parent["final_revision"],
             true <- parent["artifact_digest"] == row["artifact_digest"],
             %{} = artifact <- artifacts[row["artifact_digest"]],
             true <- artifact["projection_digest"] == row["projection_digest"],
             :ok <- chain_step(row, previous),
             {:ok, [[event, ^target]]} <-
               query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
                 row["revision"]
               ]),
             true <- event == selection_event(row["state"]),
             :ok <- row_links(db, row, previous, parent, artifact) do
          {:cont, {:ok, row}}
        else
          _ -> {:halt, :error}
        end
      end)

    with {:ok, head} <- result,
         :ok <- head_links(db, head),
         :ok <- enrollment_chain(db, chain),
         true <- revoked_before_reuse?(db, chain, operations) do
      true
    else
      _ -> false
    end
  end

  # Artifact revocation must retain every then-selected target barrier. A later
  # approval or selection cannot conceal an omitted revocation generation.
  defp revoked_before_reuse?(db, chain, operations) do
    Enum.with_index(chain)
    |> Enum.all?(fn {row, index} ->
      if row["state"] == "selected" do
        case query(
               db,
               "SELECT principal_id,authority_epoch,operation_id,expected_revision FROM profile_operations WHERE action='revoke' AND artifact_digest=? AND final_revision>? ORDER BY final_revision LIMIT 1",
               [row["artifact_digest"], row["revision"]]
             ) do
          {:ok, []} ->
            true

          {:ok, [[principal, epoch, operation, expected]]} ->
            case Enum.at(chain, index + 1) do
              %{} = next ->
                parent =
                  operations[
                    {next["principal_id"], next["authority_epoch"], next["operation_id"]}
                  ]

                parent["final_revision"] <= expected or
                  (next["state"] == "revoked" and
                     {next["principal_id"], next["authority_epoch"], next["operation_id"]} ==
                       {principal, epoch, operation})

              _ ->
                false
            end

          _ ->
            false
        end
      else
        true
      end
    end)
  end

  defp chain_step(
         %{"generation" => 1, "previous_selection_revision" => 0, "state" => "selected"},
         nil
       ),
       do: :ok

  defp chain_step(row, previous) when is_map(previous) do
    if row["generation"] == previous["generation"] + 1 and
         row["previous_selection_revision"] == previous["revision"] and
         row["previous_resource_revision"] == previous["resource_revision"] and
         row["previous_binding_revision"] == previous["binding_revision"], do: :ok, else: :error
  end

  defp chain_step(_, _), do: :error

  defp row_links(
         db,
         %{"state" => "selected"} = row,
         previous,
         %{"action" => "select"} = parent,
         artifact
       ) do
    with {:ok, history} <- Review.decode_history(row["review_document"], artifact),
         {:ok, input} <- Operation.decode(parent["input_document"]),
         true <- history.input == input,
         basis = history.basis,
         true <-
           Enum.all?(~w(principal_id authority_epoch operation_id), fn key ->
             if key == "operation_id", do: input[key] == row[key], else: basis[key] == row[key]
           end),
         true <-
           basis["store_revision"] == parent["expected_revision"] and
             basis["profile_policy_generation"] == parent["policy_generation"],
         true <-
           basis["trust_generation"] == parent["trust_generation"] and
             basis["trust_revision"] == parent["previous_trust_revision"],
         true <-
           row["trust_revision"] == basis["trust_revision"] and
             row["target_id"] == basis["target_id"],
         true <-
           row["previous_selection_revision"] == basis["selection_revision"] and
             row["generation"] == basis["selection_generation"] + 1,
         true <-
           row["previous_resource_revision"] == basis["resource_revision"] and
             row["previous_binding_revision"] == basis["binding_revision"],
         true <-
           row["runtime_digest"] == history.runtime_digest and
             row["thing_document"] == history.thing_document,
         true <- is_nil(previous) or previous["thing_document"] == basis["current_thing_document"],
         true <-
           row["binding_revision"] > parent["expected_revision"] and
             row["binding_revision"] < row["revision"],
         :ok <- original_review(db, row, history),
         :ok <- previous_review(db, row, history),
         :ok <- maintenance_link(db, basis["maintenance_revision"], parent["expected_revision"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp row_links(
         _db,
         %{"state" => "revoked"} = row,
         %{"state" => "selected"} = previous,
         parent,
         _artifact
       ) do
    with true <- parent["action"] in ["revoke", "revoke_selection"],
         true <- Enum.all?(@copied, &(row[&1] == previous[&1])),
         true <- row["review_document"] == "",
         {:ok, input} <- Operation.decode(parent["input_document"]),
         true <-
           parent["action"] == "revoke" or
             (input["target_id"] == row["target_id"] and
                input["expected_resource_revision"] == row["previous_resource_revision"] and
                input["expected_selection_generation"] == row["generation"] - 1) do
      :ok
    else
      _ -> :error
    end
  end

  defp row_links(_, _, _, _, _), do: :error

  defp original_review(db, row, history) do
    basis = history.basis
    captured = history.captured_identity

    expected_event =
      if history.mode == :initial,
        do: "thing_enrolled_reviewed",
        else: "thing_enrollment_rereviewed"

    with {:ok,
          [
            [
              stable,
              identity,
              candidate,
              review,
              "legacy_tofu",
              qualification,
              actor,
              profile,
              manufacturer,
              model,
              firmware,
              2,
              event,
              target
            ]
          ]} <-
           query(
             db,
             "SELECT h.stable_id,h.identity_digest,h.candidate_ref,h.review_ref,h.method,h.qualification_ref,h.operator_id,h.profile_ref,h.manufacturer,h.model,h.firmware,h.digest_version,a.event_type,a.entity_id FROM enrollment_review_history h LEFT JOIN authority_journal a ON a.revision=h.revision WHERE h.revision=? AND h.thing_id=?",
             [row["binding_revision"], row["target_id"]]
           ),
         true <-
           {stable, identity, candidate, review, qualification, actor, profile, manufacturer,
            model, firmware, event, target} ==
             {captured["stable_id"], history.identity_digest, history.input["candidate_ref"],
              history.input["review_ref"], history.thing.capabilities["power"].evidence_ref,
              basis["principal_id"], basis["profile_ref"], captured["manufacturer"],
              captured["model"], captured["firmware"], expected_event, row["target_id"]} do
      :ok
    else
      _ -> :error
    end
  end

  defp previous_review(db, row, %{mode: :initial}) do
    with true <-
           row["previous_binding_revision"] == 0 and row["previous_resource_revision"] == 0 and
             row["previous_selection_revision"] == 0 and row["generation"] == 1,
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE entity_id=? AND revision<? AND event_type IN ('thing_enrolled','thing_enrolled_reviewed','thing_enrollment_rereviewed','thing_narrowed','thing_revoked','thing_profile_selected','thing_profile_selection_revoked')",
             [
               row["target_id"],
               row["binding_revision"]
             ]
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_review_history WHERE thing_id=? AND revision<?",
             [row["target_id"], row["binding_revision"]]
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp previous_review(db, row, history) do
    with {:ok, [[stable, profile, qualification, manufacturer, model, firmware, 2]]} <-
           query(
             db,
             "SELECT stable_id,profile_ref,qualification_ref,manufacturer,model,firmware,digest_version FROM enrollment_review_history WHERE revision=? AND thing_id=?",
             [row["previous_binding_revision"], row["target_id"]]
           ),
         true <-
           {stable, profile, qualification, manufacturer, model, firmware} ==
             {history.basis["stable_id"], history.current_thing.profile_ref,
              history.current_thing.capabilities["power"].evidence_ref,
              history.basis["manufacturer"], history.basis["model"], history.basis["firmware"]} do
      :ok
    else
      _ -> :error
    end
  end

  defp maintenance_link(db, maintenance, expected) do
    with {:ok, [[1]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM host_maintenance_operations b WHERE b.revision=? AND b.action IN ('begin','transfer') AND b.revision<=? AND NOT EXISTS (SELECT 1 FROM host_maintenance_operations e WHERE e.action='end' AND e.begin_revision=b.revision AND e.revision<=?)",
             [maintenance, expected, expected]
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp head_links(db, head) do
    with {:ok, thing} <- Registry.decode_thing(head["thing_document"]),
         {:ok, [[profile, document, resource, binding]]} <-
           query(
             db,
             "SELECT t.profile_ref,t.document,t.resource_revision,b.revision FROM enrolled_things t JOIN enrollment_bindings b ON b.thing_id=t.thing_id WHERE t.thing_id=?",
             [head["target_id"]]
           ),
         true <-
           {profile, document, resource, binding} ==
             {thing.profile_ref, head["thing_document"], head["resource_revision"],
              head["binding_revision"]} do
      :ok
    else
      _ -> :error
    end
  end

  defp enrollment_chain(db, [first | _] = chain) do
    # Initial selection owns its original enrollment; replacement keeps the
    # preceding reviewed cohort. Later reviews belong to selected generations.
    baseline =
      if first["previous_binding_revision"] == 0,
        do: first["binding_revision"],
        else: first["previous_binding_revision"]

    succession? =
      query(db, "PRAGMA user_version") in [
        {:ok, [[22]]},
        {:ok, [[23]]},
        {:ok, [[24]]},
        {:ok, [[25]]},
        {:ok, [[26]]},
        {:ok, [[27]]}
      ]

    with {:ok, [[profile, qualification, operator, stable]]} <-
           query(
             db,
             "SELECT profile_ref,qualification_ref,operator_id,stable_id FROM enrollment_review_history WHERE thing_id=? AND revision=?",
             [first["target_id"], baseline]
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT revision,profile_ref,qualification_ref,operator_id,stable_id FROM enrollment_review_history WHERE thing_id=? ORDER BY revision LIMIT 33",
             [first["target_id"]]
           ),
         true <- length(rows) in 1..32,
         selected = Enum.filter(chain, &(&1["state"] == "selected")),
         true <-
           Enum.all?(rows, fn [revision, p, q, o, s] ->
             if revision <= first["previous_binding_revision"],
               do:
                 {p, q, s} == {profile, qualification, stable} and (succession? or o == operator),
               else: Enum.any?(selected, &(&1["binding_revision"] == revision)) and s == stable
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp current_pointer?(values, grouped) do
    row = Map.new(Enum.zip(~w(target_id generation selection_revision state), values))

    with {:ok, _} <- LedgerCodec.encode("current", row),
         [_ | _] = chain <- grouped[row["target_id"]],
         head = List.last(chain) do
      {row["generation"], row["selection_revision"], row["state"]} ==
        {head["generation"], head["revision"], head["state"]}
    else
      _ -> false
    end
  end

  defp same_parent?(row, parent),
    do: Enum.all?(~w(principal_id authority_epoch operation_id), &(row[&1] == parent[&1]))

  defp parent_receipt?(db, parent, owned) do
    targets = MapSet.new(owned, & &1["target_id"])

    authority_revisions =
      [
        parent["final_revision"]
        | Enum.flat_map(owned, fn row ->
            if row["state"] == "selected",
              do: [row["binding_revision"], row["revision"]],
              else: [row["revision"]]
          end)
      ]
      |> Enum.sort()

    reason = invalidation_reason(parent["action"])

    with {:ok, events} <-
           query(
             db,
             "SELECT revision FROM authority_journal WHERE revision>? AND revision<=? ORDER BY revision",
             [parent["expected_revision"], parent["final_revision"]]
           ),
         true <- Enum.map(events, &hd/1) == authority_revisions,
         {:ok, [[0]]} <-
           query(db, "SELECT COUNT(*) FROM journal WHERE revision>? AND revision<=?", [
             parent["expected_revision"],
             parent["final_revision"]
           ]),
         {:ok, requests} <-
           query(
             db,
             "SELECT r.target_id,j.disposition,j.reason FROM request_journal j JOIN request_receipts r USING (principal_id,authority_epoch,operation_id) WHERE j.revision>? AND j.revision<=? ORDER BY j.revision",
             [parent["expected_revision"], parent["final_revision"]]
           ),
         true <- length(requests) == parent["invalidated_requests"],
         true <-
           Enum.all?(requests, fn
             [target, "rejected", ^reason] when is_binary(reason) ->
               MapSet.member?(targets, target)

             [target, "outcome_unknown", unknown] when is_binary(reason) ->
               MapSet.member?(targets, target) and unknown == reason <> "_after_handoff"

             _ ->
               false
           end),
         true <-
           Enum.count(requests, &(Enum.at(&1, 1) == "outcome_unknown")) ==
             parent["unknown_outcomes"] do
      true
    else
      _ -> false
    end
  end

  defp invalidation_reason("approve"), do: nil
  defp invalidation_reason("revoke"), do: "profile_trust_revoked"
  defp invalidation_reason("select"), do: "profile_selected"
  defp invalidation_reason("revoke_selection"), do: "profile_selection_revoked"

  defp selection_event("selected"), do: "thing_profile_selected"
  defp selection_event("revoked"), do: "thing_profile_selection_revoked"
end
