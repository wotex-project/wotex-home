defmodule WotexHome.Durable.Store.GenerationAttempts do
  @moduledoc """
  Journals original provider reservations and atomic inert candidate settlement.

  Store supplies its borrowed SQLite connection, authenticated operation and
  actual boot/monotonic coordinates. Exact originals resolve before current
  export checks. New reservations require current epoch/revision, owned live
  preparation, contiguous bounded attempts and capacity. Only an explicitly
  selected invalid predecessor can supply repair feedback.

  Settlement imports exact generated draft/bundle metadata through the existing
  authoring writer and records one immutable result in the same transaction.
  Historical integrity needs no provider, producer or private file. This module
  opens no connection, invokes no model and creates no review or control authority.
  """

  alias WotexHome.Durable.Store.{
    AuthoringObjects,
    GenerationPreparations,
    Journal,
    MaintenanceWriter,
    ProfileWriter
  }

  alias WotexHome.Profiles.{
    AuthoringImport,
    AuthoringObject,
    AuthoringProducer,
    EnvelopeCodec,
    GenerationAttempt
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "principal_id,authority_epoch,operation_id,input_document,preparation_operation_id,attempt,handoff_sha256,receipt_document,boot_epoch,started_ms,expires_ms,revision,result_document,result_revision"
  @maximum 9_223_372_036_854_775_807
  @policy ~w(unauthorized invalid_credential permission_denied authoring_operation_conflict
    stale_authority_epoch resnapshot_required maintenance_active stale_authoring_reference
    invalid_generation_attempt generation_attempt_unavailable generation_busy generation_attempt_capacity
    generation_deadline_expired generation_cancelled generation_retired authoring_object_capacity
    invalid_authoring_import revision_exhausted)a

  def columns, do: @columns

  def prepare(db, credential, document) do
    with {:ok, input} <- GenerationAttempt.decode(document),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_authoring_generation_attempts WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [[^document, receipt]] ->
          with {:ok, value} <- GenerationAttempt.decode_receipt(receipt),
               do: {:ok, :existing, value}

        [_] ->
          {:error, :authoring_operation_conflict}

        [] ->
          with {:ok, [[_, epoch]]} <- meta(db),
               :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
               {:ok, root} <-
                 GenerationPreparations.original(
                   db,
                   principal,
                   input["authority_epoch"],
                   input["preparation_operation_id"]
                 ),
               :ok <-
                 equal(
                   root["receipt"]["input_sha256"],
                   input["preparation_sha256"],
                   :stale_authoring_reference
                 ),
               do: {:ok, :new, principal, input, root}

        _ ->
          corrupt()
      end
    end
  end

  def current_basis(db, principal, input, root, boot, now) do
    with {:ok, [[revision, epoch]]} <- meta(db),
         :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
         :ok <- live_root(root, boot, now),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, rows} <-
           root_attempts(
             db,
             principal,
             input["authority_epoch"],
             input["preparation_operation_id"]
           ),
         :ok <- predecessor(rows, input, root),
         {:ok, document} <- GenerationAttempt.encode(input),
         :ok <- capacity(db, byte_size(document), 1024, true),
         :ok <- active_capacity(db, principal, boot, now),
         {:ok, records} <- GenerationPreparations.owned_references(db, principal, root["input"]),
         do: {:ok, records, List.last(rows)}
  end

  def reserve_tx(db, credential, document, handoff, boot, started, now) do
    result =
      with {:ok, :new, principal, input, root} <- prepare(db, credential, document),
           {:ok, _, _} <- current_basis(db, principal, input, root, boot, now),
           true <-
             int?(started) and started >= root["created_ms"] and started <= now and
               EnvelopeCodec.digest?(handoff),
           expiry = min(root["expires_ms"], started + root["input"]["budget"]["attempt_ms"]),
           :ok <- deadline(expiry, now),
           {:ok, next} <- Journal.next_revision(db),
           receipt = %{
             "authority_epoch" => input["authority_epoch"],
             "operation_id" => input["operation_id"],
             "revision" => next,
             "input_sha256" => AuthoringProducer.sha(document),
             "preparation_sha256" => input["preparation_sha256"],
             "attempt" => input["attempt"],
             "handoff_sha256" => handoff,
             "provider_sha256" => root["input"]["provider_sha256"],
             "disposition" => "handoff_reserved"
           },
           {:ok, encoded} <- GenerationAttempt.encode_receipt(receipt),
           :ok <-
             Journal.authority_event(
               db,
               next,
               "authoring_generation_attempt_handed",
               input["operation_id"]
             ),
           {:ok, []} <-
             query(
               db,
               "INSERT INTO profile_authoring_generation_attempts (#{@columns}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
               [
                 principal,
                 input["authority_epoch"],
                 input["operation_id"],
                 document,
                 input["preparation_operation_id"],
                 input["attempt"],
                 handoff,
                 encoded,
                 boot,
                 started,
                 expiry,
                 next,
                 nil,
                 nil
               ]
             ),
           :ok <- validate(db),
           do: {:commit, {:ok, receipt}}

    transaction_result(result)
  end

  def original(db, principal, epoch, operation) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_authoring_generation_attempts WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [row] -> decoded_row(row)
        _ -> corrupt()
      end
    end
  end

  def status(db, credential, epoch, operation, boot, now, live?) do
    with true <- is_integer(epoch) and epoch in 1..@maximum and WotexHome.Id.valid?(operation),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, row} <- original(db, principal, epoch, operation),
         {:ok, root} <-
           GenerationPreparations.original(db, principal, epoch, row["preparation_operation_id"]) do
      state =
        cond do
          row["result"] != nil -> row["result"]["disposition"]
          root["cancellation_revision"] != nil -> "cancelled"
          row["boot_epoch"] != boot or now >= row["expires_ms"] or not live? -> "unknown"
          true -> "running"
        end

      {:ok,
       %{
         "original" => row["receipt"],
         "result" => row["result"],
         "result_revision" => row["result_revision"],
         "state" => state
       }}
    else
      false -> {:error, :invalid_generation_attempt}
      error -> error
    end
  end

  def response_basis(db, credential, principal, row, boot, now) do
    with {:ok, ^principal} <- ProfileWriter.review_actor(db, credential),
         {:ok, [[_, epoch]]} <- meta(db),
         :ok <- equal(epoch, row["authority_epoch"], :stale_authority_epoch),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, root} <-
           GenerationPreparations.original(db, principal, epoch, row["preparation_operation_id"]),
         :ok <- live_root(root, boot, now),
         :ok <- deadline(row["expires_ms"], now),
         {:ok, records} <- GenerationPreparations.owned_references(db, principal, root["input"]),
         do: {:ok, root, records}
  end

  def settle_tx(db, credential, principal, epoch, operation, value) do
    result =
      with :ok <- validate(db),
           {:ok, row} <- original(db, principal, epoch, operation),
           nil <- row["result_document"],
           {:ok, result} <- materialize(db, credential, row, value),
           {:ok, document} <- GenerationAttempt.encode_result(result),
           :ok <- result_capacity(db, byte_size(document)),
           {:ok, next} <- Journal.next_revision(db),
           :ok <-
             Journal.authority_event(db, next, "authoring_generation_attempt_settled", operation),
           {:ok, []} <-
             query(
               db,
               "UPDATE profile_authoring_generation_attempts SET result_document=?,result_revision=? WHERE principal_id=? AND authority_epoch=? AND operation_id=? AND result_revision IS NULL",
               [document, next, principal, epoch, operation]
             ),
           :ok <- validate(db),
           do: {:commit, {:ok, result}}

    case result do
      bytes when is_binary(bytes) ->
        with {:ok, old} <- GenerationAttempt.decode_result(bytes),
             do: {:rollback, {:unchanged, {:ok, old}}}

      other ->
        transaction_result(other)
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[37]]} -> validate(db)
      {:ok, [[v]]} when v in 4..36 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- GenerationPreparations.validate(db),
         {:ok, [[maximum, epoch]]} <- meta(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_authoring_generation_attempts ORDER BY revision LIMIT 3073"
           ),
         true <- length(rows) <= 3072,
         {:ok, roots} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,operation_id FROM profile_authoring_generations LIMIT 1025"
           ),
         {:ok, events} <-
           query(
             db,
             "SELECT revision,event_type,entity_id FROM authority_journal WHERE event_type IN ('authoring_generation_attempt_handed','authoring_generation_attempt_settled') ORDER BY revision LIMIT 6145"
           ),
         events = Map.new(events, fn [r, e, id] -> {r, {e, id}} end),
         true <- map_size(events) == length(rows) + Enum.count(rows, &(List.last(&1) != nil)),
         {:ok, decoded} <- decode_rows(rows),
         true <- Enum.all?(decoded, &valid_row?(db, &1, events, maximum, epoch)),
         true <- Enum.all?(roots, &valid_sequence?(db, &1, decoded)),
         :ok <- capacity(db, 0, 0, false),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp materialize(db, credential, row, {:candidate, assessment, draft, bundle}) do
    with {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         true <- principal == row["principal_id"],
         {:ok, draft_ref} <- import_generated(db, credential, row, draft, "draft"),
         {:ok, bundle_ref} <- import_generated(db, credential, row, bundle, "bundle") do
      {:ok,
       %{
         "disposition" => "candidate",
         "reason" => nil,
         "draft_ref" => draft_ref,
         "bundle_ref" => bundle_ref,
         "assessment" => assessment
       }}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp materialize(_, _, _, result) when is_map(result), do: {:ok, result}
  defp materialize(_, _, _, _), do: {:error, :invalid_generation_attempt}

  defp import_generated(_, _, _, nil, "bundle"), do: {:ok, nil}

  defp import_generated(db, credential, row, object, kind) do
    with {:ok, summary} <- AuthoringObject.summary(object),
         true <- summary["kind"] == kind,
         {:ok, [[revision, epoch]]} <- meta(db),
         true <- epoch == row["authority_epoch"],
         input = %{
           "authority_epoch" => epoch,
           "expected_revision" => revision,
           "operation_id" =>
             GenerationAttempt.object_operation(
               row["principal_id"],
               epoch,
               row["operation_id"],
               kind
             ),
           "object" => summary
         },
         {:ok, document} <- AuthoringImport.encode(input) do
      case AuthoringObjects.import_tx(db, credential, document, object) do
        {:commit, {:ok, receipt}} ->
          {:ok,
           %{
             "object_digest" => summary["object_digest"],
             "first_revision" => receipt["first_revision"]
           }}

        {:rollback, {:policy, reason}} ->
          {:error, reason}

        {:rollback, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :stale_authoring_reference}
      error -> error
    end
  end

  defp valid_row?(db, r, events, maximum, current_epoch) do
    with true <- r["authority_epoch"] in 1..current_epoch and r["revision"] in 1..maximum,
         true <- WotexHome.Id.valid?(r["principal_id"]),
         {:ok, root} <-
           GenerationPreparations.original(
             db,
             r["principal_id"],
             r["authority_epoch"],
             r["preparation_operation_id"]
           ),
         i = r["input"],
         true <-
           i["authority_epoch"] == r["authority_epoch"] and i["operation_id"] == r["operation_id"] and
             i["preparation_operation_id"] == r["preparation_operation_id"] and
             i["attempt"] == r["attempt"] and
             i["expected_revision"] == r["revision"] - 1 and
             i["preparation_sha256"] == root["receipt"]["input_sha256"],
         true <-
           r["receipt"] == %{
             "authority_epoch" => r["authority_epoch"],
             "operation_id" => r["operation_id"],
             "revision" => r["revision"],
             "input_sha256" => AuthoringProducer.sha(r["input_document"]),
             "preparation_sha256" => i["preparation_sha256"],
             "attempt" => r["attempt"],
             "handoff_sha256" => r["handoff_sha256"],
             "provider_sha256" => root["input"]["provider_sha256"],
             "disposition" => "handoff_reserved"
           },
         true <-
           EnvelopeCodec.digest?(r["handoff_sha256"]) and r["boot_epoch"] == root["boot_epoch"] and
             int?(r["started_ms"]) and int?(r["expires_ms"]) and
             r["started_ms"] >= root["created_ms"] and
             r["expires_ms"] > r["started_ms"] and
             r["expires_ms"] ==
               min(root["expires_ms"], r["started_ms"] + root["input"]["budget"]["attempt_ms"]),
         true <-
           r["revision"] > root["revision"] and
             events[r["revision"]] == {"authoring_generation_attempt_handed", r["operation_id"]},
         true <-
           root["cancellation_revision"] == nil or
             r["revision"] < root["cancellation_revision"],
         true <- result_link?(db, r, root, events, maximum),
         do: true,
         else: (_ -> false)
  end

  defp result_link?(_, %{"result" => nil, "result_revision" => nil}, _, _, _), do: true
  defp result_link?(_, %{"result" => nil}, _, _, _), do: false

  defp result_link?(db, r, root, events, maximum) do
    revision = r["result_revision"]

    is_integer(revision) and revision > r["revision"] and revision <= maximum and
      events[revision] == {"authoring_generation_attempt_settled", r["operation_id"]} and
      candidate_link?(db, r, root)
  end

  defp candidate_link?(db, %{"result" => %{"disposition" => "candidate"} = result} = r, root) do
    a = result["assessment"]

    (root["cancellation_revision"] == nil or
       r["result_revision"] < root["cancellation_revision"]) and
      a["basis_sha256"] == root["basis_sha256"] and
      a["report"]["contract_sha256"] == root["input"]["projection"]["contract_digest"] and
      object_link?(db, r, result["draft_ref"], "draft", a["draft_sha256"]) and
      object_link?(db, r, result["bundle_ref"], "bundle", a["bundle_sha256"])
  end

  defp candidate_link?(_, _, _), do: true
  defp object_link?(_, _, nil, "bundle", nil), do: true

  defp object_link?(db, r, ref, kind, payload) do
    operation =
      GenerationAttempt.object_operation(
        r["principal_id"],
        r["authority_epoch"],
        r["operation_id"],
        kind
      )

    with {:ok, [[^kind, ^payload, first, document, receipt, revision]]} <-
           query(
             db,
             "SELECT o.kind,o.payload_sha256,o.first_revision,i.input_document,i.receipt_document,i.revision FROM profile_authoring_objects o JOIN profile_authoring_object_operations i ON i.principal_id=o.principal_id WHERE o.principal_id=? AND o.object_digest=? AND i.authority_epoch=? AND i.operation_id=?",
             [r["principal_id"], ref["object_digest"], r["authority_epoch"], operation]
           ),
         {:ok, input} <- AuthoringImport.decode(document),
         {:ok, original} <- AuthoringImport.decode_receipt(receipt),
         true <-
           ref["first_revision"] == first and original["first_revision"] == first and
             input["object"]["object_digest"] == ref["object_digest"] and
             revision > r["revision"] and revision < r["result_revision"],
         do: true,
         else: (_ -> false)
  end

  defp valid_sequence?(db, [principal, epoch, operation], rows) do
    own =
      Enum.filter(
        rows,
        &(&1["principal_id"] == principal and &1["authority_epoch"] == epoch and
            &1["preparation_operation_id"] == operation)
      )

    with {:ok, root} <- GenerationPreparations.original(db, principal, epoch, operation),
         true <-
           length(own) <= root["input"]["budget"]["attempts"] and
             Enum.map(own, & &1["attempt"]) == Enum.to_list(1..length(own)//1),
         true <-
           Enum.with_index(own)
           |> Enum.all?(fn {r, n} ->
             if n == 0,
               do: r["input"]["previous_operation_id"] == nil,
               else: valid_predecessor?(Enum.at(own, n - 1), r)
           end),
         do: true,
         else: (_ -> false)
  end

  defp valid_predecessor?(previous, row),
    do:
      previous["result"] != nil and previous["result"]["disposition"] == "candidate" and
        previous["result"]["assessment"]["disposition"] == "invalid" and
        previous["result_revision"] < row["revision"] and
        previous["started_ms"] <= row["started_ms"] and
        row["input"]["previous_operation_id"] == previous["operation_id"] and
        row["input"]["repair_export"] == true

  defp predecessor(rows, input, root) do
    cond do
      input["attempt"] != length(rows) + 1 or
          input["attempt"] > root["input"]["budget"]["attempts"] ->
        {:error, :generation_attempt_unavailable}

      rows == [] ->
        :ok

      true ->
        p = List.last(rows)

        if p["result"] != nil and p["result"]["disposition"] == "candidate" and
             p["result"]["assessment"]["disposition"] == "invalid" and
             input["previous_operation_id"] == p["operation_id"] and
             input["repair_export"] == true,
           do: :ok,
           else: {:error, :generation_attempt_unavailable}
    end
  end

  defp live_root(root, boot, now) do
    cond do
      root["cancellation_revision"] != nil -> {:error, :generation_cancelled}
      root["boot_epoch"] != boot -> {:error, :generation_retired}
      not int?(now) or now >= root["expires_ms"] -> {:error, :generation_deadline_expired}
      true -> :ok
    end
  end

  defp root_attempts(db, principal, epoch, root) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_authoring_generation_attempts WHERE principal_id=? AND authority_epoch=? AND preparation_operation_id=? ORDER BY attempt LIMIT 4",
             [principal, epoch, root]
           ),
         do: decode_rows(rows)
  end

  defp decoded_row(row) do
    r = Map.new(Enum.zip(String.split(@columns, ","), row))

    with {:ok, input} <- GenerationAttempt.decode(r["input_document"]),
         {:ok, receipt} <- GenerationAttempt.decode_receipt(r["receipt_document"]),
         {:ok, result} <- decoded_result(r["result_document"]),
         do:
           {:ok,
            r
            |> Map.put("input", input)
            |> Map.put("receipt", receipt)
            |> Map.put("result", result)}
  end

  defp decoded_result(nil), do: {:ok, nil}
  defp decoded_result(bytes), do: GenerationAttempt.decode_result(bytes)

  defp decode_rows(rows),
    do:
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, all} ->
        case decoded_row(row) do
          {:ok, r} -> {:cont, {:ok, all ++ [r]}}
          error -> {:halt, error}
        end
      end)

  defp active_capacity(db, principal, boot, now) do
    with {:ok, [[all, own]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(a.principal_id=?),0) FROM profile_authoring_generation_attempts a JOIN profile_authoring_generations g ON g.principal_id=a.principal_id AND g.authority_epoch=a.authority_epoch AND g.operation_id=a.preparation_operation_id WHERE a.boot_epoch=? AND a.expires_ms>? AND a.result_revision IS NULL AND g.cancellation_revision IS NULL",
             [principal, boot, now]
           ),
         true <- all < 16 and own == 0,
         do: :ok,
         else: (_ -> {:error, :generation_busy})
  end

  defp capacity(db, input, reserve, new?) do
    with {:ok, [[count, bytes, results, unsettled]]} <- usage(db),
         true <-
           count + if(new?, do: 1, else: 0) <= 3072 and bytes + input <= 4_194_304 and
             results + unsettled * 1024 + reserve <= 8_388_608,
         do: :ok,
         else: (_ -> {:error, :generation_attempt_capacity})
  end

  defp result_capacity(db, bytes) do
    with {:ok, [[_, _, results, unsettled]]} <- usage(db),
         true <- unsettled > 0 and results + bytes + (unsettled - 1) * 1024 <= 8_388_608,
         do: :ok,
         else: (_ -> {:error, :generation_attempt_capacity})
  end

  defp usage(db),
    do:
      query(
        db,
        "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(result_document AS BLOB))),0),COALESCE(SUM(result_revision IS NULL),0) FROM profile_authoring_generation_attempts"
      )

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp int?(n), do: is_integer(n) and n in 0..@maximum
  defp deadline(expires, now) when is_integer(now) and now < expires, do: :ok
  defp deadline(_, _), do: {:error, :generation_deadline_expired}
  defp equal(x, x, _), do: :ok
  defp equal(_, _, reason), do: {:error, reason}
  defp transaction_result({:commit, _} = result), do: result
  defp transaction_result({:ok, :existing, r}), do: {:rollback, {:unchanged, {:ok, r}}}

  defp transaction_result({:error, reason}) when reason in @policy,
    do: {:rollback, {:policy, reason}}

  defp transaction_result({:error, reason}), do: {:rollback, reason}
  defp transaction_result(:not_found), do: {:rollback, {:policy, :stale_authoring_reference}}
  defp transaction_result(_), do: {:rollback, :corrupt_generation_attempts}
  defp corrupt, do: {:error, :corrupt_generation_attempts}
end
