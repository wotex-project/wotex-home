defmodule WotexHome.Durable.Store.RuleWriter do
  @moduledoc """
  Store-owned admission, generation activation and explicit invocation ledger.

  No device I/O, caller truth maps, scheduler or native verifier enters this
  borrowed-handle domain. Every rule effect is a normal scoped request; its
  immutable origin must still pass current rule/lease guards before dispatch.
  """
  alias WotexHome.{Id, Mutation}
  alias WotexHome.Durable.Registry

  alias WotexHome.Durable.Store.{
    Access,
    InvariantWriter,
    Journal,
    MaintenanceWriter,
    OverrideWriter,
    ProfilePins,
    RequestInvalidator,
    RequestLedger
  }

  alias WotexHome.Rules.{AdmissionArtifact, Codec}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807
  @capacity 1_024

  def admit(db, credential, epoch, operation, expected, source) do
    policy(fn ->
      with :ok <- input(epoch, operation, expected),
           {:ok, actor} <- actor(db, credential, :manage),
           {:ok, rows} <-
             query(
               db,
               "SELECT expected_revision, source_document, artifact_document, artifact_digest, revision FROM rule_admissions WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
               [actor, epoch, operation]
             ) do
        case rows do
          [[^expected, ^source, artifact, digest, revision]] ->
            with {:ok, _} <- historical_admission(db, revision),
                 true <- AdmissionArtifact.digest(artifact) == digest do
              {:rollback,
               {:unchanged, {:ok, admission_receipt(actor, epoch, operation, revision, digest)}}}
            else
              _ -> {:error, :corrupt_rule_admission}
            end

          [_] ->
            {:error, :rule_operation_conflict}

          [] ->
            with :ok <- MaintenanceWriter.guard(db),
                 :ok <- capacity(db, "rule_admissions"),
                 :ok <- unused_operation(db, "rule_activations", actor, epoch, operation),
                 :ok <- compare_meta(db, epoch, expected),
                 {:ok, rule} <- source_rule(source),
                 target = elem(rule.effect, 0),
                 :ok <- grant(db, actor, target),
                 {:ok, thing, resource_revision} <- Access.usable_thing(db, target),
                 {:ok, profile_pin} <- ProfilePins.capture(db, thing, resource_revision),
                 {:ok, declaration} <- Registry.encode_thing(thing),
                 {:ok, invariant} <- invariant_pin(db, target),
                 {:ok, artifact} <-
                   AdmissionArtifact.build(
                     source,
                     [
                       %{
                         "thing_id" => target,
                         "resource_revision" => resource_revision,
                         "document" => declaration
                       }
                     ],
                     invariant
                   ),
                 {:ok, revision} <- Journal.next_revision(db),
                 :ok <- Journal.authority_event(db, revision, "rule_admitted", target),
                 digest = AdmissionArtifact.digest(artifact),
                 {:ok, []} <-
                   query(db, "INSERT INTO rule_admissions VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
                     actor,
                     epoch,
                     operation,
                     expected,
                     source,
                     artifact,
                     digest,
                     revision
                   ]),
                 :ok <- ProfilePins.retain(db, :rule, profile_pin, revision, nil) do
              {:commit, {:ok, admission_receipt(actor, epoch, operation, revision, digest)}}
            end

          _ ->
            {:error, :corrupt_rule_admission}
        end
      end
    end)
  end

  def activate(db, credential, epoch, operation, expected, admission_revision) do
    policy(fn ->
      with :ok <- input(epoch, operation, expected),
           true <- integer?(admission_revision),
           {:ok, actor} <- actor(db, credential, :manage),
           {:ok, rows} <-
             query(
               db,
               "SELECT expected_revision, admission_revision, previous_generation, generation, revision, final_revision, affected_requests, unknown_outcomes FROM rule_activations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
               [actor, epoch, operation]
             ) do
        case rows do
          [
            [
              ^expected,
              ^admission_revision,
              previous,
              generation,
              revision,
              final,
              affected,
              unknown
            ]
          ] ->
            with :ok <- historical_activation(db, actor, epoch, operation) do
              {:rollback,
               {:unchanged,
                {:ok,
                 activation_receipt(
                   admission_revision,
                   previous,
                   generation,
                   revision,
                   final,
                   affected,
                   unknown
                 )}}}
            end

          [_] ->
            {:error, :rule_operation_conflict}

          [] ->
            with :ok <- if(admission_revision == 0, do: :ok, else: MaintenanceWriter.guard(db)),
                 :ok <- capacity(db, "rule_activations"),
                 :ok <- unused_operation(db, "rule_admissions", actor, epoch, operation),
                 :ok <- compare_meta(db, epoch, expected),
                 :ok <- activation_basis(db, actor, admission_revision),
                 {:ok, [[current_admission, generation, ^epoch]]} <- current_meta(db),
                 :ok <- active_link(db, current_admission, generation, epoch),
                 true <- integer?(generation) and generation < @max_i64,
                 {:ok, held} <-
                   query(
                     db,
                     "SELECT principal_id, authority_epoch, operation_id FROM request_outbox ORDER BY principal_id, authority_epoch, operation_id LIMIT 1025"
                   ),
                 {:ok, pending} <- RequestInvalidator.pending_execution_rows(db, :all),
                 true <- length(held) + length(pending) <= 1_024,
                 {:ok, revision} <- Journal.next_revision(db),
                 :ok <-
                   Journal.authority_event(db, revision, "rule_policy_activated", "rules:active"),
                 {:ok, []} <-
                   query(db, "UPDATE meta SET value=? WHERE key='rule_generation'", [
                     generation + 1
                   ]),
                 {:ok, []} <-
                   query(db, "UPDATE meta SET value=? WHERE key='active_rule_admission'", [
                     admission_revision
                   ]),
                 {:ok, _} <-
                   RequestInvalidator.reject_held_batch(db, held, "rule_generation_changed"),
                 {:ok, final} <-
                   RequestInvalidator.invalidate_execution_for(
                     db,
                     :all,
                     "rule_generation_changed"
                   ),
                 unknown =
                   Enum.count(pending, &(List.last(&1) in ["dispatching", "protocol_accepted"])),
                 affected = length(held) + length(pending),
                 {:ok, []} <-
                   query(
                     db,
                     "INSERT INTO rule_activations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     [
                       actor,
                       epoch,
                       operation,
                       expected,
                       admission_revision,
                       generation,
                       generation + 1,
                       revision,
                       final,
                       affected,
                       unknown
                     ]
                   ) do
              {:commit,
               {:ok,
                activation_receipt(
                  admission_revision,
                  generation,
                  generation + 1,
                  revision,
                  final,
                  affected,
                  unknown
                )}}
            else
              false -> {:error, :rule_activation_capacity}
              error -> error
            end

          _ ->
            {:error, :corrupt_rule_admission}
        end
      else
        false -> {:error, :invalid_rule_operation}
        error -> error
      end
    end)
  end

  def invoke(db, credential, epoch, operation, expected_generation, rule_id, receipt_limit, clock) do
    policy(fn ->
      with :ok <- input(epoch, operation, expected_generation),
           true <- Id.valid?(rule_id),
           {:ok, principal} <- actor(db, credential, :invoke),
           {:ok, rows} <-
             query(
               db,
               "SELECT admission_revision, rule_id, generation FROM request_rule_origins WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
               [principal, epoch, operation]
             ) do
        case rows do
          [[_admission, ^rule_id, ^expected_generation]] ->
            with {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
                 {:ok, receipt} <- RequestLedger.decode_receipt(principal, epoch, operation, row) do
              {:rollback, {:unchanged, {:ok, receipt}}}
            end

          [_] ->
            {:error, :rule_operation_conflict}

          [] ->
            with :ok <- MaintenanceWriter.guard(db),
                 {:ok, []} <- RequestLedger.select_request(db, principal, epoch, operation),
                 {:ok, [[admission, generation, current_epoch]]} <- current_meta(db),
                 :ok <- equal(current_epoch, epoch, :stale_authority_epoch),
                 :ok <- equal(generation, expected_generation, :stale_rule_generation),
                 :ok <- active_link(db, admission, generation, epoch),
                 true <- admission > 0,
                 {:ok, artifact, _author} <- current_admission(db, admission),
                 true <- artifact.rule.id == rule_id,
                 {target, "power", value} = artifact.rule.effect,
                 :ok <- grant(db, principal, target),
                 {:ok, resource} <- resource_revision(artifact, target),
                 :ok <- current_guards(db, target, epoch, clock),
                 {:ok, mutation} <-
                   Mutation.new(%{
                     "api_version" => 1,
                     "authority_epoch" => epoch,
                     "operation_id" => operation,
                     "expected_revision" => resource,
                     "target_id" => target,
                     "capability_key" => "power",
                     "value" => %{"type" => "boolean", "value" => value.data}
                   }),
                 {:ok, hash} <- Registry.credential_hash(credential),
                 {:commit, {:ok, receipt}} <-
                   RequestLedger.submit_request_tx(db, hash, mutation, receipt_limit),
                 {:ok, []} <-
                   query(db, "INSERT INTO request_rule_origins VALUES (?, ?, ?, ?, ?, ?, ?)", [
                     principal,
                     epoch,
                     operation,
                     admission,
                     rule_id,
                     generation,
                     receipt.revision
                   ]),
                 {:ok, []} <-
                   query(
                     db,
                     "UPDATE request_causal_roots SET rule_admission_revision=?, rule_generation=? WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
                     [admission, generation, principal, epoch, operation]
                   ),
                 {:ok, [[1]]} <- query(db, "SELECT changes()") do
              {:commit, {:ok, receipt}}
            else
              {:ok, [_existing_request]} -> {:error, :rule_operation_conflict}
              false -> {:error, :rule_inactive}
              error -> error
            end

          _ ->
            {:error, :corrupt_rule_admission}
        end
      else
        false -> {:error, :invalid_rule_operation}
        error -> error
      end
    end)
  end

  @doc "Repeated by Store at queue, claim and handoff. Manual requests have no rule origin."
  def execution_guard(db, principal, epoch, operation, clock) do
    with {:ok, [[root_admission, root_generation]]} <-
           query(
             db,
             "SELECT rule_admission_revision, rule_generation FROM request_causal_roots WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT admission_revision, rule_id, generation FROM request_rule_origins WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] when is_nil(root_admission) and is_nil(root_generation) ->
          :ok

        [[admission, rule_id, generation]] ->
          with true <- root_admission == admission and root_generation == generation,
               :ok <-
                 origin_binding(db, principal, epoch, operation, admission, rule_id, generation),
               {:ok, [[^admission, ^generation, ^epoch]]} <- current_meta(db),
               :ok <- active_link(db, admission, generation, epoch),
               {:ok, artifact, _author} <- current_admission(db, admission),
               true <- artifact.rule.id == rule_id,
               :ok <- current_guards(db, elem(artifact.rule.effect, 0), epoch, clock) do
            :ok
          else
            {:ok, _} -> {:error, :rule_basis_changed}
            false -> {:error, :corrupt_rule_admission}
            error -> error
          end

        _ ->
          {:error, :corrupt_rule_admission}
      end
    else
      {:ok, []} -> {:error, :corrupt_receipt}
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  def status(db, credential) do
    with {:ok, _actor} <- actor(db, credential, :manage),
         {:ok, [[admission, generation, epoch]]} <- current_meta(db),
         :ok <- active_link(db, admission, generation, epoch),
         {:ok, state, reason} <- status_basis(db, admission) do
      {:ok,
       %{
         admission_revision: admission,
         rule_generation: generation,
         authority_epoch: epoch,
         state: state,
         reason: reason
       }}
    end
  end

  def operation_status(db, credential, epoch, operation) do
    with :ok <- input(epoch, operation, 0),
         {:ok, actor} <- actor(db, credential, :manage),
         {:ok, admissions} <-
           query(
             db,
             "SELECT revision, artifact_digest FROM rule_admissions WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [actor, epoch, operation]
           ),
         {:ok, activations} <-
           query(
             db,
             "SELECT admission_revision, previous_generation, generation, revision, final_revision, affected_requests, unknown_outcomes FROM rule_activations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [actor, epoch, operation]
           ) do
      case {admissions, activations} do
        {[[revision, digest]], []} ->
          with {:ok, _} <- historical_admission(db, revision),
               do:
                 {:ok,
                  Map.put(
                    admission_receipt(actor, epoch, operation, revision, digest),
                    :kind,
                    :admission
                  )}

        {[], [[admission, previous, generation, revision, final, affected, unknown]]} ->
          with :ok <- historical_activation(db, actor, epoch, operation) do
            {:ok,
             Map.put(
               activation_receipt(
                 admission,
                 previous,
                 generation,
                 revision,
                 final,
                 affected,
                 unknown
               ),
               :kind,
               :activation
             )}
          end

        {[], []} ->
          :not_found

        _ ->
          {:error, :corrupt_rule_admission}
      end
    end
  end

  @doc "Existing-only admission/activation input correspondence; no first-write route."
  def original_status(db, credential, kind, epoch, operation, expected, basis)
      when kind in ["admit", "activate"] do
    with :ok <- input(epoch, operation, expected),
         {:ok, actor} <- actor(db, credential, :manage) do
      case operation_status(db, credential, epoch, operation) do
        {:ok, %{kind: :admission} = receipt} when kind == "admit" ->
          with {:ok, [[^expected, ^basis]]} <-
                 query(
                   db,
                   "SELECT expected_revision, source_document FROM rule_admissions WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
                   [actor, epoch, operation]
                 ),
               do: {:ok, receipt},
               else: (
                 {:ok, _} -> {:error, :rule_operation_conflict}
                 error -> error
               )

        {:ok, %{kind: :activation} = receipt} when kind == "activate" ->
          with {:ok, [[^expected, ^basis]]} <-
                 query(
                   db,
                   "SELECT expected_revision, admission_revision FROM rule_activations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
                   [actor, epoch, operation]
                 ),
               do: {:ok, receipt},
               else: (
                 {:ok, _} -> {:error, :rule_operation_conflict}
                 error -> error
               )

        {:ok, _} ->
          {:error, :rule_operation_conflict}

        other ->
          other
      end
    end
  end

  @doc "Read an original invocation's generation/source link and current receipt."
  def original_invocation_status(db, credential, epoch, operation, generation, rule_id) do
    with :ok <- input(epoch, operation, generation),
         true <- Id.valid?(rule_id),
         {:ok, principal} <- actor(db, credential, :invoke),
         {:ok, rows} <-
           query(
             db,
             "SELECT admission_revision, rule_id, generation FROM request_rule_origins WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [[admission, ^rule_id, ^generation]] ->
          with :ok <-
                 origin_binding(db, principal, epoch, operation, admission, rule_id, generation),
               {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
               do: RequestLedger.decode_receipt(principal, epoch, operation, row),
               else: (
                 {:ok, _} -> {:error, :corrupt_rule_admission}
                 error -> error
               )

        [_] ->
          {:error, :rule_operation_conflict}

        [] ->
          :not_found

        _ ->
          {:error, :corrupt_rule_admission}
      end
    else
      false -> {:error, :invalid_rule_operation}
      error -> error
    end
  end

  def validate(db) do
    with {:ok, rows} <-
           query(db, "SELECT revision FROM rule_admissions ORDER BY revision LIMIT 1025"),
         true <- length(rows) <= @capacity,
         :ok <-
           each(rows, fn [revision] ->
             case historical_admission(db, revision) do
               {:ok, _} -> :ok
               _ -> {:error, :corrupt_rule_admission}
             end
           end),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM request_rule_origins o
             LEFT JOIN request_receipts r ON r.principal_id=o.principal_id AND r.authority_epoch=o.authority_epoch AND r.operation_id=o.operation_id
             LEFT JOIN rule_admissions a ON a.revision=o.admission_revision
             LEFT JOIN request_journal j ON j.revision=o.receipt_revision
             LEFT JOIN request_causal_roots c USING (principal_id, authority_epoch, operation_id)
           WHERE r.operation_id IS NULL OR a.revision IS NULL OR j.principal_id IS NOT o.principal_id OR
             j.authority_epoch IS NOT o.authority_epoch OR j.operation_id IS NOT o.operation_id OR
             c.rule_admission_revision IS NOT o.admission_revision OR c.rule_generation IS NOT o.generation OR
             o.receipt_revision != (SELECT MIN(j2.revision) FROM request_journal j2
               WHERE j2.principal_id=o.principal_id AND j2.authority_epoch=o.authority_epoch AND j2.operation_id=o.operation_id) OR
             o.generation<1 OR o.generation>(SELECT value FROM meta WHERE key='rule_generation')
           """),
         {:ok, [[0]]} <-
           query(db, """
           SELECT COUNT(*) FROM request_causal_roots c LEFT JOIN request_rule_origins o
             USING (principal_id, authority_epoch, operation_id)
           WHERE c.rule_admission_revision IS NOT o.admission_revision OR
             c.rule_generation IS NOT o.generation
           """),
         :ok <- validate_origins(db, 0),
         {:ok, activations} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id, expected_revision, admission_revision, previous_generation, generation, revision, final_revision, affected_requests, unknown_outcomes FROM rule_activations ORDER BY revision LIMIT 1025"
           ),
         true <- length(activations) <= @capacity,
         :ok <- each(activations, &validate_activation(db, &1)),
         {:ok, [[admission, generation, epoch]]} <- current_meta(db),
         true <- integer?(admission) and integer?(generation) and is_integer(epoch) and epoch >= 1,
         :ok <- active_link(db, admission, generation, epoch),
         {:ok, [[count]]} <-
           query(db, "SELECT COUNT(*) FROM authority_journal WHERE event_type='rule_admitted'"),
         true <- count == length(rows),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='rule_policy_activated'"
           ),
         true <- count == length(activations) do
      :ok
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp historical_admission(db, revision) do
    with {:ok,
          [
            [
              principal,
              epoch,
              operation,
              expected,
              source,
              artifact,
              digest,
              ^revision,
              "rule_admitted",
              target
            ]
          ]} <-
           query(
             db,
             "SELECT r.*, j.event_type, j.entity_id FROM rule_admissions r LEFT JOIN authority_journal j ON j.revision=r.revision WHERE r.revision=?",
             [revision]
           ),
         true <-
           Id.valid?(principal) and Id.valid?(operation) and integer?(epoch) and epoch >= 1 and
             integer?(expected) and revision == expected + 1,
         true <- AdmissionArtifact.digest(artifact) == digest,
         {:ok, decoded} <- AdmissionArtifact.decode(artifact),
         true <- decoded.source == source and elem(decoded.rule.effect, 0) == target,
         true <-
           Enum.all?(decoded.resources, &(&1["resource_revision"] <= expected)) and
             decoded.invariant["revision"] <= expected do
      {:ok, %{principal: principal, epoch: epoch, artifact: decoded, document: artifact}}
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp validate_origins(db, after_revision) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id, admission_revision, rule_id, generation, receipt_revision FROM request_rule_origins WHERE receipt_revision>? ORDER BY receipt_revision LIMIT 100",
             [after_revision]
           ),
         :ok <-
           each(rows, fn [principal, epoch, operation, admission, rule_id, generation, _] ->
             origin_binding(db, principal, epoch, operation, admission, rule_id, generation)
           end) do
      case rows do
        [] -> :ok
        _ -> validate_origins(db, List.last(List.last(rows)))
      end
    end
  end

  defp current_admission(db, revision) do
    with {:ok, stored} <- historical_admission(db, revision),
         {:ok, [[current_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key='authority_epoch'"),
         :ok <- equal(current_epoch, stored.epoch, :stale_authority_epoch),
         {:ok, permissions} <- Access.active_principal_permissions(db, stored.principal),
         :ok <- permission(permissions, :manage),
         {:ok, artifact} <- AdmissionArtifact.current(stored.document),
         :ok <-
           each(artifact.resources, fn pin ->
             with :ok <- grant(db, stored.principal, pin["thing_id"]),
                  {:ok, thing, resource} <- Access.usable_thing(db, pin["thing_id"]),
                  :ok <- ProfilePins.require_current(db, :rule, thing, resource, revision),
                  {:ok, document} <- Registry.encode_thing(thing),
                  true <- resource == pin["resource_revision"] and document == pin["document"] do
               :ok
             else
               false -> {:error, :rule_basis_changed}
               error -> error
             end
           end),
         {:ok, current_pin} <- invariant_pin(db, elem(artifact.rule.effect, 0)),
         true <- current_pin == artifact.invariant do
      {:ok, artifact, stored.principal}
    else
      false -> {:error, :rule_basis_changed}
      error -> error
    end
  end

  defp activation_basis(_db, _actor, 0), do: :ok

  defp activation_basis(db, actor, admission) do
    with {:ok, artifact, _author} <- current_admission(db, admission),
         :ok <- grant(db, actor, elem(artifact.rule.effect, 0)),
         do: :ok
  end

  defp current_guards(db, target, epoch, clock) do
    with {:ok, boot, ms} <- sample(clock),
         {:ok, :allow} <- InvariantWriter.decision(db, target, {boot, ms}),
         {:ok, nil} <- OverrideWriter.active_override_for_target(db, target, epoch, boot, ms) do
      :ok
    else
      {:ok, :deny} -> {:error, :invariant_unresolved}
      {:ok, :unknown} -> {:error, :invariant_unresolved}
      {:ok, _lease} -> {:error, :operator_override_active}
      error -> error
    end
  end

  defp invariant_pin(db, target) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT revision, artifact_digest FROM invariant_policy_operations WHERE target_id=? ORDER BY revision DESC LIMIT 1",
             [target]
           ) do
      case rows do
        [] ->
          {:ok, %{"target_id" => target, "revision" => 0, "digest" => nil}}

        [[revision, digest]] ->
          {:ok, %{"target_id" => target, "revision" => revision, "digest" => digest}}

        _ ->
          {:error, :corrupt_invariant}
      end
    end
  end

  defp actor(db, credential, mode) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, actor, permissions} <- Access.authenticate(db, hash),
         :ok <- permission(permissions, mode),
         do: {:ok, actor}
  end

  defp permission(permissions, :manage),
    do:
      if(Enum.all?(["rule:manage", "rule:review", "control:ordinary"], &(&1 in permissions)),
        do: :ok,
        else: {:error, :permission_denied}
      )

  defp permission(permissions, :invoke),
    do: if("control:ordinary" in permissions, do: :ok, else: {:error, :permission_denied})

  defp grant(db, actor, target) do
    with {:ok, grants} <- Access.allowed_targets(db, actor) do
      if MapSet.member?(grants, target), do: :ok, else: {:error, :permission_denied}
    end
  end

  defp resource_revision(artifact, target) do
    case artifact.resources do
      [%{"thing_id" => ^target, "resource_revision" => revision}] -> {:ok, revision}
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp current_meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='active_rule_admission'), (SELECT value FROM meta WHERE key='rule_generation'), (SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp compare_meta(db, epoch, expected) do
    with {:ok, [[current_epoch, revision]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='authority_epoch'), (SELECT value FROM meta WHERE key='revision')"
           ),
         :ok <- equal(current_epoch, epoch, :stale_authority_epoch),
         :ok <- equal(revision, expected, :resnapshot_required),
         do: :ok
  end

  defp validate_activation(db, [
         principal,
         epoch,
         operation,
         expected,
         admission,
         previous,
         generation,
         revision,
         final,
         affected,
         unknown
       ]) do
    with true <-
           Id.valid?(principal) and Id.valid?(operation) and integer?(epoch) and epoch >= 1 and
             Enum.all?(
               [expected, admission, previous, generation, revision, final, affected, unknown],
               &integer?/1
             ),
         true <-
           revision == expected + 1 and generation == previous + 1 and final >= revision and
             unknown <= affected and affected <= 1024,
         {:ok, [["rule_policy_activated", "rules:active"]]} <-
           query(db, "SELECT event_type, entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         {:ok, [[current_revision, current_generation]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='rule_generation')"
           ),
         true <- final <= current_revision and generation <= current_generation,
         {:ok, [[^generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_policy_activated', 'rule_generation_fenced') AND revision<=?",
             [revision]
           ),
         :ok <- activation_admission_link(db, admission, epoch, revision) do
      :ok
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp historical_activation(db, principal, epoch, operation) do
    case query(
           db,
           "SELECT * FROM rule_activations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, [row]} -> validate_activation(db, row)
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp activation_admission_link(_db, 0, _epoch, _revision), do: :ok

  defp activation_admission_link(db, admission, epoch, revision) do
    with true <- admission < revision,
         {:ok, %{epoch: ^epoch}} <- historical_admission(db, admission) do
      :ok
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp status_basis(_db, 0), do: {:ok, :inactive, nil}

  defp status_basis(db, admission) do
    case current_admission(db, admission) do
      {:error, reason}
      when reason in [
             :corrupt_rule_admission,
             :corrupt_maintenance,
             :corrupt_invariant,
             :corrupt_enrollment,
             :corrupt_principal
           ] ->
        {:error, reason}

      {:ok, _, _} ->
        {:ok, :active, nil}

      {:error, reason} ->
        {:ok, :suspended, reason}
    end
  end

  defp active_link(db, admission, generation, epoch) do
    with true <- integer?(admission) and integer?(generation),
         {:ok, [[^generation]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('rule_policy_activated', 'rule_generation_fenced')"
           ),
         {:ok, events} <-
           query(
             db,
             "SELECT event_type, entity_id, revision FROM authority_journal WHERE event_type IN ('rule_policy_activated', 'rule_generation_fenced') ORDER BY revision DESC LIMIT 1"
           ) do
      case events do
        [] when admission == 0 and generation == 0 ->
          :ok

        [["rule_generation_fenced", "rules:empty", _]] when admission == 0 ->
          :ok

        [["rule_policy_activated", "rules:active", revision]] ->
          case query(db, "SELECT * FROM rule_activations WHERE revision=?", [revision]) do
            {:ok, [[_, ^epoch, _, _, ^admission, _, ^generation | _] = row]} ->
              validate_activation(db, row)

            _ ->
              {:error, :corrupt_rule_admission}
          end

        _ ->
          {:error, :corrupt_rule_admission}
      end
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp origin_binding(db, principal, epoch, operation, admission, rule_id, generation) do
    with {:ok, stored} <- historical_admission(db, admission),
         true <- stored.artifact.rule.id == rule_id,
         {:ok, [row]} <- RequestLedger.select_request(db, principal, epoch, operation),
         {:ok, receipt} <- RequestLedger.decode_receipt(principal, epoch, operation, row),
         [expected, target, key, kind, a, b | _] = row,
         {:ok, value} <- WotexHome.Durable.Store.ObservationCodec.decode_value(kind, a, b),
         true <- stored.artifact.rule.effect == {target, key, value},
         {:ok, resource} <- resource_revision(stored.artifact, target),
         true <- expected == resource,
         {:ok, [[active_revision]]} <-
           query(
             db,
             "SELECT final_revision FROM rule_activations WHERE generation=? AND admission_revision=? AND authority_epoch=?",
             [generation, admission, epoch]
           ),
         true <- active_revision < receipt.revision do
      :ok
    else
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp capacity(db, table) when table in ["rule_admissions", "rule_activations"] do
    case query(db, "SELECT COUNT(*) FROM " <> table) do
      {:ok, [[count]]} when count < @capacity -> :ok
      {:ok, [[@capacity]]} -> {:error, :rule_capacity}
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp unused_operation(db, table, principal, epoch, operation)
       when table in ["rule_admissions", "rule_activations"] do
    case query(
           db,
           "SELECT revision FROM " <>
             table <> " WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
           [principal, epoch, operation]
         ) do
      {:ok, []} -> :ok
      {:ok, [_]} -> {:error, :rule_operation_conflict}
      _ -> {:error, :corrupt_rule_admission}
    end
  end

  defp source_rule(source) do
    case Codec.decode(source) do
      {:ok, [rule]} -> {:ok, rule}
      _ -> {:error, :unsupported_admission_profile}
    end
  end

  defp policy(fun) do
    case fun.() do
      {:error, reason}
      when reason in [
             :corrupt_rule_admission,
             :corrupt_maintenance,
             :corrupt_invariant,
             :corrupt_value,
             :corrupt_override,
             :corrupt_receipt,
             :corrupt_enrollment,
             :corrupt_principal
           ] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}

      other ->
        other
    end
  end

  defp input(epoch, operation, revision),
    do:
      if(
        integer?(epoch) and epoch >= 1 and Id.valid?(operation) and integer?(revision) and
          revision < @max_i64,
        do: :ok,
        else: {:error, :invalid_rule_operation}
      )

  defp integer?(value), do: is_integer(value) and value in 0..@max_i64
  defp equal(a, a, _reason), do: :ok
  defp equal(_a, _b, reason), do: {:error, reason}
  defp sample(clock) when is_function(clock, 0), do: sample(clock.())

  defp sample({epoch, ms}),
    do:
      if(Id.valid?(epoch) and integer?(ms),
        do: {:ok, epoch, ms},
        else: {:error, :corrupt_rule_admission}
      )

  defp sample(_clock), do: {:error, :corrupt_rule_admission}

  defp each(items, fun),
    do:
      Enum.reduce_while(items, :ok, fn item, :ok ->
        case fun.(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp admission_receipt(actor, epoch, operation, revision, digest),
    do: %{
      principal_id: actor,
      authority_epoch: epoch,
      operation_id: operation,
      revision: revision,
      artifact_digest: digest,
      profile: "home-explicit-light-admission-v1",
      state: :admitted
    }

  defp activation_receipt(admission, previous, generation, revision, final, affected, unknown),
    do: %{
      admission_revision: admission,
      previous_generation: previous,
      rule_generation: generation,
      revision: revision,
      store_revision: final,
      affected_requests: affected,
      unknown_outcomes: unknown,
      state: if(admission == 0, do: :inactive, else: :active)
    }
end
