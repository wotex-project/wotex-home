defmodule WotexHome.Durable.Store.InvariantWriter do
  @moduledoc """
  Store-owned durable constraints and current direct-power guard consumption.

  This borrowed-handle domain owns no process, clock, transport or credentials.
  The latest immutable operation for a target is its constraint; history is not
  pruned. Replacements require explicit policy authority and revision CAS. A
  revoked author, changed declaration or missing current fact fails closed.
  These are reported-fact restrictions, not physical safety certification.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, FactReadModel, Journal, RequestInvalidator}
  alias WotexHome.Id
  alias WotexHome.Policy.InvariantArtifact
  alias WotexHome.Rules.Compiler
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @max_i64 9_223_372_036_854_775_807
  @capacity 1_024
  @select """
  SELECT i.principal_id, i.authority_epoch, i.operation_id, i.expected_revision,
    i.target_id, i.previous_revision, i.source_document, i.artifact_document,
    i.artifact_digest, i.revision, a.event_type, a.entity_id, a.revision,
    p.principal_id, t.thing_id
  FROM invariant_policy_operations i
    LEFT JOIN authority_journal a ON a.revision=i.revision
    LEFT JOIN principals p ON p.principal_id=i.principal_id
    LEFT JOIN enrolled_things t ON t.thing_id=i.target_id
  """

  def set(db, credential, epoch, operation, expected, target, previous, source) do
    result =
      with :ok <- inputs(epoch, operation, expected, target, previous, source),
           {:ok, principal} <- manager(db, credential),
           {:ok, rows} <-
             query(
               db,
               @select <> " WHERE i.principal_id=? AND i.authority_epoch=? AND i.operation_id=?",
               [principal, epoch, operation]
             ) do
        case rows do
          [row] ->
            with :ok <- same_content(row, expected, target, previous, source),
                 {:ok, receipt, _artifact, _program} <- decode_row(row) do
              {:rollback, {:unchanged, {:ok, receipt}}}
            end

          [] ->
            install(db, principal, epoch, operation, expected, target, previous, source)

          _ ->
            {:error, :corrupt_invariant}
        end
      end

    case result do
      {:error, reason}
      when reason in [
             :invalid_invariant_operation,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :stale_authority_epoch,
             :resnapshot_required,
             :invariant_revision_changed,
             :invariant_operation_conflict,
             :invariant_capacity,
             :target_unavailable,
             :invalid_invariant_artifact
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      other ->
        other
    end
  end

  def status(db, credential, epoch, operation) do
    with true <- integer?(epoch) and epoch >= 1 and Id.valid?(operation),
         {:ok, principal} <- manager(db, credential),
         {:ok, rows} <-
           query(
             db,
             @select <> " WHERE i.principal_id=? AND i.authority_epoch=? AND i.operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [row] ->
          with {:ok, receipt, _artifact, _program} <- decode_row(row), do: {:ok, receipt}

        [] ->
          {:error, :invariant_not_found}

        _ ->
          {:error, :corrupt_invariant}
      end
    else
      false -> {:error, :invalid_invariant_operation}
      error -> error
    end
  end

  @doc "Only Store may supply the current receipt clock and consume this result."
  def decision(db, target, {epoch, ms}), do: decision(db, target, fn -> {epoch, ms} end)

  def decision(db, target, clock) when is_function(clock, 0) do
    with true <- Id.valid?(target),
         :ok <- target_history_link(db, target),
         {:ok, rows} <-
           query(db, @select <> " WHERE i.target_id=? ORDER BY i.revision DESC LIMIT 1", [target]) do
      case rows do
        [] ->
          {:ok, :allow}

        [row] ->
          with {:ok, receipt, artifact, program} <- decode_row(row),
               :ok <- current_basis(db, receipt.principal_id, artifact),
               {:ok, epoch, ms} <- sample(clock),
               {:ok, projection} <- FactReadModel.project(db, program.facts, epoch, ms),
               {:ok, truth} <- Compiler.evaluate(program.instructions, projection.facts) do
            {:ok, %{true => :allow, false => :deny, :unknown => :unknown}[truth]}
          else
            {:error, reason}
            when reason in [
                   :principal_unavailable,
                   :permission_denied,
                   :target_unavailable,
                   :invariant_basis_changed
                 ] ->
              {:ok, :unknown}

            error ->
              error
          end

        _ ->
          {:error, :corrupt_invariant}
      end
    else
      false -> {:error, :corrupt_invariant}
      error -> error
    end
  end

  def decision(_db, _target, _clock), do: {:error, :corrupt_invariant}

  @doc "Historical semantics and both directions of journal links; no requalification."
  def validate(db) do
    with {:ok, rows} <- query(db, @select <> " ORDER BY i.revision LIMIT 1025"),
         true <- length(rows) <= @capacity,
         {:ok, [[journal_count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='invariant_policy_set'"
           ),
         true <- journal_count == length(rows),
         {:ok, [[store_revision, store_epoch]]} <- meta(db),
         {:ok, _last} <-
           Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, last} ->
             case decode_row(row) do
               {:ok, receipt, _artifact, _program} ->
                 if receipt.revision <= store_revision and receipt.authority_epoch <= store_epoch and
                      receipt.previous_revision == Map.get(last, receipt.target_id, 0) do
                   {:cont, {:ok, Map.put(last, receipt.target_id, receipt.revision)}}
                 else
                   {:halt, {:error, :corrupt_invariant}}
                 end

               _ ->
                 {:halt, {:error, :corrupt_invariant}}
             end
           end) do
      :ok
    else
      _ -> {:error, :corrupt_invariant}
    end
  end

  defp install(db, principal, epoch, operation, expected, target, previous, source) do
    with :ok <- capacity(db),
         {:ok, [[revision, current_epoch]]} <- meta(db),
         :ok <- equal(epoch, current_epoch, :stale_authority_epoch),
         :ok <- equal(expected, revision, :resnapshot_required),
         :ok <- target_history_link(db, target),
         {:ok, [[current_previous]]} <-
           query(
             db,
             "SELECT COALESCE(MAX(revision), 0) FROM invariant_policy_operations WHERE target_id=?",
             [target]
           ),
         :ok <- equal(previous, current_previous, :invariant_revision_changed),
         {:ok, program} <- Compiler.compile_predicate(source),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         ids = InvariantArtifact.required_ids(target, program),
         true <- Enum.all?(ids, &MapSet.member?(grants, &1)),
         {:ok, resources} <- resources(db, ids),
         {:ok, document} <- InvariantArtifact.create(target, source, resources),
         {:ok, next} <- Journal.next_revision(db),
         digest = InvariantArtifact.digest(document),
         :ok <- Journal.authority_event(db, next, "invariant_policy_set", target),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO invariant_policy_operations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
             [
               principal,
               epoch,
               operation,
               expected,
               target,
               previous,
               source,
               document,
               digest,
               next
             ]
           ),
         {:ok, held} <- RequestInvalidator.held_for_thing(db, target),
         :ok <- RequestInvalidator.reject_held_batch(db, held, "invariant_policy_changed"),
         :ok <-
           RequestInvalidator.invalidate_execution_for(
             db,
             {:thing, target},
             "invariant_policy_changed"
           ),
         {:ok, [row]} <- query(db, @select <> " WHERE i.revision=?", [next]),
         {:ok, receipt, _artifact, _program} <- decode_row(row) do
      {:commit, {:ok, receipt}}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp resources(db, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, thing, revision} <- Access.enrolled_thing(db, id),
           {:ok, document} <- Registry.encode_thing(thing) do
        {:cont,
         {:ok,
          acc ++ [%{"thing_id" => id, "resource_revision" => revision, "document" => document}]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp current_basis(db, principal, artifact) do
    with {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         :ok <- permission(permissions),
         {:ok, grants} <- Access.allowed_targets(db, principal) do
      Enum.reduce_while(artifact["resources"], :ok, fn pin, :ok ->
        with true <- MapSet.member?(grants, pin["thing_id"]),
             {:ok, thing, revision} <- Access.enrolled_thing(db, pin["thing_id"]),
             {:ok, document} <- Registry.encode_thing(thing),
             true <- revision == pin["resource_revision"] and document == pin["document"] do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :invariant_basis_changed}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp decode_row([
         principal,
         epoch,
         operation,
         expected,
         target,
         previous,
         source,
         document,
         digest,
         revision,
         "invariant_policy_set",
         target,
         revision,
         principal,
         target
       ]) do
    with true <- Id.valid?(principal) and Id.valid?(operation) and Id.valid?(target),
         true <- integer?(epoch) and epoch >= 1 and integer?(expected) and expected < @max_i64,
         true <- integer?(revision) and revision == expected + 1,
         true <- integer?(previous) and previous <= expected,
         true <- is_binary(document) and InvariantArtifact.digest(document) == digest,
         {:ok, artifact, program} <- InvariantArtifact.decode(document),
         true <- artifact["target_id"] == target and artifact["source_document"] == source,
         true <- Enum.all?(artifact["resources"], &(&1["resource_revision"] <= expected)) do
      {:ok,
       %{
         principal_id: principal,
         authority_epoch: epoch,
         operation_id: operation,
         expected_revision: expected,
         target_id: target,
         previous_revision: previous,
         revision: revision,
         artifact_digest: digest,
         profile: artifact["profile"],
         scope: :reported_constraint_only,
         source_digest: program.source_digest,
         ir_digest: program.ir_digest
       }, artifact, program}
    else
      _ -> {:error, :corrupt_invariant}
    end
  end

  defp decode_row(_row), do: {:error, :corrupt_invariant}

  defp same_content(
         [_, _, _, expected, target, previous, source | _],
         expected,
         target,
         previous,
         source
       ),
       do: :ok

  defp same_content(_row, _expected, _target, _previous, _source),
    do: {:error, :invariant_operation_conflict}

  defp manager(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         :ok <- permission(permissions),
         do: {:ok, principal}
  end

  defp permission(permissions),
    do:
      if("policy:manage" in permissions and "read" in permissions,
        do: :ok,
        else: {:error, :permission_denied}
      )

  defp target_history_link(db, target) do
    with {:ok, [[rows, journal]]} <-
           query(
             db,
             "SELECT (SELECT COUNT(*) FROM invariant_policy_operations WHERE target_id=?), (SELECT COUNT(*) FROM authority_journal WHERE event_type='invariant_policy_set' AND entity_id=?)",
             [target, target]
           ),
         true <- rows == journal and rows in 0..@capacity do
      :ok
    else
      _ -> {:error, :corrupt_invariant}
    end
  end

  defp capacity(db) do
    case query(db, "SELECT COUNT(*) FROM invariant_policy_operations") do
      {:ok, [[count]]} when count >= 0 and count < @capacity -> :ok
      {:ok, [[@capacity]]} -> {:error, :invariant_capacity}
      _ -> {:error, :corrupt_invariant}
    end
  end

  defp inputs(epoch, operation, expected, target, previous, source) do
    with true <- integer?(epoch) and epoch >= 1 and Id.valid?(operation) and Id.valid?(target),
         true <- integer?(expected) and expected < @max_i64 and integer?(previous),
         {:ok, _program} <- Compiler.compile_predicate(source) do
      :ok
    else
      _ -> {:error, :invalid_invariant_operation}
    end
  end

  defp integer?(value), do: is_integer(value) and value in 0..@max_i64

  defp sample(clock) do
    case clock.() do
      {epoch, ms} ->
        if(Id.valid?(epoch) and integer?(ms),
          do: {:ok, epoch, ms},
          else: {:error, :corrupt_invariant}
        )

      _ ->
        {:error, :corrupt_invariant}
    end
  end

  defp equal(value, value, _reason), do: :ok
  defp equal(_value, _other, reason), do: {:error, reason}

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch')"
      )
end
