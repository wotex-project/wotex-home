defmodule WotexHome.Durable.Store.ExternalObservations do
  @moduledoc """
  Retains original external observations with current pointers and sequence guards.

  The domain resolves the current target/read scope, recognizes original
  report-owner operations and journals exact projected report/value witnesses.
  Current pointers and retained sequence protection remain separate from
  immutable receipts; clearing current use does not rewrite prior observations.

  Store owns the borrowed connection, transaction and receipt clock. This
  collaborator performs no transport or source publication. Report custody,
  current source lease and interpretation are checked by their owning boundaries
  before a value can become current reported state.
  """

  alias WotexHome.Durable.{Registry, Store.ExternalTargets}
  alias WotexHome.Durable.Store.Journal

  alias WotexHome.Profiles.{
    ExternalObservation,
    ExternalTarget,
    ReadDeclarationCodec,
    RetainedJSON,
    RetainedSource
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @columns ~w(report_owner_epoch report_id input_document outcome_document receipt_document revision)
  @tables %{
    "profile_external_observations" => @columns,
    "profile_external_observation_current" => ~w(target_id capability_key revision),
    "profile_external_observation_sequences" =>
      ~w(target_id channel_id source_epoch sequence revision)
  }
  def tables, do: @tables

  def read_scope(db, credential, target, key) do
    with true <- WotexHome.Id.valid?(target) and WotexHome.Id.valid?(key),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- WotexHome.Durable.Store.Access.authenticate(db, hash),
         true <- "read" in permissions,
         {:ok, grants} <- WotexHome.Durable.Store.Access.allowed_targets(db, principal),
         true <- target in grants,
         :ok <- validate(db),
         {:ok, current} <- ExternalTargets.cursor(db, target),
         true <- current.selection_revision > 0,
         {:ok, thing} <- Registry.decode_thing(current.outcome["thing_document"]),
         {:ok, cap} <- WotexHome.Semantics.Thing.capability(thing, key),
         {:ok, [[revision, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT o.outcome_document,o.receipt_document FROM profile_external_observation_current c JOIN profile_external_observations o ON o.revision=c.revision WHERE c.target_id=? AND c.capability_key=?",
             [target, key]
           ),
         {:ok, report} <- current_report(rows),
         do:
           {:ok,
            %{
              target_id: target,
              capability_key: key,
              current: current,
              capability: cap,
              report: report,
              revision: revision,
              epoch: epoch
            }},
         else: (
           false -> {:error, :permission_denied}
           :error -> {:error, :unsupported_capability}
           error -> error
         )
  end

  def original_status(db, credential, input) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, _, permissions} <- WotexHome.Durable.Store.Access.authenticate(db, hash),
         true <- "read" in permissions,
         {:ok, receipt} <- original(db, input),
         {:ok, _} <- read_scope(db, credential, receipt["target_id"], receipt["capability_key"]),
         do: {:ok, receipt},
         else: (
           false -> {:error, :permission_denied}
           error -> error
         )
  end

  def preview(scope, reason, {boot, now}) do
    base = %{
      "format" => "home-external-reported-value-v1",
      "target_id" => scope.target_id,
      "capability_key" => scope.capability_key,
      "store_revision" => scope.revision,
      "authority_epoch" => scope.epoch,
      "selection_revision" => scope.current.selection_revision,
      "resource_revision" => scope.current.resource_revision,
      "report_revision" => nil,
      "value" => nil,
      "freshness" => "unknown",
      "reason" => reason,
      "age_ms" => nil,
      "remaining_ms" => 0
    }

    if scope.report do
      r = scope.report.receipt
      v = scope.report.value

      age =
        if r["store_boot_epoch"] == boot and now >= r["received_store_ms"],
          do: now - r["received_store_ms"]

      why =
        cond do
          reason != nil ->
            reason

          r["selection_revision"] != scope.current.selection_revision ->
            "external_selection_changed"

          age == nil ->
            "old_store_boot"

          age >= scope.capability.freshness_ms ->
            "expired"

          v["quality"] != "usable" ->
            v["quality"]

          v["sequence"] == nil ->
            "missing_sequence"

          v["continuity"] not in ~w(baseline continuous) ->
            v["continuity"]

          true ->
            nil
        end

      Map.merge(base, %{
        "report_revision" => r["revision"],
        "value" => if(why == nil, do: v),
        "freshness" =>
          if(why == nil, do: "fresh", else: if(why == "expired", do: "stale", else: "unknown")),
        "reason" => why,
        "age_ms" => age,
        "remaining_ms" => if(why == nil, do: scope.capability.freshness_ms - age, else: 0)
      })
    else
      Map.merge(base, %{"freshness" => "missing", "reason" => reason || "missing"})
    end
  end

  defp current_report([]), do: {:ok, nil}

  defp current_report([[o, r]]) do
    with {:ok, outcome} <- ExternalObservation.decode_outcome(o),
         {:ok, receipt} <- ExternalObservation.decode_receipt(r),
         {:ok, value} <- RetainedJSON.decode(outcome["value_document"]),
         do: {:ok, %{receipt: receipt, outcome: outcome, value: value}}
  end

  defp current_report(_), do: corrupt()

  def original(db, input) do
    with {:ok, document} <- ExternalObservation.encode(input),
         :ok <- validate(db),
         {:ok, rows} <-
           query(
             db,
             "SELECT input_document,receipt_document FROM profile_external_observations WHERE report_owner_epoch=? AND report_id=?",
             [input["report_owner_epoch"], input["report_id"]]
           ) do
      case rows do
        [] -> :not_found
        [[^document, r]] -> ExternalObservation.decode_receipt(r)
        [_] -> {:error, :external_observation_conflict}
        _ -> corrupt()
      end
    end
  end

  def retain_tx(db, input, prepared, basis, clock) do
    case original(db, input) do
      {:ok, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
      :not_found -> retain_new(db, input, prepared, basis, clock)
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp retain_new(db, input, prepared, basis, clock) do
    with {:ok, current} <- ExternalTargets.observation_basis(db, basis.source),
         true <- current == basis.context,
         {:ok, input_doc} <- ExternalObservation.encode(input),
         {:ok, outcome_doc} <- ExternalObservation.encode_outcome(prepared.outcome),
         :ok <- capacity(db, byte_size(input_doc), byte_size(outcome_doc)),
         :ok <- sequence(db, current.target_id, prepared.value),
         {:ok, next} <- Journal.next_revision(db),
         receipt = receipt(input, input_doc, outcome_doc, prepared, current, next, clock),
         {:ok, receipt_doc} <- ExternalObservation.encode_receipt(receipt),
         :ok <-
           Journal.authority_event(db, next, "external_observation_recorded", current.target_id),
         {:ok, []} <-
           query(db, "INSERT INTO profile_external_observations VALUES (?,?,?,?,?,?)", [
             input["report_owner_epoch"],
             input["report_id"],
             input_doc,
             outcome_doc,
             receipt_doc,
             next
           ]),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_external_observation_current VALUES (?,?,?) ON CONFLICT(target_id,capability_key) DO UPDATE SET revision=excluded.revision",
             [current.target_id, prepared.capability.key, next]
           ),
         :ok <- retain_sequence(db, current.target_id, prepared.value, next),
         :ok <- validate(db),
         do: {:commit, {:ok, receipt}},
         else: (
           false -> {:rollback, {:policy, :external_selection_changed}}
           {:error, :corrupt_external_observations} -> {:rollback, :corrupt_external_observations}
           {:error, r} when is_atom(r) -> {:rollback, {:policy, r}}
           {:error, r} -> {:rollback, r}
           _ -> {:rollback, :corrupt_external_observations}
         )
  end

  def capacity(db, input, outcome, new? \\ true) do
    with {:ok, [[count, inputs, outcomes]]} <-
           query(
             db,
             "SELECT COUNT(*),COALESCE(SUM(length(CAST(input_document AS BLOB))),0),COALESCE(SUM(length(CAST(outcome_document AS BLOB))),0) FROM profile_external_observations"
           ),
         {:ok, [[sequences]]} <-
           query(db, "SELECT COUNT(*) FROM profile_external_observation_sequences"),
         true <-
           count + if(new?, do: 1, else: 0) <= 4096 and inputs + input <= 2_097_152 and
             outcomes + outcome <= 16_777_216 and sequences <= 8192,
         do: :ok,
         else: (_ -> {:error, :external_observation_capacity})
  end

  defp sequence(_, _, %{"sequence" => nil}), do: :ok

  defp sequence(db, target, v) do
    with {:ok, rows} <-
           query(
             db,
             "SELECT sequence FROM profile_external_observation_sequences WHERE target_id=? AND channel_id=? AND source_epoch=?",
             [target, v["channel_id"], v["source_epoch"]]
           ),
         {:ok, n} <- uint(v["sequence"]) do
      case rows do
        [] ->
          :ok

        [[old]] ->
          with {:ok, previous} <- uint(old) do
            cond do
              n == previous ->
                {:error, :external_observation_duplicate}

              n < previous ->
                {:error, :stale_external_sequence}

              v["continuity"] == "continuous" and n != previous + 1 ->
                {:error, :continuity_mismatch}

              true ->
                :ok
            end
          end

        _ ->
          corrupt()
      end
    end
  end

  defp retain_sequence(_, _, %{"sequence" => nil}, _), do: :ok

  defp retain_sequence(db, target, v, revision) do
    with {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_external_observation_sequences VALUES (?,?,?,?,?) ON CONFLICT(target_id,channel_id,source_epoch) DO UPDATE SET sequence=excluded.sequence,revision=excluded.revision",
             [target, v["channel_id"], v["source_epoch"], v["sequence"], revision]
           ),
         do: :ok
  end

  def clear_current_if_present(db, target) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [35, 36, 37] ->
        with {:ok, []} <-
               query(db, "DELETE FROM profile_external_observation_current WHERE target_id=?", [
                 target
               ]),
             do: :ok

      {:ok, [[v]]} when v in 4..34 ->
        :ok

      _ ->
        corrupt()
    end
  end

  def validate_if_current(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[v]]} when v in [35, 36, 37] -> validate(db)
      {:ok, [[v]]} when v in 4..34 -> :ok
      _ -> corrupt()
    end
  end

  def validate(db) do
    with :ok <- ExternalTargets.validate(db),
         :ok <- capacity(db, 0, 0, false),
         {:ok, [[maximum, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         {:ok, rows} <-
           query(
             db,
             "SELECT #{Enum.join(@columns, ",")} FROM profile_external_observations ORDER BY revision LIMIT 4097"
           ),
         true <- length(rows) <= 4096,
         {:ok, records, sequences, latest} <- validate_rows(db, rows, maximum, epoch),
         :ok <- pointers(db, records, sequences, latest),
         {:ok, [[count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type='external_observation_recorded'"
           ),
         true <- count == length(rows),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp validate_rows(db, rows, maximum, epoch) do
    Enum.reduce_while(rows, {:ok, %{}, %{}, %{}}, fn [
                                                       owner,
                                                       id,
                                                       input_doc,
                                                       outcome_doc,
                                                       receipt_doc,
                                                       revision
                                                     ],
                                                     {:ok, records, sequences, latest} ->
      with {:ok, i} <- ExternalObservation.decode(input_doc),
           {:ok, o} <- ExternalObservation.decode_outcome(outcome_doc),
           {:ok, r} <- ExternalObservation.decode_receipt(receipt_doc),
           {:ok, value} <- RetainedJSON.decode(o["value_document"]),
           true <-
             i == %{"report_owner_epoch" => owner, "report_id" => id} and
               r["report_owner_epoch"] == owner and r["report_id"] == id and
               r["revision"] == revision and revision in 1..maximum and
               r["authority_epoch"] in 1..epoch,
           true <-
             r["input_sha256"] == ExternalObservation.sha(input_doc) and
               r["outcome_sha256"] == ExternalObservation.sha(outcome_doc) and
               r["report_sha256"] == ExternalObservation.report_sha(o["report_document"]) and
               r["value_sha256"] == o["value_sha256"] and
               r["source_selection_sha256"] == o["source_selection_sha256"] and
               r["selection_revision"] == o["target_selection_revision"],
           true <- value["receipt_time"]["epoch"] == owner,
           {:ok, [["external_observation_recorded", target]]} <-
             query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
               revision
             ]),
           true <- target == r["target_id"],
           :ok <- target_correspondence(db, r, o, value),
           :ok <- historical_sequence(sequences, target, value),
           seqs =
             if(value["sequence"] == nil,
               do: sequences,
               else:
                 Map.put(
                   sequences,
                   {target, value["channel_id"], value["source_epoch"]},
                   {value["sequence"], revision}
                 )
             ),
           record = %{receipt: r, outcome: o, value: value},
           do:
             {:cont,
              {:ok, Map.put(records, revision, record), seqs,
               Map.put(latest, {target, r["capability_key"]}, revision)}},
           else: (_ -> {:halt, corrupt()})
    end)
  end

  defp target_correspondence(db, r, o, v) do
    with {:ok, [[target_doc, generation, "select"]]} <-
           query(
             db,
             "SELECT outcome_document,generation,action FROM profile_external_target_history WHERE target_id=? AND revision=?",
             [r["target_id"], r["selection_revision"]]
           ),
         {:ok, target} <- ExternalTarget.decode_outcome(target_doc),
         {:ok, thing} <- Registry.decode_thing(target["thing_document"]),
         {:ok, cap} <- WotexHome.Semantics.Thing.capability(thing, r["capability_key"]),
         {:ok, %{"data" => declaration}} <- ReadDeclarationCodec.decode(cap.record),
         {:ok, source} <- RetainedSource.decode(target["source_document"]),
         {:ok, [[target_receipt]]} <-
           query(
             db,
             "SELECT receipt_document FROM profile_external_target_operations WHERE revision=?",
             [r["selection_revision"]]
           ),
         {:ok, tr} <- ExternalTarget.decode_receipt(target_receipt),
         true <-
           r["resource_revision"] == generation - 1 and
             r["trust_revision"] == tr["trust_revision"] and
             r["policy_generation"] == tr["policy_generation"] and
             r["source_selection_sha256"] == source.sha256 and
             o["declaration_sha256"] == cap.record["declaration_sha256"],
         true <-
           v["channel_id"] == declaration["channel_id"] and
             v["source_ref"] == source.inputs["source"]["source_ref"] and
             v["source_epoch"] == source.inputs["source"]["source_epoch"],
         true <-
           Enum.all?(
             ~w(contract_ref contract_sha256 value_kind consumption_sha256),
             &(v[&1] == declaration[&1])
           ) and v["semantic"] == declaration["semantic_ref"] and v["unit"] == declaration["unit"],
         true <- v["quality"] != "usable" or valid_value?(v["normalized_value"], cap),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp valid_value?(v, %{value_kind: "integer", constraints: c}) do
    case signed(v) do
      {:ok, n} -> n >= c["min"] and n <= c["max"]
      _ -> false
    end
  end

  defp valid_value?(v, %{value_kind: "boolean"}),
    do:
      WotexHome.Profiles.EnvelopeCodec.keys?(v, ~w(type value)) and v["type"] == "boolean" and
        is_boolean(v["value"])

  defp valid_value?(v, %{value_kind: "external"}),
    do: is_map(v) and not is_struct(v) and is_binary(v["type"])

  defp historical_sequence(_, _, %{"sequence" => nil}), do: :ok

  defp historical_sequence(sequences, target, v) do
    with {:ok, n} <- uint(v["sequence"]) do
      case sequences[{target, v["channel_id"], v["source_epoch"]}] do
        nil ->
          :ok

        {previous, _} ->
          with {:ok, old} <- uint(previous),
               true <- n > old and (v["continuity"] != "continuous" or n == old + 1),
               do: :ok,
               else: (_ -> corrupt())
      end
    end
  end

  defp pointers(db, records, sequences, latest) do
    with {:ok, cursors} <-
           query(
             db,
             "SELECT target_id,channel_id,source_epoch,sequence,revision FROM profile_external_observation_sequences"
           ),
         true <- Map.new(cursors, fn [t, c, e, s, r] -> {{t, c, e}, {s, r}} end) == sequences,
         {:ok, current} <-
           query(
             db,
             "SELECT target_id,capability_key,revision FROM profile_external_observation_current"
           ),
         {:ok, selected_rows} <-
           query(
             db,
             "SELECT target_id,selection_revision FROM profile_external_target_current WHERE state='selected'"
           ),
         selected = Map.new(selected_rows, fn [target, revision] -> {target, revision} end),
         expected =
           Map.filter(latest, fn {{target, _}, revision} ->
             records[revision].receipt["selection_revision"] == selected[target]
           end),
         true <- Map.new(current, fn [t, c, r] -> {{t, c}, r} end) == expected,
         true <-
           Enum.all?(current, fn [t, c, r] ->
             record = records[r]

             record != nil and latest[{t, c}] == r and record.receipt["target_id"] == t and
               record.receipt["capability_key"] == c and
               match?(
                 {:ok, [[_]]},
                 query(
                   db,
                   "SELECT target_id FROM profile_external_target_current WHERE target_id=? AND state='selected' AND selection_revision=?",
                   [t, record.receipt["selection_revision"]]
                 )
               )
           end),
         do: :ok,
         else: (_ -> corrupt())
  end

  defp receipt(i, input_doc, outcome_doc, p, c, revision, {boot, received}) do
    %{
      "authority_epoch" => c.epoch,
      "report_owner_epoch" => i["report_owner_epoch"],
      "report_id" => i["report_id"],
      "revision" => revision,
      "input_sha256" => ExternalObservation.sha(input_doc),
      "target_id" => c.target_id,
      "capability_key" => p.capability.key,
      "selection_revision" => c.current.selection_revision,
      "resource_revision" => c.current.resource_revision,
      "trust_revision" => c.selection_receipt["trust_revision"],
      "policy_generation" => c.policy,
      "source_selection_sha256" => p.outcome["source_selection_sha256"],
      "report_sha256" => ExternalObservation.report_sha(p.outcome["report_document"]),
      "value_sha256" => p.outcome["value_sha256"],
      "outcome_sha256" => ExternalObservation.sha(outcome_doc),
      "store_boot_epoch" => boot,
      "received_store_ms" => received
    }
  end

  defp signed(%{"type" => "sint", "value" => value} = v)
       when is_binary(value) and byte_size(value) <= 20 do
    with true <- WotexHome.Profiles.EnvelopeCodec.keys?(v, ~w(type value)),
         {n, ""} <- Integer.parse(value),
         true <-
           n in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
             Integer.to_string(n) == value,
         do: {:ok, n},
         else: (_ -> :error)
  end

  defp signed(_), do: :error

  defp uint(s) when is_binary(s) and byte_size(s) <= 20 do
    case Integer.parse(s) do
      {n, ""} when n in 0..18_446_744_073_709_551_615 ->
        if Integer.to_string(n) == s, do: {:ok, n}, else: corrupt()

      _ ->
        corrupt()
    end
  end

  defp uint(_), do: corrupt()
  defp corrupt, do: {:error, :corrupt_external_observations}
end
