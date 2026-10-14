defmodule WotexHome.Durable.Store.AuthoringCandidates do
  @moduledoc "Stateless original manual assessments and their immutable retained dependency links."
  alias WotexHome.Durable.Store.{AuthoringObjects, Journal, MaintenanceWriter, ProfileWriter}
  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringObject, AuthoringProducer}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "principal_id,authority_epoch,operation_id,input_document,assessment_document,receipt_document,revision"
  @policy ~w(unauthorized invalid_credential permission_denied authoring_operation_conflict stale_authority_epoch resnapshot_required maintenance_active stale_authoring_reference authoring_candidate_capacity invalid_authoring_candidate revision_exhausted)a
  def columns, do: @columns

  def prepare(db, credential, document) do
    with {:ok, input} <- AuthoringCandidate.decode(document),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_authoring_candidates WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[^document, receipt]] ->
          with {:ok, r} <- AuthoringCandidate.decode_receipt(receipt), do: {:ok, :existing, r}

        [_] ->
          {:error, :authoring_operation_conflict}

        _ ->
          corrupt()
      end
    end
  end

  def current_basis(db, principal, input) do
    with {:ok, [[revision, epoch]]} <- meta(db),
         :ok <- equal(epoch, input["authority_epoch"], :stale_authority_epoch),
         :ok <- equal(revision, input["expected_revision"], :resnapshot_required),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, objects} <- ownership(db),
         :ok <- references(objects, principal, input),
         {:ok, document} <- AuthoringCandidate.encode(input),
         :ok <- document_capacity(db, byte_size(document), 0) do
      {:ok, elem(objects[{principal, input["request"]["base_draft_ref"]["object_digest"]}], 0)}
    end
  end

  def retain_tx(db, credential, document, assessment_document, bundle) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, _} <- current_basis(db, principal, input),
         {:ok, assessment} <- AuthoringCandidate.decode_assessment(assessment_document),
         :ok <- correspondence(db, principal, input, assessment, bundle),
         :ok <- capacity(db, document, assessment_document, bundle),
         {:ok, next} <- Journal.next_revision(db),
         receipt = %{
           "authority_epoch" => input["authority_epoch"],
           "operation_id" => input["operation_id"],
           "revision" => next,
           "input_sha256" => AuthoringProducer.sha(document),
           "basis_sha256" => assessment["basis_sha256"],
           "assessment_sha256" => AuthoringProducer.sha(assessment_document),
           "disposition" => assessment["disposition"],
           "capture_status" => "not_supplied",
           "bundle" => bundle,
           "source_review" => "not_assessed",
           "fixture_status" => fixture_status(input)
         },
         {:ok, receipt_document} <- AuthoringCandidate.encode_receipt(receipt),
         :ok <-
           Journal.authority_event(
             db,
             next,
             "authoring_candidate_assessed",
             input["operation_id"]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_authoring_candidates (#{@columns}) VALUES (?,?,?,?,?,?,?)",
             [
               principal,
               input["authority_epoch"],
               input["operation_id"],
               document,
               assessment_document,
               receipt_document,
               next
             ]
           ),
         :ok <- validate(db) do
      {:commit, {:ok, receipt}}
    else
      {:ok, :existing, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
      {:error, reason} when reason in @policy -> {:rollback, {:policy, reason}}
      :not_found -> {:rollback, {:policy, :stale_authoring_reference}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_authoring_candidates}
    end
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
             "SELECT receipt_document FROM profile_authoring_candidates WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[bytes]] -> AuthoringCandidate.decode_receipt(bytes)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_authoring_candidate}
      error -> error
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [30, 31] -> validate(db)
      {:ok, [[version]]} when version in 4..29 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- AuthoringObjects.validate(db),
         {:ok, objects} <- ownership(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_authoring_candidates ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1024,
         {:ok, [[maximum, epoch]]} <- meta(db),
         {:ok, links} <-
           query(
             db,
             "SELECT c.revision,j.event_type,j.entity_id,p.principal_id FROM profile_authoring_candidates c LEFT JOIN authority_journal j ON j.revision=c.revision LEFT JOIN principals p ON p.principal_id=c.principal_id ORDER BY c.revision LIMIT 1025"
           ),
         true <- length(links) == length(rows),
         links = Map.new(links, fn [r, e, o, p] -> {r, {e, o, p}} end),
         true <- map_size(links) == length(rows),
         {:ok, bundles} <- validate_rows(rows, objects, links, maximum, epoch),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_candidate_assessed'"
           ),
         true <- count == length(rows),
         :ok <- document_capacity(db, 0, 0, false),
         :ok <- retained_capacity(db, objects, bundles) do
      :ok
    else
      _ -> corrupt()
    end
  end

  def retained(db) do
    with :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT receipt_document FROM profile_authoring_candidates ORDER BY revision"
           ) do
      bundles =
        Enum.flat_map(rows, fn [bytes] ->
          {:ok, r} = AuthoringCandidate.decode_receipt(bytes)
          if r["bundle"], do: [r["bundle"]], else: []
        end)

      unique(bundles)
    end
  end

  def capacity(db, input, assessment, bundle) do
    with :ok <- document_capacity(db, byte_size(input), byte_size(assessment)),
         {:ok, objects} <- ownership(db),
         {:ok, prior} <- retained(db),
         :ok <- retained_capacity(db, objects, if(bundle, do: [bundle | prior], else: prior)),
         do: :ok,
         else: (_ -> {:error, :authoring_candidate_capacity})
  end

  def object_capacity(db, summary) do
    with {:ok, objects} <- ownership(db),
         {:ok, bundles} <- retained(db),
         do: retained_capacity(db, objects, [summary | bundles])
  end

  def v1_capacity(db, digest) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [30, 31] ->
        with {:ok, objects} <- ownership(db),
             {:ok, bundles} <- retained(db),
             {:ok, profiles} <-
               query(db, "SELECT artifact_digest FROM portable_profiles LIMIT 65") do
          ids =
            Enum.map(Map.values(objects), fn {s, _} -> s["object_digest"] end) ++
              Enum.map(bundles, & &1["object_digest"]) ++
              Enum.map(profiles, fn [d] -> d end) ++ [digest]

          if length(Enum.uniq(ids)) <= 128, do: :ok, else: {:error, :profile_capacity}
        end

      {:ok, [[version]]} when version in 4..29 ->
        :ok

      _ ->
        corrupt()
    end
  end

  defp validate_rows(rows, objects, links, maximum, epoch) do
    Enum.reduce_while(rows, {:ok, []}, fn [
                                            principal,
                                            original_epoch,
                                            operation,
                                            input,
                                            assessment,
                                            receipt,
                                            revision
                                          ],
                                          {:ok, bundles} ->
      with true <- is_integer(revision) and revision in 1..maximum and original_epoch in 1..epoch,
           true <- links[revision] == {"authoring_candidate_assessed", operation, principal},
           {:ok, i} <- AuthoringCandidate.decode(input),
           {:ok, a} <- AuthoringCandidate.decode_assessment(assessment),
           {:ok, r} <- AuthoringCandidate.decode_receipt(receipt),
           true <-
             i["authority_epoch"] == original_epoch and i["operation_id"] == operation and
               i["expected_revision"] == revision - 1,
           true <-
             r["authority_epoch"] == original_epoch and r["operation_id"] == operation and
               r["revision"] == revision and
               r["input_sha256"] == AuthoringProducer.sha(input) and
               r["assessment_sha256"] == AuthoringProducer.sha(assessment) and
               r["basis_sha256"] == a["basis_sha256"] and r["disposition"] == a["disposition"] and
               r["fixture_status"] == fixture_status(i),
           :ok <- references(objects, principal, i),
           :ok <- matches(objects, principal, i, a, r["bundle"]) do
        {:cont, {:ok, if(r["bundle"], do: [r["bundle"] | bundles], else: bundles)}}
      else
        _ -> {:halt, corrupt()}
      end
    end)
  end

  defp correspondence(db, principal, i, a, b) do
    with {:ok, objects} <- ownership(db), do: matches(objects, principal, i, a, b)
  end

  defp matches(objects, principal, i, a, b) do
    {draft, _} = objects[{principal, i["request"]["base_draft_ref"]["object_digest"]}]

    valid =
      a["draft_sha256"] == draft["payload_sha256"] and
        a["report"]["contract_sha256"] == i["request"]["contract_digest"] and
        length(a["report"]["diagnostics"]) <= i["request"]["limits"]["max_diagnostics"] and
        byte_size(JSON.encode!(a["report"])) <= i["request"]["limits"]["max_report_bytes"] and
        ((b == nil and a["bundle_sha256"] == nil) or
           (AuthoringObject.valid_summary?(b) and b["kind"] == "bundle" and
              b["payload_sha256"] == a["bundle_sha256"]))

    if valid, do: :ok, else: {:error, :invalid_authoring_candidate}
  end

  defp references(objects, principal, input) do
    request = input["request"]

    refs =
      [{request["base_draft_ref"], "draft"}] ++
        Enum.map(request["source_refs"], &{&1, "source"}) ++
        Enum.map(request["fixture_refs"], &{&1, "fixture"})

    Enum.reduce_while(refs, :ok, fn {ref, kind}, :ok ->
      expected_first = ref["first_revision"]
      maximum = input["expected_revision"]

      case objects[{principal, ref["object_digest"]}] do
        {%{"kind" => ^kind}, first}
        when first == expected_first and first <= maximum ->
          {:cont, :ok}

        nil ->
          {:halt, :not_found}

        _ ->
          {:halt, {:error, :stale_authoring_reference}}
      end
    end)
  end

  defp ownership(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT #{AuthoringObjects.object_columns()} FROM profile_authoring_objects LIMIT 1025"
           ) do
      {:ok,
       Map.new(rows, fn [p, d, k, h, s, r] ->
         {{p, d},
          {%{"object_digest" => d, "kind" => k, "payload_sha256" => h, "payload_bytes" => s}, r}}
       end)}
    end
  end

  defp document_capacity(db, input, assessment, new? \\ true) do
    with {:ok, [[count, inputs, assessments]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(assessment_document AS BLOB))),0) FROM profile_authoring_candidates"
           ),
         true <-
           count + if(new?, do: 1, else: 0) <= 1024 and inputs + input <= 4_194_304 and
             assessments + assessment <= 4_194_304 do
      :ok
    else
      _ -> {:error, :authoring_candidate_capacity}
    end
  end

  defp retained_capacity(db, objects, bundles) do
    imported = objects |> Map.values() |> Enum.map(&elem(&1, 0))

    with {:ok, all} <- unique(imported ++ bundles),
         true <-
           length(all) <= 128 and
             Enum.reduce(all, 0, &(&1["payload_bytes"] + 42 + &2)) <= 4_194_304,
         {:ok, profiles} <- query(db, "SELECT artifact_digest FROM portable_profiles LIMIT 65"),
         true <-
           length(
             Enum.uniq(
               Enum.map(all, & &1["object_digest"]) ++ Enum.map(profiles, fn [d] -> d end)
             )
           ) <= 128 do
      :ok
    else
      _ -> {:error, :authoring_candidate_capacity}
    end
  end

  defp unique(all) do
    unique = Enum.uniq_by(all, & &1["object_digest"])

    if length(Enum.uniq(all)) == length(unique),
      do: {:ok, Enum.sort_by(unique, & &1["object_digest"])},
      else: corrupt()
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp equal(v, v, _), do: :ok
  defp equal(_, _, reason), do: {:error, reason}

  defp fixture_status(input),
    do: if(input["request"]["fixture_refs"] == [], do: "not_supplied", else: "not_assessed")

  defp corrupt, do: {:error, :corrupt_authoring_candidates}
end
