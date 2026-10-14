defmodule WotexHome.Durable.Store.AuthoringReviews do
  @moduledoc """
  Retains source and complete review originals with immutable dependency links.

  Preparation resolves the actor's exact candidate/source/fixture references and
  checks the current basis. Review computation is supplied by the application
  boundary; `retain_tx/4` repeats current checks before journaling the result and
  receipt. Status reads the original review, while integrity validation checks
  both directions of its retained links.

  This stateless collaborator borrows the single Store connection. A complete
  proposal review does not approve the profile, select a target or authorize
  physical dispatch.
  """

  alias WotexHome.Durable.Store.{
    AuthoringCandidates,
    AuthoringObjects,
    ProfileWriter,
    MaintenanceWriter,
    Journal
  }

  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringReview, AuthoringProducer}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns "principal_id,authority_epoch,operation_id,input_document,result_document,receipt_document,revision"
  @denials ~w(unauthorized invalid_credential permission_denied authoring_operation_conflict stale_authority_epoch resnapshot_required maintenance_active stale_authoring_reference stale_authoring_basis authoring_review_capacity invalid_authoring_review revision_exhausted)a
  def columns, do: @columns

  def prepare(db, credential, document) do
    with {:ok, input} <- AuthoringReview.decode(document),
         {:ok, principal} <- ProfileWriter.review_actor(db, credential),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_authoring_reviews WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, input["authority_epoch"], input["operation_id"]]
           ) do
      case rows do
        [] ->
          {:ok, :new, principal, input}

        [[^document, receipt]] ->
          with {:ok, r} <- AuthoringReview.decode_receipt(receipt), do: {:ok, :existing, r}

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
         {:ok, context} <- candidate(db, principal, input["review"]["candidate_ref"]),
         {:ok, objects} <- ownership(db),
         :ok <- envelope_ref(objects, principal, input),
         {:ok, document} <- AuthoringReview.encode(input),
         :ok <- capacity(db, byte_size(document), 0),
         required = read_requirements(context, objects, principal, input) do
      {:ok, Map.put(context, :objects, required)}
    end
  end

  def retain_tx(db, credential, document, result_document) do
    with {:ok, :new, principal, input} <- prepare(db, credential, document),
         {:ok, context} <- current_basis(db, principal, input),
         {:ok, result} <- AuthoringReview.decode_result(result_document),
         {:ok, objects} <- ownership(db),
         :ok <- correspondence(input, context, result, objects, principal),
         :ok <- capacity(db, byte_size(document), byte_size(result_document)),
         {:ok, next} <- Journal.next_revision(db),
         receipt = receipt(input, context, result, document, result_document, next),
         {:ok, receipt_document} <- AuthoringReview.encode_receipt(receipt),
         :ok <-
           Journal.authority_event(
             db,
             next,
             "authoring_candidate_reviewed",
             input["operation_id"]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_authoring_reviews (#{@columns}) VALUES (?,?,?,?,?,?,?)",
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
           {:ok, :existing, r} -> {:rollback, {:unchanged, {:ok, r}}}
           {:error, reason} when reason in @denials -> {:rollback, {:policy, reason}}
           :not_found -> {:rollback, {:policy, :stale_authoring_reference}}
           {:error, reason} -> {:rollback, reason}
           _ -> {:rollback, :corrupt_authoring_reviews}
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
             "SELECT receipt_document FROM profile_authoring_reviews WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, epoch, operation]
           ) do
      case rows do
        [] -> :not_found
        [[r]] -> AuthoringReview.decode_receipt(r)
        _ -> corrupt()
      end
    else
      false -> {:error, :invalid_authoring_review}
      error -> error
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [31, 32, 33, 34, 35, 36] -> validate(db)
      {:ok, [[v]]} when v in 4..30 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- AuthoringCandidates.validate(db),
         {:ok, objects} <- ownership(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_authoring_reviews ORDER BY revision LIMIT 1025"
           ),
         true <- length(rows) <= 1024,
         {:ok, [[maximum, epoch]]} <- meta(db),
         {:ok, links} <-
           query(
             db,
             "SELECT r.revision,j.event_type,j.entity_id,p.principal_id FROM profile_authoring_reviews r LEFT JOIN authority_journal j ON j.revision=r.revision LEFT JOIN principals p ON p.principal_id=r.principal_id ORDER BY r.revision LIMIT 1025"
           ),
         true <- length(links) == length(rows),
         links = Map.new(links, fn [r, e, o, p] -> {r, {e, o, p}} end),
         true <- map_size(links) == length(rows),
         {:ok, candidates} <- retained_candidates(db),
         :ok <- validate_rows(rows, links, objects, candidates, maximum, epoch),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='authoring_candidate_reviewed'"
           ),
         true <- count == length(rows),
         :ok <- capacity(db, 0, 0, false),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp retained_candidates(db) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT principal_id,authority_epoch,operation_id,input_document,assessment_document,receipt_document FROM profile_authoring_candidates LIMIT 1025"
           ),
         true <- length(rows) <= 1024 do
      Enum.reduce_while(rows, {:ok, %{}}, fn [principal, epoch, operation, i, a, r], {:ok, acc} ->
        with {:ok, input} <- AuthoringCandidate.decode(i),
             {:ok, assessment} <- AuthoringCandidate.decode_assessment(a),
             {:ok, receipt} <- AuthoringCandidate.decode_receipt(r) do
          context = %{candidate_input: input, assessment: assessment, candidate_receipt: receipt}
          {:cont, {:ok, Map.put(acc, {principal, epoch, operation}, context)}}
        else
          _ -> {:halt, corrupt()}
        end
      end)
    else
      _ -> corrupt()
    end
  end

  defp validate_rows(rows, links, objects, candidates, maximum, epoch) do
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
               links[revision] == {"authoring_candidate_reviewed", operation, principal},
           {:ok, i} <- AuthoringReview.decode(input),
           {:ok, r} <- AuthoringReview.decode_result(result),
           {:ok, s} <- AuthoringReview.decode_receipt(stored),
           true <-
             i["authority_epoch"] == original_epoch and i["operation_id"] == operation and
               i["expected_revision"] == revision - 1,
           ref = i["review"]["candidate_ref"],
           context when is_map(context) <-
             candidates[{principal, ref["authority_epoch"], ref["operation_id"]}],
           true <- candidate_matches?(context, ref),
           :ok <- envelope_ref(objects, principal, i),
           :ok <- correspondence(i, context, r, objects, principal),
           true <- s == receipt(i, context, r, input, result, revision),
           do: {:cont, :ok},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp candidate(db, principal, ref) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT input_document,assessment_document,receipt_document FROM profile_authoring_candidates WHERE principal_id=? AND authority_epoch=? AND operation_id=?",
             [principal, ref["authority_epoch"], ref["operation_id"]]
           ) do
      case rows do
        [] ->
          :not_found

        [[i, a, r]] ->
          with {:ok, input} <- AuthoringCandidate.decode(i),
               {:ok, assessment} <- AuthoringCandidate.decode_assessment(a),
               {:ok, receipt} <- AuthoringCandidate.decode_receipt(r),
               true <- candidate_matches?(%{candidate_receipt: receipt}, ref),
               do:
                 {:ok,
                  %{candidate_input: input, assessment: assessment, candidate_receipt: receipt}},
               else: (_ -> {:error, :stale_authoring_reference})

        _ ->
          corrupt()
      end
    end
  end

  defp candidate_matches?(%{candidate_receipt: receipt}, ref),
    do: Enum.all?(~w(revision input_sha256 assessment_sha256), &(receipt[&1] == ref[&1]))

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

  defp envelope_ref(_, _, %{"review" => %{"mode" => "source"}}), do: :ok

  defp envelope_ref(objects, principal, input) do
    ref = input["review"]["envelope_ref"]

    case objects[{principal, ref["object_digest"]}] do
      nil ->
        :not_found

      %{"object" => %{"kind" => "envelope"}, "first_revision" => first} ->
        if first == ref["first_revision"] and first <= input["expected_revision"],
          do: :ok,
          else: {:error, :stale_authoring_reference}

      _ ->
        {:error, :stale_authoring_reference}
    end
  end

  defp read_requirements(context, objects, principal, input) do
    request = context.candidate_input["request"]
    refs = [request["base_draft_ref"] | request["source_refs"]]

    refs =
      if input["review"]["mode"] == "complete",
        do: refs ++ request["fixture_refs"] ++ [input["review"]["envelope_ref"]],
        else: refs

    imported = Enum.map(refs, &objects[{principal, &1["object_digest"]}])
    bundle = context.candidate_receipt["bundle"]

    if bundle,
      do:
        imported ++
          [%{"object" => bundle, "first_revision" => context.candidate_receipt["revision"]}],
      else: imported
  end

  defp correspondence(input, context, result, objects, principal) do
    source = result["source"]
    request = context.candidate_input["request"]
    sources = Enum.map(request["source_refs"], &objects[{principal, &1["object_digest"]}])
    required = source["required_paths"]
    evidence = input["review"]["evidence"]
    unresolved = input["review"]["unresolved_paths"]
    counts = Enum.frequencies_by(evidence, & &1["instance_path"])
    covered = Enum.filter(required, &(Map.get(counts, &1, 0) == 1 and &1 not in unresolved))
    missing = Enum.filter(required, &(Map.get(counts, &1, 0) == 0 and &1 not in unresolved))
    ambiguous = Enum.filter(required, &(Map.get(counts, &1, 0) > 1))

    valid =
      context.candidate_receipt["revision"] <= input["expected_revision"] and
        context.assessment["disposition"] == "compatible" and
        source["basis_sha256"] == context.candidate_receipt["basis_sha256"] and
        source["draft_sha256"] == context.assessment["draft_sha256"] and
        source["sources_sha256"] == AuthoringReview.sources_digest(sources) and
        source["evidence_sha256"] == AuthoringReview.evidence_digest(evidence, unresolved) and
        source["covered_paths"] == covered and source["missing_paths"] == missing and
        source["ambiguous_paths"] == ambiguous and source["unresolved_paths"] == unresolved and
        Enum.all?(
          evidence,
          &(&1["instance_path"] in required and
              Enum.any?(sources, fn s -> s["object"]["object_digest"] == &1["source_ref"] end))
        ) and
        Enum.all?(unresolved, &(&1 in required)) and
        result_mode?(input, result, objects, principal)

    if valid, do: :ok, else: {:error, :invalid_authoring_review}
  end

  defp result_mode?(%{"review" => %{"mode" => "source"}}, r, _, _),
    do: r["envelope"] == nil and r["fixtures"] == nil

  defp result_mode?(input, r, objects, principal) do
    owned = objects[{principal, input["review"]["envelope_ref"]["object_digest"]}]

    r["envelope"] != nil and r["fixtures"] != nil and
      r["envelope"]["envelope_sha256"] == owned["object"]["payload_sha256"]
  end

  defp receipt(input, context, result, document, result_document, revision) do
    source = result["source"]["status"]
    home = if result["envelope"], do: "matched", else: "not_assessed"

    fixtures =
      if result["fixtures"],
        do: result["fixtures"]["status"],
        else:
          if(context.candidate_input["request"]["fixture_refs"] == [],
            do: "not_supplied",
            else: "not_assessed"
          )

    %{
      "authority_epoch" => input["authority_epoch"],
      "operation_id" => input["operation_id"],
      "revision" => revision,
      "input_sha256" => AuthoringProducer.sha(document),
      "candidate_revision" => context.candidate_receipt["revision"],
      "basis_sha256" => result["source"]["basis_sha256"],
      "result_sha256" => AuthoringProducer.sha(result_document),
      "source_review" => source,
      "home_consumption" => home,
      "fixture_status" => fixtures,
      "proposal_status" => AuthoringReview.proposal_status(source, home, fixtures)
    }
  end

  defp capacity(db, input, result, new? \\ true) do
    with {:ok, [[count, inputs, results]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(result_document AS BLOB))),0) FROM profile_authoring_reviews"
           ),
         true <-
           count + if(new?, do: 1, else: 0) <= 1024 and inputs + input <= 4_194_304 and
             results + result <= 4_194_304,
         do: :ok,
         else: (_ -> {:error, :authoring_review_capacity})
  end

  defp meta(db),
    do:
      query(
        db,
        "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
      )

  defp equal(v, v, _), do: :ok
  defp equal(_, _, e), do: {:error, e}
  defp corrupt, do: {:error, :corrupt_authoring_reviews}
end
