defmodule WotexHome.Durable.Store.AuthoringObjects do
  @moduledoc "Stateless immutable actor-owned authoring-object and original-receipt journal."

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{Access, Journal, MaintenanceWriter}
  alias WotexHome.Profiles.{AuthoringImport, AuthoringObject}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @objects "principal_id,object_digest,kind,payload_sha256,payload_bytes,first_revision"
  @operations "principal_id,authority_epoch,operation_id,input_document,receipt_document,revision"

  def object_columns, do: @objects
  def operation_columns, do: @operations

  def prepare(db, credential, document) do
    with {:ok, input} <- AuthoringImport.decode(document),
         {:ok, principal} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_authoring_object_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[^document, receipt]] ->
          with {:ok, value} <- AuthoringImport.decode_receipt(receipt),
               do: {:ok, :existing, value}

        [_] ->
          {:error, :authoring_operation_conflict}

        _ ->
          corrupt()
      end
    end
  end

  def import_tx(db, credential, document, object) do
    result =
      with {:ok, :new, principal, input} <- prepare(db, credential, document),
           {:ok, summary} <- AuthoringObject.summary(object),
           true <- summary == input["object"],
           {:ok, [[revision, epoch]]} <-
             query(
               db,
               "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
             ),
           :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
           :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
           :ok <- MaintenanceWriter.guard(db),
           :ok <- capacity(db, summary),
           {:ok, next} <- Journal.next_revision(db),
           {:ok, first} <- ownership(db, principal, summary, next),
           receipt = AuthoringImport.receipt(input, first, next),
           {:ok, receipt_document} <- AuthoringImport.encode_receipt(receipt),
           :ok <-
             Journal.authority_event(db, next, "authoring_object_imported", input["operation_id"]),
           {:ok, []} <-
             query(
               db,
               "INSERT INTO profile_authoring_object_operations (#{@operations}) VALUES (?,?,?,?,?,?)",
               [principal, epoch, input["operation_id"], document, receipt_document, next]
             ),
           :ok <- validate(db) do
        {:commit, {:ok, receipt}}
      else
        {:ok, :existing, receipt} ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        false ->
          {:rollback, {:policy, :invalid_authoring_import}}

        {:error, reason}
        when reason in [
               :unauthorized,
               :invalid_credential,
               :permission_denied,
               :authoring_operation_conflict,
               :stale_authority_epoch,
               :resnapshot_required,
               :maintenance_active,
               :authoring_object_capacity,
               :invalid_authoring_import,
               :revision_exhausted
             ] ->
          {:rollback, {:policy, reason}}

        {:error, reason} ->
          {:rollback, reason}
      end

    result
  end

  def current_basis(db, input) do
    with {:ok, [[revision, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
         :ok <- MaintenanceWriter.guard(db),
         do: capacity(db, input["object"])
  end

  def status(db, credential, epoch, operation) do
    with true <-
           is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807 and
             WotexHome.Id.valid?(operation),
         {:ok, principal} <- actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_authoring_object_operations WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[document]] -> AuthoringImport.decode_receipt(document)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_authoring_import}
      error -> error
    end
  end

  def retained(db) do
    with :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT DISTINCT object_digest,kind,payload_sha256,payload_bytes FROM profile_authoring_objects ORDER BY object_digest"
           ) do
      {:ok,
       Enum.map(rows, fn [digest, kind, payload, size] ->
         %{
           "object_digest" => digest,
           "kind" => kind,
           "payload_sha256" => payload,
           "payload_bytes" => size
         }
       end)}
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[29]]} -> validate(db)
      {:ok, [[version]]} when version in 4..28 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{@objects} FROM profile_authoring_objects ORDER BY first_revision LIMIT 1025"
           ),
         {:ok, operations} <-
           query(
             db,
             "SELECT #{@operations} FROM profile_authoring_object_operations ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1024 and length(operations) <= 1024,
         {:ok, [[revision, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         true <- is_integer(revision) and revision >= 0 and is_integer(epoch) and epoch > 0,
         {:ok, table} <- validate_operations(db, operations, revision, epoch),
         :ok <- validate_objects(rows, table),
         {:ok, [[journal_count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_object_imported'"
           ),
         true <- journal_count == length(operations),
         :ok <- aggregate(rows),
         :ok <- combined_capacity(db, rows) do
      :ok
    else
      _ -> corrupt()
    end
  end

  defp validate_operations(db, rows, maximum, epoch) do
    Enum.reduce_while(rows, {:ok, %{}}, fn [
                                             principal,
                                             original_epoch,
                                             operation,
                                             input,
                                             receipt,
                                             revision
                                           ],
                                           {:ok, table} ->
      with true <-
             WotexHome.Id.valid?(principal) and original_epoch in 1..epoch and
               revision in 1..maximum,
           {:ok, data} <- AuthoringImport.decode(input),
           {:ok, value} <- AuthoringImport.decode_receipt(receipt),
           true <-
             data["authority_epoch"] == original_epoch and data["operation_id"] == operation and
               data["expected_revision"] == revision - 1 and
               value == AuthoringImport.receipt(data, value["first_revision"], revision),
           {:ok, [["authoring_object_imported", ^operation]]} <-
             query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
               revision
             ]),
           {:ok, [[^principal]]} <-
             query(db, "SELECT principal_id FROM principals WHERE principal_id=?", [principal]) do
        {:cont, {:ok, Map.put(table, revision, {principal, value})}}
      else
        _ -> {:halt, corrupt()}
      end
    end)
  end

  defp validate_objects(rows, operations) do
    objects =
      Map.new(rows, fn [principal, digest, kind, payload, size, first] ->
        {{principal, digest}, {summary(digest, kind, payload, size), first}}
      end)

    valid_rows =
      Enum.all?(objects, fn {{principal, _}, {summary, first}} ->
        case operations[first] do
          {^principal, receipt} ->
            AuthoringObject.valid_summary?(summary) and receipt["object"] == summary and
              receipt["first_revision"] == first

          _ ->
            false
        end
      end)

    valid_operations =
      Enum.all?(operations, fn {revision, {principal, receipt}} ->
        case objects[{principal, receipt["object"]["object_digest"]}] do
          {summary, first} ->
            receipt["object"] == summary and receipt["first_revision"] == first and
              first <= revision

          _ ->
            false
        end
      end)

    if valid_rows and valid_operations and map_size(objects) == length(rows),
      do: :ok,
      else: corrupt()
  end

  defp aggregate(rows) do
    summaries =
      Enum.map(rows, fn [_, digest, kind, payload, size, _] ->
        summary(digest, kind, payload, size)
      end)

    unique = Enum.uniq_by(summaries, & &1["object_digest"])

    if length(unique) <= 128 and length(Enum.uniq(summaries)) == length(unique) and
         Enum.reduce(unique, 0, &(&1["payload_bytes"] + 42 + &2)) <= 4_194_304,
       do: :ok,
       else: corrupt()
  end

  defp capacity(db, summary) do
    with {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM profile_authoring_object_operations"),
         true <- count < 1024,
         {:ok, rows} <-
           query(
             db,
             "SELECT DISTINCT object_digest,kind,payload_sha256,payload_bytes FROM profile_authoring_objects"
           ) do
      candidate = [
        nil,
        summary["object_digest"],
        summary["kind"],
        summary["payload_sha256"],
        summary["payload_bytes"],
        0
      ]

      prior = Enum.map(rows, fn row -> [nil | row] ++ [0] end)

      case with :ok <- aggregate([candidate | prior]),
                do: combined_capacity(db, [candidate | prior]) do
        :ok -> :ok
        _ -> {:error, :authoring_object_capacity}
      end
    else
      false -> {:error, :authoring_object_capacity}
      error -> error
    end
  end

  defp ownership(db, principal, summary, revision) do
    digest = summary["object_digest"]

    case query(
           db,
           "SELECT kind,payload_sha256,payload_bytes,first_revision FROM profile_authoring_objects WHERE principal_id=? AND object_digest=?",
           [principal, digest]
         ) do
      {:ok, []} ->
        with {:ok, []} <-
               query(
                 db,
                 "INSERT INTO profile_authoring_objects (#{@objects}) VALUES (?,?,?,?,?,?)",
                 [
                   principal,
                   digest,
                   summary["kind"],
                   summary["payload_sha256"],
                   summary["payload_bytes"],
                   revision
                 ]
               ),
             do: {:ok, revision}

      {:ok, [[kind, payload, size, first]]} ->
        if summary == summary(digest, kind, payload, size), do: {:ok, first}, else: corrupt()

      _ ->
        corrupt()
    end
  end

  defp combined_capacity(db, rows) do
    with {:ok, profiles} <- query(db, "SELECT artifact_digest FROM portable_profiles LIMIT 65") do
      ids =
        Enum.map(rows, fn [_, digest | _] -> digest end) ++
          Enum.map(profiles, fn [digest] -> digest end)

      if length(Enum.uniq(ids)) <= 128, do: :ok, else: corrupt()
    end
  end

  defp actor(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- "profile:manage" in permissions do
      {:ok, principal}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp summary(digest, kind, payload, size),
    do: %{
      "object_digest" => digest,
      "kind" => kind,
      "payload_sha256" => payload,
      "payload_bytes" => size
    }

  defp equal(value, value, _), do: :ok
  defp equal(_, _, reason), do: {:error, reason}
  defp corrupt, do: {:error, :corrupt_authoring_objects}
end
