defmodule WotexHome.Durable.Store.ScheduleWriter do
  @moduledoc "Store-owned immutable temporal review/admission content. No activation, timer, device I/O or clock qualification."
  alias WotexHome.{Id, Schedules.Codec}
  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, Journal, MaintenanceWriter, ProfilePins}
  alias WotexHome.Schedules.{AdmissionArtifact, OperationInput}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @fields ~w(principal_id authority_epoch operation_id kind expected_revision input_document artifact_document artifact_digest revision)
  @columns Enum.join(@fields, ",")
  @capacity 1_024
  @byte_limit 8_388_608
  @permissions ~w(rule:review rule:manage control:ordinary)
  @corrupt ~w(corrupt_schedule_admission corrupt_maintenance corrupt_invariant corrupt_value corrupt_override corrupt_receipt corrupt_enrollment corrupt_principal corrupt_native_setup corrupt_native_target_history corrupt_profile_ledger corrupt_qualification_history)a
  def columns, do: @columns

  def authorize(db, credential) do
    with {:ok, principal} <- actor(db, credential, :manage),
         :ok <- validate(db),
         {:ok, [[epoch, revision]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='authority_epoch'), (SELECT value FROM meta WHERE key='revision')"
           ),
         do: {:ok, %{principal_id: principal, authority_epoch: epoch, store_revision: revision}}
  end

  def retain(db, credential, input_document, zone) do
    policy(fn ->
      with {:ok, kind, input} when kind in ["review", "admit"] <-
             OperationInput.decode(input_document),
           {:ok, actor} <- actor(db, credential, :manage),
           :ok <- validate(db),
           {:ok, rows} <- original(db, actor, input["authority_epoch"], input["operation_id"]) do
        case rows do
          [row] ->
            with {:ok, retained} <- historical(db, row),
                 true <- retained.input_document == input_document,
                 do: {:rollback, {:unchanged, {:ok, receipt(retained)}}},
                 else: (
                   false -> {:error, :schedule_operation_conflict}
                   error -> error
                 )

          [] ->
            with :ok <- MaintenanceWriter.guard(db),
                 :ok <- compare(db, input),
                 {:ok, source, _rule} <- OperationInput.source(kind, input),
                 true <- source["author_id"] == actor,
                 :ok <- supported_clock_source(source),
                 :ok <- grant(db, actor, source["target_id"]),
                 {:ok, thing, resource} <- Access.usable_thing(db, source["target_id"]),
                 true <- resource == source["resource_revision"],
                 {:ok, pin} <- ProfilePins.capture(db, thing, resource),
                 {:ok, declaration} <- Registry.encode_thing(thing),
                 {:ok, invariant} <- invariant_pin(db, thing.id),
                 {:ok, artifact} <-
                   AdmissionArtifact.build(
                     input["source_document"],
                     input["rule_document"],
                     [
                       %{
                         "thing_id" => thing.id,
                         "resource_revision" => resource,
                         "document" => declaration
                       }
                     ],
                     invariant,
                     pin,
                     zone
                   ),
                 :ok <- capacity(db, byte_size(artifact) + byte_size(input_document)),
                 {:ok, revision} <- Journal.next_revision(db),
                 :ok <-
                   Journal.authority_event(
                     db,
                     revision,
                     event(kind),
                     entity(actor, input["authority_epoch"], input["operation_id"])
                   ),
                 values = [
                   actor,
                   input["authority_epoch"],
                   input["operation_id"],
                   kind,
                   input["expected_revision"],
                   input_document,
                   artifact,
                   AdmissionArtifact.digest(artifact),
                   revision
                 ],
                 {:ok, []} <-
                   query(db, "INSERT INTO schedule_admissions VALUES (?,?,?,?,?,?,?,?,?)", values),
                 {:ok, retained} <- historical(db, values) do
              {:commit, {:ok, receipt(retained)}}
            else
              false -> {:error, :schedule_basis_changed}
              error -> error
            end

          _ ->
            corrupt()
        end
      else
        {:ok, _, _} -> {:error, :unsupported_schedule_operation}
        error -> error
      end
    end)
  end

  def original_status(db, credential, input_document) do
    with {:ok, kind, input} when kind in ["review", "admit"] <-
           OperationInput.decode(input_document),
         {:ok, actor} <- actor(db, credential, :read),
         :ok <- validate(db),
         {:ok, rows} <- original(db, actor, input["authority_epoch"], input["operation_id"]) do
      case rows do
        [] ->
          :not_found

        [row] ->
          with {:ok, retained} <- historical(db, row),
               true <- retained.input_document == input_document,
               do: {:ok, receipt(retained)},
               else: (
                 false -> {:error, :schedule_operation_conflict}
                 error -> error
               )

        _ ->
          corrupt()
      end
    else
      {:ok, _, _} -> {:error, :unsupported_schedule_operation}
      error -> error
    end
  end

  @doc "Current original author, exact declaration/profile/invariant and runtime; neither activation nor time authority."
  def current_admission(db, revision) do
    with true <- Codec.integer?(revision, 1, Codec.maximum()),
         {:ok, row} <- current_row(db, revision),
         {:ok, retained} <- historical(db, row),
         true <- retained.kind == "admit",
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key='authority_epoch'"),
         true <- epoch == retained.epoch,
         {:ok, permissions} <- Access.active_principal_permissions(db, retained.principal),
         :ok <- permission(permissions, :manage),
         {:ok, artifact} <- AdmissionArtifact.current(retained.artifact_document),
         target = artifact.source["target_id"],
         :ok <- grant(db, retained.principal, target),
         {:ok, thing, resource} <- Access.usable_thing(db, target),
         {:ok, declaration} <- Registry.encode_thing(thing),
         true <-
           [%{"thing_id" => target, "resource_revision" => resource, "document" => declaration}] ==
             artifact.resources,
         {:ok, profile} <- ProfilePins.capture(db, thing, resource),
         true <- profile == artifact.profile_pin,
         {:ok, invariant} <- invariant_pin(db, target),
         true <- invariant == artifact.invariant,
         do: {:ok, artifact, retained.principal},
         else: (
           {:ok, _} -> corrupt()
           false -> {:error, :schedule_basis_changed}
           error -> error
         )
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[24]]} -> validate(db)
      {:ok, [[version]]} when version in 1..23 -> :ok
      _ -> corrupt()
    end
  end

  defp current_row(db, revision) do
    case query(db, "SELECT #{@columns} FROM schedule_admissions WHERE revision=?", [revision]) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :schedule_admission_not_found}
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, rows} <-
           query(db, "SELECT #{@columns} FROM schedule_admissions ORDER BY revision LIMIT 1025"),
         true <- length(rows) <= @capacity,
         true <-
           Enum.reduce(rows, 0, fn row, total ->
             total + byte_size(Enum.at(row, 5)) + byte_size(Enum.at(row, 6))
           end) <= @byte_limit,
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type IN ('schedule_reviewed','schedule_admitted')"
           ),
         true <- count == length(rows),
         true <- Enum.all?(rows, &match?({:ok, _}, historical(db, &1))),
         do: :ok,
         else: (_ -> corrupt())
  rescue
    _ -> corrupt()
  end

  defp historical(db, [
         principal,
         epoch,
         operation,
         kind,
         expected,
         input_document,
         artifact_document,
         digest,
         revision
       ]) do
    with true <- Id.valid?(principal) and Id.valid?(operation),
         true <-
           Codec.integer?(epoch, 1, Codec.maximum()) and
             Codec.integer?(expected, 0, Codec.maximum() - 1),
         true <- revision == expected + 1,
         {:ok, ^kind, input} <- OperationInput.decode(input_document),
         true <- kind in ["review", "admit"],
         true <-
           {epoch, operation, expected} ==
             {input["authority_epoch"], input["operation_id"], input["expected_revision"]},
         true <- AdmissionArtifact.digest(artifact_document) == digest,
         {:ok, artifact} <- AdmissionArtifact.decode(artifact_document),
         true <-
           artifact.source["author_id"] == principal and
             artifact.source_document == input["source_document"] and
             artifact.rule_document == input["rule_document"],
         true <-
           artifact.source["resource_revision"] <= expected and
             artifact.invariant["revision"] <= expected,
         true <-
           artifact.profile_pin == nil or
             Enum.all?(
               ~w(selection_revision trust_revision resource_revision),
               &(artifact.profile_pin[&1] <= expected)
             ),
         {:ok, [[event, entity]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             revision
           ]),
         true <- event == event(kind) and entity == entity(principal, epoch, operation),
         {:ok, [[current_revision, current_epoch, 1]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch'), (SELECT COUNT(*) FROM principals WHERE principal_id=?)",
             [principal]
           ),
         true <- revision <= current_revision and epoch <= current_epoch do
      {:ok,
       %{
         principal: principal,
         epoch: epoch,
         operation: operation,
         kind: kind,
         expected: expected,
         input_document: input_document,
         artifact_document: artifact_document,
         artifact_digest: digest,
         revision: revision
       }}
    else
      _ -> corrupt()
    end
  end

  defp historical(_, _), do: corrupt()

  defp receipt(retained),
    do: %{
      kind: retained.kind,
      state: if(retained.kind == "admit", do: :admitted, else: :reviewed),
      principal_id: retained.principal,
      authority_epoch: retained.epoch,
      operation_id: retained.operation,
      input_digest: Codec.hash(retained.input_document),
      artifact_digest: retained.artifact_digest,
      revision: retained.revision
    }

  defp original(db, principal, epoch, operation),
    do:
      query(
        db,
        "SELECT #{@columns} FROM schedule_admissions WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
        [principal, epoch, operation]
      )

  defp compare(db, input) do
    with {:ok, [[epoch, revision]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='authority_epoch'), (SELECT value FROM meta WHERE key='revision')"
           ) do
      cond do
        epoch != input["authority_epoch"] -> {:error, :stale_authority_epoch}
        revision != input["expected_revision"] -> {:error, :resnapshot_required}
        true -> :ok
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
      if(Enum.all?(@permissions, &(&1 in permissions)),
        do: :ok,
        else: {:error, :permission_denied}
      )

  defp permission(permissions, :read),
    do: if("rule:review" in permissions, do: :ok, else: {:error, :permission_denied})

  defp grant(db, actor, target) do
    with {:ok, targets} <- Access.allowed_targets(db, actor),
         do: if(MapSet.member?(targets, target), do: :ok, else: {:error, :permission_denied})
  end

  defp invariant_pin(db, target) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT revision,artifact_digest FROM invariant_policy_operations WHERE target_id=? ORDER BY revision DESC LIMIT 1",
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

  defp capacity(db, extra) do
    with {:ok, [[count, bytes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))+length(CAST(artifact_document AS BLOB))),0) FROM schedule_admissions"
           ) do
      if count < @capacity and bytes + extra <= @byte_limit,
        do: :ok,
        else: {:error, :schedule_admission_capacity}
    end
  end

  defp supported_clock_source(%{"trigger" => ["countdown" | _]}),
    do: {:error, :temporal_clock_unavailable}

  defp supported_clock_source(_), do: :ok
  defp event("review"), do: "schedule_reviewed"
  defp event("admit"), do: "schedule_admitted"
  defp entity(principal, epoch, operation), do: "#{principal}/#{epoch}/#{operation}"
  defp corrupt, do: {:error, :corrupt_schedule_admission}

  defp policy(fun) do
    case fun.() do
      {:error, reason} when reason in @corrupt ->
        {:rollback, reason}

      {:error, reason} when is_atom(reason) ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      other ->
        other
    end
  end
end
