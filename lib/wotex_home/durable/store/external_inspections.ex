defmodule WotexHome.Durable.Store.ExternalInspections do
  @moduledoc """
  Journals inert external inspections and their exact owned import references.

  Preparation authenticates the actor and resolves typed original object
  handles. Application-side inspection returns a result; `retain_tx/4` checks
  the current basis again before storing the original result/receipt. Historical
  validation checks the retained import correspondence in both directions.

  The module is stateless and uses Store's borrowed handle. It performs no
  producer call or custody publication and grants no artifact trust, target
  selection or observation authority.
  """

  alias WotexHome.Durable.Store.{AuthoringObjects, Journal, MaintenanceWriter, ProfileWriter}
  alias WotexHome.Profiles.ExternalInspection
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "principal_id,authority_epoch,operation_id,input_document,result_document,receipt_document,revision"
  @policy ~w(unauthorized invalid_credential permission_denied external_inspection_conflict stale_authority_epoch resnapshot_required maintenance_active stale_external_reference external_inspection_capacity invalid_external_inspection revision_exhausted)a
  def columns, do: @columns

  @doc false
  def retained_original(db, principal, reference) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT input_document,result_document,receipt_document FROM profile_external_inspections WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, reference["authority_epoch"], reference["operation_id"]]
           ) do
      case rows do
        [] ->
          :not_found

        [[input, result, receipt]] ->
          with {:ok, i} <- ExternalInspection.decode(input),
               {:ok, r} <- ExternalInspection.decode_result(result),
               {:ok, s} <- ExternalInspection.decode_receipt(receipt),
               true <-
                 Enum.all?(
                   ~w(authority_epoch operation_id revision input_sha256 result_sha256),
                   &(s[&1] == reference[&1])
                 ),
               do: {:ok, %{input: i, result: r, result_document: result, receipt: s}},
               else: (_ -> {:error, :stale_external_reference})

        _ ->
          corrupt()
      end
    end
  end

  @doc false
  def owned_records(db, principal, inspection_input) do
    with {:ok, objects} <- ownership(db), do: references(objects, principal, inspection_input)
  end

  def prepare(db, credential, document) do
    with {:ok, input} <- ExternalInspection.decode(document),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_external_inspections WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[^document, receipt]] ->
          with {:ok, r} <- ExternalInspection.decode_receipt(receipt), do: {:ok, :existing, r}

        [_] ->
          {:error, :external_inspection_conflict}

        _ ->
          corrupt()
      end
    end
  end

  def current_basis(db, principal, input) do
    with {:ok, [[revision, epoch]]} <- meta(db),
         :ok <- same(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- same(revision, input["expected_revision"], :resnapshot_required),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, objects} <- ownership(db),
         {:ok, records} <- references(objects, principal, input),
         {:ok, document} <- ExternalInspection.encode(input),
         :ok <- capacity(db, byte_size(document), 0),
         do: {:ok, records}
  end

  def retain_tx(db, credential, document, result_document) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, _} <- current_basis(db, principal, input),
         {:ok, result} <- ExternalInspection.decode_result(result_document),
         {:ok, objects} <- ownership(db),
         :ok <- correspondence(objects, principal, input, result),
         :ok <- capacity(db, byte_size(document), byte_size(result_document)),
         {:ok, next} <- Journal.next_revision(db),
         receipt = receipt(input, result, document, result_document, next),
         {:ok, receipt_document} <- ExternalInspection.encode_receipt(receipt),
         :ok <-
           Journal.authority_event(db, next, "external_profile_inspected", input["operation_id"]),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_external_inspections (#{@columns}) VALUES (?,?,?,?,?,?,?)",
             [
               principal,
               input["authority_epoch"],
               input["operation_id"],
               document,
               result_document,
               receipt_document,
               next
             ]
           ),
         :ok <- validate(db),
         do: {:commit, {:ok, receipt}},
         else: (
           {:ok, :existing, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
           {:error, reason} when reason in @policy -> {:rollback, {:policy, reason}}
           :not_found -> {:rollback, {:policy, :stale_external_reference}}
           {:error, reason} -> {:rollback, reason}
           _ -> {:rollback, :corrupt_external_inspections}
         )
  end

  def status(db, credential, epoch, operation) do
    with true <-
           is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807 and
             WotexHome.Id.valid?(operation),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_external_inspections WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[r]] -> ExternalInspection.decode_receipt(r)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_external_inspection}
      error -> error
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [32, 33, 34, 35, 36] -> validate(db)
      {:ok, [[v]]} when v in 4..31 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- AuthoringObjects.validate(db),
         {:ok, objects} <- ownership(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_external_inspections ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1024,
         {:ok, [[maximum, epoch]]} <- meta(db),
         {:ok, links} <-
           query(
             db,
             "SELECT r.revision,j.event_type,j.entity_id,p.principal_id FROM profile_external_inspections r LEFT JOIN authority_journal j ON j.revision=r.revision LEFT JOIN principals p ON p.principal_id=r.principal_id ORDER BY r.revision LIMIT 1025"
           ),
         true <- length(links) == length(rows),
         links = Map.new(links, fn [r, e, o, p] -> {r, {e, o, p}} end),
         true <- map_size(links) == length(rows),
         :ok <- validate_rows(rows, links, objects, maximum, epoch),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='external_profile_inspected'"
           ),
         true <- count == length(rows),
         :ok <- capacity(db, 0, 0, false),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp validate_rows(rows, links, objects, maximum, epoch) do
    Enum.reduce_while(rows, :ok, fn [
                                      principal,
                                      original_epoch,
                                      operation,
                                      input,
                                      result,
                                      stored,
                                      revision
                                    ],
                                    :ok ->
      with true <-
             original_epoch in 1..epoch and revision in 1..maximum and
               links[revision] == {"external_profile_inspected", operation, principal},
           {:ok, i} <- ExternalInspection.decode(input),
           {:ok, r} <- ExternalInspection.decode_result(result),
           {:ok, s} <- ExternalInspection.decode_receipt(stored),
           true <-
             i["authority_epoch"] == original_epoch and i["operation_id"] == operation and
               i["expected_revision"] == revision - 1,
           :ok <- correspondence(objects, principal, i, r),
           true <- s == receipt(i, r, input, result, revision),
           do: {:cont, :ok},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp ownership(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{AuthoringObjects.object_columns()} FROM profile_authoring_objects LIMIT 1025"
           ),
         do:
           {:ok,
            Map.new(rows, fn [p, d, k, h, s, r] ->
              {{p, d},
               %{
                 "object" => %{
                   "kind" => k,
                   "object_digest" => d,
                   "payload_sha256" => h,
                   "payload_bytes" => s
                 },
                 "first_revision" => r
               }}
            end)}
  end

  defp requirements(i),
    do:
      [{i["envelope_ref"], "envelope"}, {i["profile"]["object_ref"], "profile"}] ++
        Enum.map(i["definitions"], &{&1["object_ref"], "definition"})

  defp references(objects, principal, input) do
    Enum.reduce_while(requirements(input["inspection"]), {:ok, []}, fn {h, kind},
                                                                       {:ok, records} ->
      case objects[{principal, h["object_digest"]}] do
        nil ->
          {:halt, :not_found}

        %{"object" => %{"kind" => ^kind}, "first_revision" => first} = r ->
          if first == h["first_revision"] and first <= input["expected_revision"],
            do: {:cont, {:ok, [r | records]}},
            else: {:halt, {:error, :stale_external_reference}}

        _ ->
          {:halt, {:error, :stale_external_reference}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.sort_by(records, & &1["object"]["object_digest"])}
      error -> error
    end
  end

  defp correspondence(objects, principal, input, result) do
    i = input["inspection"]

    with {:ok, _} <- references(objects, principal, input),
         documents =
           Enum.map([i["profile"] | i["definitions"]], fn d ->
             %{
               "reference" => d["reference"],
               "raw_sha256" =>
                 objects[{principal, d["object_ref"]["object_digest"]}]["object"][
                   "payload_sha256"
                 ]
             }
           end),
         true <-
           result["reader_basis_sha256"] == i["reader_basis_sha256"] and
             result["envelope"]["envelope_sha256"] ==
               objects[{principal, i["envelope_ref"]["object_digest"]}]["object"][
                 "payload_sha256"
               ] and result["envelope"]["document_identities"] == documents,
         do: :ok,
         else: (
           false -> {:error, :invalid_external_inspection}
           error -> error
         )
  end

  defp receipt(input, result, document, result_document, revision),
    do: %{
      "authority_epoch" => input["authority_epoch"],
      "operation_id" => input["operation_id"],
      "revision" => revision,
      "input_sha256" => sha(document),
      "reader_basis_sha256" => result["reader_basis_sha256"],
      "result_sha256" => sha(result_document),
      "capture_digest" => result["capture_digest"],
      "envelope_sha256" => result["envelope"]["envelope_sha256"],
      "home_consumption" => "matched"
    }

  defp capacity(db, input, result, new? \\ true) do
    with {:ok, [[count, inputs, results]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(result_document AS BLOB))),0) FROM profile_external_inspections"
           ),
         true <-
           count + if(new?, do: 1, else: 0) <= 1024 and inputs + input <= 4_194_304 and
             results + result <= 4_194_304,
         do: :ok,
         else: (_ -> {:error, :external_inspection_capacity})
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp same(v, v, _), do: :ok
  defp same(_, _, reason), do: {:error, reason}
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp corrupt, do: {:error, :corrupt_external_inspections}
end
