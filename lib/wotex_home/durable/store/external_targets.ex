defmodule WotexHome.Durable.Store.ExternalTargets do
  @moduledoc "Stateless retained external target history and atomic retirement for Store."
  alias WotexHome.Durable.Registry

  alias WotexHome.Durable.Store.{
    Access,
    ExternalTrustWriter,
    Journal,
    MaintenanceWriter,
    OverrideWriter,
    ProfileWriter,
    RequestInvalidator
  }

  alias WotexHome.Profiles.{ExternalArtifact, ExternalTarget, ExternalTrust, RetainedSource}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @maximum 9_223_372_036_854_775_807
  @operations ~w(principal_id authority_epoch operation_id input_document outcome_document receipt_document revision)
  @history ~w(target_id revision generation action cause_revision outcome_document)
  @current ~w(target_id selection_revision generation state resource_revision binding_revision)
  @bindings ~w(target_id stable_id source_ref owner_epoch source_selection_sha256 source_generation binding_revision)
  @tables %{
    "profile_external_target_operations" => @operations,
    "profile_external_target_history" => @history,
    "profile_external_target_current" => @current,
    "profile_external_source_bindings" => @bindings
  }
  def tables, do: @tables

  @doc "Current native observation basis; creates no report, grant or effect pin."
  def observation_basis(db, source) do
    with :ok <- validate(db),
         {:ok, [[target]]} <-
           query(
             db,
             "SELECT c.target_id FROM profile_external_target_current c JOIN profile_external_source_bindings b ON b.target_id=c.target_id WHERE c.state='selected' AND b.source_ref=? AND b.owner_epoch=? AND b.source_selection_sha256=?",
             [
               source["source_ref"],
               source["source_owner_epoch"],
               source["source_selection_sha256"]
             ]
           ),
         {:ok, current} <- cursor(db, target),
         {:ok, [[principal, input_doc, receipt_doc]]} <-
           query(
             db,
             "SELECT principal_id,input_document,receipt_document FROM profile_external_target_operations WHERE revision=?",
             [current.binding_revision]
           ),
         {:ok, input} <- ExternalTarget.decode(input_doc),
         {:ok, receipt} <- ExternalTarget.decode_receipt(receipt_doc),
         true <- selection_author?(db, principal),
         {:ok, trust} <- trust(db, input["artifact_digest"]),
         :ok <- allowed_trust(db, input, trust),
         :ok <-
           same(trust.receipt["revision"], receipt["trust_revision"], :external_trust_changed),
         {:ok, [[revision, epoch, policy]]} <- meta(db),
         :ok <- same(policy, receipt["policy_generation"], :external_policy_changed),
         do:
           {:ok,
            %{
              target_id: target,
              principal: principal,
              input: input,
              selection_receipt: receipt,
              current: current,
              revision: revision,
              epoch: epoch,
              policy: policy
            }},
         else: (
           false -> {:error, :profile_author_unavailable}
           {:ok, []} -> {:error, :external_selection_changed}
           {:ok, [_ | _]} -> {:error, :external_selection_changed}
           error -> error
         )
  end

  def actor(db, credential) do
    with {:ok, p} <- ProfileWriter.review_actor(db, credential),
         {:ok, permissions} <- Access.active_principal_permissions(db, p),
         true <- "enroll:review" in permissions,
         do: {:ok, p},
         else: (
           false -> {:error, :permission_denied}
           error -> error
         )
  end

  def prepare(db, credential, document) do
    with {:ok, i} <- ExternalTarget.decode(document),
         {:ok, p} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_external_target_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [p, i["authority_epoch"], i["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, p, i}

        [[^document, r]] ->
          with {:ok, r} <- ExternalTarget.decode_receipt(r), do: {:ok, :existing, r}

        [_] ->
          {:error, :external_target_conflict}

        _ ->
          corrupt()
      end
    end
  end

  def status(db, credential, epoch, operation) do
    with true <- is_integer(epoch) and epoch in 1..@maximum and WotexHome.Id.valid?(operation),
         {:ok, p} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_external_target_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [p, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[r]] -> ExternalTarget.decode_receipt(r)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_external_target}
      error -> error
    end
  end

  def basis(db, input) do
    with {:ok, [[revision, epoch, policy]]} <- meta(db),
         :ok <- same(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- same(revision, input["expected_revision"], :resnapshot_required),
         :ok <- same(policy, input["expected_policy_generation"], :external_policy_changed),
         {:ok, _} <- MaintenanceWriter.require_active(db),
         {:ok, current} <- cursor(db, input["target_id"]),
         :ok <-
           same(
             current.selection_revision,
             input["expected_selection_revision"],
             :external_selection_changed
           ),
         :ok <-
           same(
             current.resource_revision,
             input["expected_resource_revision"],
             :resnapshot_required
           ),
         :ok <- desired(input["action"], current),
         {:ok, trust} <- trust(db, input["artifact_digest"]),
         :ok <-
           same(
             trust.receipt["revision"],
             input["expected_trust_revision"],
             :external_trust_changed
           ),
         :ok <- allowed_trust(db, input, trust),
         true <-
           current.generation < @maximum and current.resource_revision < @maximum and
             revision < @maximum,
         {:ok, document} <- ExternalTarget.encode(input),
         :ok <- capacity(db, byte_size(document), 0, current.selection_revision == 0),
         do: {:ok, %{current: current, trust: trust, policy: policy}},
         else: (
           false -> {:error, :revision_exhausted}
           error -> error
         )
  end

  defp desired("revoke", %{selection_revision: 0}), do: :not_found
  defp desired("revoke", %{state: "revoked"}), do: {:error, :external_target_already_revoked}
  defp desired(_, _), do: :ok

  def trust(db, digest) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT principal_id,receipt_document FROM profile_external_trust_operations ORDER BY revision DESC LIMIT 1025"
           ),
         found =
           Enum.find_value(rows, fn [p, d] ->
             case ExternalTrust.decode_receipt(d) do
               {:ok, r} -> if r["artifact_digest"] == digest, do: %{principal: p, receipt: r}
               _ -> nil
             end
           end),
         true <- found != nil,
         {:ok, [[document]]} <-
           query(
             db,
             "SELECT artifact_document FROM profile_external_artifacts WHERE artifact_digest=?",
             [digest]
           ),
         do: {:ok, Map.put(found, :document, document)},
         else: (
           false -> :not_found
           error -> error
         )
  end

  defp allowed_trust(_db, %{"action" => "revoke"}, _), do: :ok

  defp allowed_trust(db, _, t) do
    with true <- t.receipt["action"] == "approve",
         {:ok, permissions} <- Access.active_principal_permissions(db, t.principal),
         true <- "profile:manage" in permissions,
         do: :ok,
         else: (_ -> {:error, :external_trust_changed})
  end

  def cursor(db, target) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT c.selection_revision,c.generation,c.state,c.resource_revision,c.binding_revision,h.outcome_document FROM profile_external_target_current c JOIN profile_external_target_history h ON h.target_id=c.target_id AND h.revision=c.selection_revision WHERE c.target_id=?",
             [target]
           ),
         {:ok, enrolled} <-
           query(
             db,
             "SELECT document,resource_revision,status FROM enrolled_things WHERE thing_id=?",
             [target]
           ) do
      case {rows, enrolled} do
        {[], []} ->
          {:ok,
           %{
             selection_revision: 0,
             generation: 0,
             state: nil,
             resource_revision: 0,
             binding_revision: 0,
             outcome: nil
           }}

        {[], [_]} ->
          {:error, :external_target_collision}

        {[[rev, gen, state, resource, binding, doc]], [[thing_doc, resource, status]]} ->
          with {:ok, o} <- ExternalTarget.decode_outcome(doc),
               true <- o["thing_document"] == thing_doc and status == enrollment_state(state),
               do:
                 {:ok,
                  %{
                    selection_revision: rev,
                    generation: gen,
                    state: state,
                    resource_revision: resource,
                    binding_revision: binding,
                    outcome: o
                  }},
               else: (_ -> corrupt())

        _ ->
          corrupt()
      end
    end
  end

  def retain_tx(db, credential, document, outcome_document) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, context} <- basis(db, input),
         {:ok, outcome} <- ExternalTarget.decode_outcome(outcome_document),
         :ok <- correspondence(input, outcome, context),
         {:ok, source} <- RetainedSource.decode(outcome["source_document"]),
         :ok <- identity(db, input["target_id"], source.inputs["source"]["stable_id"]),
         :ok <-
           capacity(
             db,
             byte_size(document),
             byte_size(outcome_document),
             context.current.selection_revision == 0
           ),
         {:ok, [[withdrawn]]} <-
           query(db, "SELECT COUNT(*) FROM principal_targets WHERE thing_id=?", [
             input["target_id"]
           ]),
         true <- withdrawn <= 4096,
         {:ok, next} <- Journal.next_revision(db),
         :ok <-
           transition(
             db,
             input["target_id"],
             input["action"],
             next,
             next,
             context.current,
             outcome_document
           ),
         receipt =
           receipt(input, document, outcome_document, source.sha256, next, context, withdrawn),
         {:ok, receipt_document} <- ExternalTarget.encode_receipt(receipt),
         :ok <-
           insert(db, "profile_external_target_operations", [
             principal,
             input["authority_epoch"],
             input["operation_id"],
             document,
             outcome_document,
             receipt_document,
             next
           ]),
         :ok <- validate(db),
         do: {:commit, {:ok, receipt}},
         else: (
           {:ok, :existing, r} -> {:rollback, {:unchanged, {:ok, r}}}
           false -> {:rollback, {:policy, :external_target_capacity}}
           :not_found -> {:rollback, {:policy, :external_trust_changed}}
           {:error, :corrupt_external_targets} -> {:rollback, :corrupt_external_targets}
           {:error, reason} when is_atom(reason) -> {:rollback, {:policy, reason}}
           {:error, reason} -> {:rollback, reason}
           _ -> {:rollback, :corrupt_external_targets}
         )
  end

  defp correspondence(i, o, c) do
    with true <- o["action"] == i["action"] and o["target_id"] == i["target_id"],
         true <- o["artifact_document"] == c.trust.document,
         {:ok, s} <- RetainedSource.decode(o["source_document"]),
         true <-
           i["action"] == "revoke" or
             (s.owner_epoch == i["source_owner_epoch"] and
                s.sha256 == i["source_selection_sha256"] and
                s.inputs["source"]["source_ref"] == i["source_ref"]),
         true <- i["action"] != "revoke" or o == Map.put(c.current.outcome, "action", "revoke"),
         do: :ok,
         else: (_ -> {:error, :external_artifact_mismatch})
  end

  defp identity(db, target, stable) do
    with {:ok, []} <-
           query(db, "SELECT thing_id FROM enrollment_bindings WHERE stable_id=?", [stable]),
         {:ok, rows} <-
           query(
             db,
             "SELECT target_id,stable_id FROM profile_external_source_bindings WHERE stable_id=? OR target_id=?",
             [stable, target]
           ),
         true <- rows == [] or rows == [[target, stable]],
         do: :ok,
         else: (_ -> {:error, :external_target_collision})
  end

  defp transition(db, target, action, revision, cause, previous, outcome_document) do
    with {:ok, o} <- ExternalTarget.decode_outcome(outcome_document),
         {:ok, s} <- RetainedSource.decode(o["source_document"]),
         {:ok, thing} <- Registry.decode_thing(o["thing_document"]),
         state = if(action == "select", do: "selected", else: "revoked"),
         resource =
           if(previous.selection_revision == 0, do: 0, else: previous.resource_revision + 1),
         binding = if(action == "select", do: revision, else: previous.binding_revision),
         :ok <- Journal.authority_event(db, revision, event(action), target),
         :ok <-
           insert(db, "profile_external_target_history", [
             target,
             revision,
             previous.generation + 1,
             action,
             cause,
             outcome_document
           ]),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO enrolled_things VALUES (?,?,?,?,?) ON CONFLICT(thing_id) DO UPDATE SET profile_ref=excluded.profile_ref,document=excluded.document,resource_revision=excluded.resource_revision,status=excluded.status",
             [target, thing.profile_ref, o["thing_document"], resource, enrollment_state(state)]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_external_target_current VALUES (?,?,?,?,?,?) ON CONFLICT(target_id) DO UPDATE SET selection_revision=excluded.selection_revision,generation=excluded.generation,state=excluded.state,resource_revision=excluded.resource_revision,binding_revision=excluded.binding_revision",
             [target, revision, previous.generation + 1, state, resource, binding]
           ),
         :ok <- binding(db, target, action, revision, s),
         :ok <- invalidate(db, target),
         do: :ok
  end

  defp binding(_, _, action, _, _) when action != "select", do: :ok

  defp binding(db, target, "select", revision, s) do
    source = s.inputs["source"]

    with {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_external_source_bindings VALUES (?,?,?,?,?,?,?) ON CONFLICT(target_id) DO UPDATE SET source_ref=excluded.source_ref,owner_epoch=excluded.owner_epoch,source_selection_sha256=excluded.source_selection_sha256,source_generation=excluded.source_generation,binding_revision=excluded.binding_revision",
             [
               target,
               source["stable_id"],
               source["source_ref"],
               s.owner_epoch,
               s.sha256,
               source["source_generation"],
               revision
             ]
           ),
         do: :ok
  end

  defp invalidate(db, target) do
    with :ok <- WotexHome.Durable.Store.ExternalObservations.clear_current_if_present(db, target),
         :ok <- OverrideWriter.clear_override_for_target(db, target),
         {:ok, []} <- query(db, "DELETE FROM principal_targets WHERE thing_id=?", [target]),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id=?", [target]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id=?", [target]),
         {:ok, []} <-
           query(db, "UPDATE profile_qualifications SET status='revoked' WHERE thing_id=?", [
             target
           ]),
         {:ok, held} <- RequestInvalidator.held_for_thing(db, target),
         {:ok, _} <- RequestInvalidator.reject_held_batch(db, held, "external_selection_changed"),
         {:ok, _} <-
           RequestInvalidator.invalidate_execution_for(
             db,
             {:thing, target},
             "external_selection_changed"
           ),
         do: :ok
  end

  def withdraw_if_current(db, cause) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [34, 35] -> withdraw(db, cause)
      {:ok, [[v]]} when v in 4..33 -> :ok
      _ -> corrupt()
    end
  end

  defp withdraw(db, cause) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT target_id FROM profile_external_target_current WHERE state='selected' ORDER BY target_id"
           ) do
      Enum.reduce_while(rows, :ok, fn [target], :ok ->
        with {:ok, current} <- cursor(db, target),
             {:ok, artifact} <- ExternalArtifact.decode(current.outcome["artifact_document"]),
             {:ok, digest} <- ExternalArtifact.identity(artifact),
             {:ok, trust} <- trust(db, digest),
             {:ok, [[selector]]} <-
               query(
                 db,
                 "SELECT principal_id FROM profile_external_target_operations WHERE revision=?",
                 [current.binding_revision]
               ) do
          if allowed_trust(db, %{}, trust) == :ok and selection_author?(db, selector) do
            {:cont, :ok}
          else
            with {:ok, next} <- Journal.next_revision(db),
                 {:ok, doc} <-
                   ExternalTarget.encode_outcome(Map.put(current.outcome, "action", "revoke")),
                 :ok <- transition(db, target, "dependency_revoked", next, cause, current, doc),
                 do: {:cont, :ok},
                 else: (error -> {:halt, error})
          end
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp selection_author?(db, p) do
    case Access.active_principal_permissions(db, p) do
      {:ok, permissions} -> "profile:manage" in permissions and "enroll:review" in permissions
      _ -> false
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [34, 35] -> validate(db)
      {:ok, [[v]]} when v in 4..33 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- ExternalTrustWriter.validate(db),
         {:ok, [[maximum, epoch, _policy]]} <- meta(db),
         :ok <- capacity(db, 0, 0, false, false),
         {:ok, operations} <-
           query(
             db,
             "SELECT #{Enum.join(@operations, ",")} FROM profile_external_target_operations ORDER BY revision LIMIT 1025"
           ),
         {:ok, ops} <- validate_operations(db, operations, maximum, epoch),
         {:ok, history} <-
           query(
             db,
             "SELECT #{Enum.join(@history, ",")} FROM profile_external_target_history ORDER BY revision LIMIT 2049"
           ),
         true <- length(history) <= 2048,
         {:ok, latest, used} <- validate_history(db, history, ops, maximum),
         true <- used == MapSet.new(Map.keys(ops)),
         :ok <- validate_current(db, latest, ops, maximum),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('external_target_selected','external_target_revoked','external_target_dependency_revoked')"
           ),
         true <- count == length(history),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp validate_operations(db, rows, maximum, epoch) do
    Enum.reduce_while(rows, {:ok, %{}}, fn [p, e, op, id, od, rd, rev], {:ok, acc} ->
      with {:ok, i} <- ExternalTarget.decode(id),
           {:ok, o} <- ExternalTarget.decode_outcome(od),
           {:ok, r} <- ExternalTarget.decode_receipt(rd),
           {:ok, s} <- RetainedSource.decode(o["source_document"]),
           true <-
             is_integer(e) and e in 1..epoch and rev in 1..maximum and
               i["authority_epoch"] == e and i["operation_id"] == op and
               i["expected_revision"] == rev - 1,
           true <-
             r["authority_epoch"] == e and r["operation_id"] == op and r["revision"] == rev and
               r["input_sha256"] == sha(id) and r["outcome_sha256"] == sha(od) and
               r["source_selection_sha256"] == s.sha256 and
               r["action"] == i["action"] and r["target_id"] == i["target_id"] and
               r["artifact_digest"] == i["artifact_digest"] and
               r["trust_revision"] == i["expected_trust_revision"] and
               r["policy_generation"] == i["expected_policy_generation"],
           {:ok, [[_]]} <-
             query(db, "SELECT principal_id FROM principals WHERE principal_id=?", [p]),
           {:ok, [[approved]]} <-
             query(
               db,
               "SELECT artifact_document FROM profile_external_artifacts WHERE artifact_digest=?",
               [i["artifact_digest"]]
             ),
           true <- approved == o["artifact_document"],
           :ok <- historical_trust(db, i, rev),
           :ok <- original_source(i, s),
           :ok <- imported_objects(db, p, i, o),
           do:
             {:cont,
              {:ok,
               Map.put(acc, rev, %{input: i, outcome: o, receipt: r, document: od, principal: p})}},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp original_source(%{"action" => "revoke"}, _), do: :ok

  defp original_source(i, s),
    do:
      if(
        i["source_ref"] == s.inputs["source"]["source_ref"] and
          i["source_owner_epoch"] == s.owner_epoch and i["source_selection_sha256"] == s.sha256,
        do: :ok,
        else: corrupt()
      )

  defp imported_objects(_, _, %{"action" => "revoke"}, _), do: :ok

  defp imported_objects(db, principal, i, o) do
    {:ok, artifact} = ExternalArtifact.decode(o["artifact_document"])
    objects = i["objects"]

    requested =
      [
        {objects["envelope_ref"], nil},
        {objects["profile"]["object_ref"], objects["profile"]["reference"]}
      ] ++ Enum.map(objects["definitions"], &{&1["object_ref"], &1["reference"]})

    if length(requested) != length(artifact["objects"]) do
      corrupt()
    else
      Enum.zip(requested, artifact["objects"])
      |> Enum.reduce_while(:ok, fn {{h, ref}, a}, :ok ->
        with true <-
               h["object_digest"] == a["object_digest"] and ref == a["reference"] and
                 h["first_revision"] <= i["expected_revision"],
             {:ok, [[kind, digest, bytes, first]]} <-
               query(
                 db,
                 "SELECT kind,payload_sha256,payload_bytes,first_revision FROM profile_authoring_objects WHERE principal_id=? AND object_digest=?",
                 [principal, h["object_digest"]]
               ),
             true <-
               kind == a["kind"] and digest == a["payload_sha256"] and bytes == a["payload_bytes"] and
                 first == h["first_revision"],
             do: {:cont, :ok},
             else: (_ -> {:halt, corrupt()})
      end)
    end
  end

  defp historical_trust(db, i, rev) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_external_trust_operations WHERE revision<? ORDER BY revision",
             [rev]
           ),
         receipts =
           Enum.map(rows, fn [d] ->
             {:ok, r} = ExternalTrust.decode_receipt(d)
             r
           end),
         own = Enum.filter(receipts, &(&1["artifact_digest"] == i["artifact_digest"])),
         last when is_map(last) <- List.last(own),
         true <-
           last["revision"] == i["expected_trust_revision"] and
             (i["action"] == "revoke" or last["action"] == "approve"),
         true <- List.last(receipts)["policy_generation"] == i["expected_policy_generation"],
         do: :ok,
         else: (_ -> corrupt())
  end

  defp validate_history(db, rows, ops, maximum) do
    Enum.reduce_while(rows, {:ok, %{}, MapSet.new()}, fn [
                                                           target,
                                                           revision,
                                                           gen,
                                                           action,
                                                           cause,
                                                           doc
                                                         ],
                                                         {:ok, latest, used} ->
      previous = latest[target]

      with true <-
             revision in 1..maximum and gen == if(previous, do: previous.generation + 1, else: 1),
           {:ok, o} <- ExternalTarget.decode_outcome(doc),
           true <-
             o["target_id"] == target and
               o["action"] == if(action == "select", do: "select", else: "revoke"),
           {:ok, [[event_type, ^target]]} <-
             query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
               revision
             ]),
           true <- event_type == event(action),
           :ok <- retirement_correspondence(db, previous, action, cause, revision, ops),
           :ok <-
             history_original(db, target, revision, gen, action, cause, doc, o, previous, ops),
           {:ok, s} <- RetainedSource.decode(o["source_document"]),
           true <-
             previous == nil or
               previous.source.inputs["source"]["stable_id"] == s.inputs["source"]["stable_id"],
           binding = if(action == "select", do: revision, else: previous.binding_revision),
           record = %{
             revision: revision,
             generation: gen,
             state: if(action == "select", do: "selected", else: "revoked"),
             resource_revision: gen - 1,
             binding_revision: binding,
             outcome: o,
             source: s
           },
           do:
             {:cont,
              {:ok, Map.put(latest, target, record),
               if(action == "dependency_revoked", do: used, else: MapSet.put(used, revision))}},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp history_original(
         db,
         target,
         rev,
         _gen,
         "dependency_revoked",
         cause,
         _doc,
         o,
         previous,
         ops
       ) do
    with true <- previous != nil and previous.state == "selected" and cause < rev,
         true <- o == Map.put(previous.outcome, "action", "revoke"),
         {:ok, [[event, entity]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             cause
           ]),
         select when is_map(select) <- ops[previous.binding_revision],
         {:ok, trust_author} <- trust_author_at(db, select.input["artifact_digest"], cause),
         true <-
           (event == "external_profile_revoked" and entity == select.input["artifact_digest"]) or
             (event == "principal_revoked" and entity in [select.principal, trust_author]),
         true <- select.input["target_id"] == target,
         do: :ok,
         else: (_ -> corrupt())
  end

  defp history_original(_, target, rev, gen, action, cause, doc, o, previous, ops)
       when action in ~w(select revoke) do
    with original when is_map(original) <- ops[rev],
         true <-
           cause == rev and original.document == doc and original.input["target_id"] == target and
             original.input["action"] == action,
         i = original.input,
         r = original.receipt,
         true <-
           i["expected_selection_revision"] == if(previous, do: previous.revision, else: 0) and
             i["expected_resource_revision"] ==
               if(previous, do: previous.resource_revision, else: 0),
         true <-
           r["previous_selection_revision"] == i["expected_selection_revision"] and
             r["selection_generation"] == gen and r["resource_revision"] == gen - 1,
         true <-
           r["binding_revision"] ==
             if(action == "select", do: rev, else: previous && previous.binding_revision),
         true <-
           action != "revoke" or
             (previous != nil and previous.state == "selected" and
                o == Map.put(previous.outcome, "action", "revoke")),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp history_original(_, _, _, _, _, _, _, _, _, _), do: corrupt()

  defp trust_author_at(db, digest, cause) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT principal_id,receipt_document FROM profile_external_trust_operations WHERE revision<? ORDER BY revision DESC",
             [cause]
           ) do
      Enum.reduce_while(rows, corrupt(), fn [p, doc], _ ->
        case ExternalTrust.decode_receipt(doc) do
          {:ok, r} ->
            if r["artifact_digest"] == digest, do: {:halt, {:ok, p}}, else: {:cont, corrupt()}

          _ ->
            {:halt, corrupt()}
        end
      end)
    end
  end

  defp validate_current(db, latest, ops, maximum) do
    with {:ok, rows} <-
           query(db, "SELECT #{Enum.join(@current, ",")} FROM profile_external_target_current"),
         {:ok, bindings} <-
           query(db, "SELECT #{Enum.join(@bindings, ",")} FROM profile_external_source_bindings"),
         true <- length(rows) == map_size(latest) and length(bindings) == map_size(latest) do
      Enum.reduce_while(rows, :ok, fn [target, revision, gen, state, resource, binding], :ok ->
        h = latest[target]

        with true <-
               h != nil and
                 [revision, gen, state, resource, binding] == [
                   h.revision,
                   h.generation,
                   h.state,
                   h.resource_revision,
                   h.binding_revision
                 ],
             {:ok, current} <- cursor(db, target),
             true <- current.outcome == h.outcome,
             source = h.source.inputs["source"],
             true <-
               [
                 target,
                 source["stable_id"],
                 source["source_ref"],
                 h.source.owner_epoch,
                 h.source.sha256,
                 source["source_generation"],
                 binding
               ] in bindings,
             :ok <- identity(db, target, source["stable_id"]),
             :ok <- retirement_correspondence(db, h, "current", nil, maximum, ops),
             do: {:cont, :ok},
             else: (_ -> {:halt, corrupt()})
      end)
    else
      _ -> corrupt()
    end
  end

  defp retirement_correspondence(_, nil, _, _, _, _), do: :ok
  defp retirement_correspondence(_, %{state: "revoked"}, _, _, _, _), do: :ok

  defp retirement_correspondence(db, previous, action, cause, upper, ops) do
    select = ops[previous.binding_revision]

    with true <- select != nil,
         {:ok, [[author]]} <-
           query(
             db,
             "SELECT principal_id FROM profile_external_trust_operations WHERE revision=?",
             [select.receipt["trust_revision"]]
           ),
         {:ok, causes} <-
           query(
             db,
             "SELECT revision FROM authority_journal WHERE revision>? AND revision<=? AND ((event_type='external_profile_revoked' AND entity_id=?) OR (event_type='principal_revoked' AND entity_id IN (?,?))) ORDER BY revision LIMIT 1",
             [previous.revision, upper, select.input["artifact_digest"], select.principal, author]
           ),
         true <-
           (action == "dependency_revoked" and causes == [[cause]]) or
             (action != "dependency_revoked" and causes == []),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp receipt(i, id, od, sha, revision, c, withdrawn) do
    %{
      "authority_epoch" => i["authority_epoch"],
      "operation_id" => i["operation_id"],
      "revision" => revision,
      "input_sha256" => sha(id),
      "action" => i["action"],
      "target_id" => i["target_id"],
      "artifact_digest" => i["artifact_digest"],
      "previous_selection_revision" => i["expected_selection_revision"],
      "selection_generation" => c.current.generation + 1,
      "resource_revision" =>
        if(c.current.selection_revision == 0, do: 0, else: c.current.resource_revision + 1),
      "binding_revision" =>
        if(i["action"] == "select", do: revision, else: c.current.binding_revision),
      "trust_revision" => i["expected_trust_revision"],
      "policy_generation" => c.policy,
      "source_selection_sha256" => sha,
      "outcome_sha256" => sha(od),
      "withdrawn_grants" => withdrawn
    }
  end

  defp capacity(db, input, outcome, target_new?, new? \\ true) do
    with {:ok, [[n, inputs, outcomes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(outcome_document AS BLOB))),0) FROM profile_external_target_operations"
           ),
         {:ok, [[targets]]} <- query(db, "SELECT COUNT(*) FROM profile_external_target_current"),
         {:ok, [[history, history_bytes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(outcome_document AS BLOB))),0) FROM profile_external_target_history"
           ),
         true <-
           n + if(new?, do: 1, else: 0) <= 1024 and inputs + input <= 4_194_304 and
             outcomes + outcome <= 4_194_304 and targets + if(target_new?, do: 1, else: 0) <= 256 and
             history <= 2048 and history_bytes <= 8_388_608,
         do: :ok,
         else: (_ -> {:error, :external_target_capacity})
  end

  defp insert(db, table, values) do
    with {:ok, []} <-
           query(
             db,
             "INSERT INTO #{table} (#{Enum.join(@tables[table], ",")}) VALUES (#{Enum.map_join(values, ",", fn _ -> "?" end)})",
             values
           ),
         do: :ok
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='external_profile_policy_generation')"
      )

  defp same(v, v, _), do: :ok
  defp same(_, _, error), do: {:error, error}
  defp enrollment_state("selected"), do: "active"
  defp enrollment_state("revoked"), do: "revoked"
  defp event("select"), do: "external_target_selected"
  defp event("revoke"), do: "external_target_revoked"
  defp event("dependency_revoked"), do: "external_target_dependency_revoked"
  defp event(_), do: "invalid"
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp corrupt, do: {:error, :corrupt_external_targets}
end
