defmodule WotexHome.Durable.Store.ExternalInputCollection do
  @moduledoc """
  Collects a current external-input snapshot for one complete authorized scope.

  Native callers use `WotexHome.Authority.external_routine_facts/3`.
  `WotexHome.Durable.Store.ExternalInputCollection.collect/4` borrows Store's
  SQLite connection, owned configuration and caller credential. Its fourth
  argument is a proper list of 1 through 32 exact string-keyed maps containing
  `"target_id"` and `"capability_key"`, unique and sorted by that pair. The scope
  supplies no report, Mapping, clock or prepared context.

  Success is `{:ok, snapshot}`: a closed string-keyed map containing the
  authority epoch, Store revision, Store boot epoch, one final `"sampled_ms"`
  and `"items"` in scope order. Each item includes its established revisions,
  report reference, original owner expiry, binding, projection and refusal
  reason; unavailable fields remain `nil`. A `nil` reason means the qualified
  report is usable at that final sample. Semantic absences remain explicit
  items rather than silently shrinking the requested scope.

  Before slot lookup or private reads, every target must be granted to the
  caller with `rule:review` and `read`. The original installer separately needs
  current `qualify:profile`, `rule:review`, `read` and a target grant; the selector
  and trust approver must also retain their own required permissions and grants.
  The caller cannot supply or borrow an installer's prepared authorization.

  Collection rebuilds actual private objects, selected native producer/source,
  current signed review, original report interpretation and consumed lifetime.
  It repeats the complete reached basis across the whole scope under one shared
  ten-second budget. One final Store elapsed sample classifies all reports
  without renewing their original receipt or expiry. A changed witness refuses
  the complete call as `{:error, :external_input_basis_changed}`; owner failures
  or exhausted preparation return `{:error, :external_input_unavailable}`.
  Authentication, malformed scope, corruption and limit errors likewise return
  `{:error, reason}` without a partial snapshot.

  Store keeps connection and transaction ownership. This read creates no lease,
  operation, journal row, revision, input change or edge memory. The snapshot
  establishes no predicate truth, rule admission, physical qualification or
  permission to send a device effect.
  """

  alias WotexHome.{Id, Durable.Registry}

  alias WotexHome.Durable.Store.{
    Access,
    ExternalInputContext,
    ExternalInputMath,
    ExternalInputs,
    ExternalObservations,
    ExternalTargets,
    MaintenanceWriter
  }

  alias WotexHome.Profiles.{
    EnvelopeCodec,
    ExternalObservation,
    ExternalObservationPreparation,
    ExternalReportOwner,
    RetainedJSON
  }

  alias WotexHome.Rules.{
    ExternalFact,
    ExternalInput,
    ExternalInputFormat,
    ExternalInputOperation,
    ExternalInputPackage,
    ExternalInputRuntime
  }

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @nullable ~w(install_revision selection_revision resource_revision report_revision report_ref owner_expires_ms binding_basis projection reason)
  @context_keys ~w(authority_epoch selection_revision resource_revision binding_revision trust_revision policy_generation selection_author trust_author declaration)
  @lifetime ~w(channel_id expires_at_us format owner_epoch receipt_monotonic_us report_id report_sha256 sequence source_epoch source_owner_epoch source_ref source_selection_sha256 state)
  @maximum 9_223_372_036_854_775_807

  def collect(db, config, credential, scope) do
    deadline = now() + 10_000

    with {:ok, pairs} <- scope(scope),
         {:ok, actor} <- authorize(db, credential, pairs),
         :ok <- MaintenanceWriter.guard(db),
         :ok <- ExternalInputs.validate_if_current(db),
         :ok <- ExternalTargets.validate_if_current(db),
         :ok <- ExternalObservations.validate_if_current(db),
         {:ok, meta} <- meta(db),
         {:ok, opening} <- pass(db, config, credential, pairs, deadline, nil),
         {:ok, closing} <- pass(db, config, credential, pairs, deadline, opening),
         true <- fingerprints(opening) == fingerprints(closing),
         {:ok, ^actor} <- authorize(db, credential, pairs),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, ^meta} <- meta(db),
         sampled = now() - config.clock_origin,
         {:ok, items} <- finish(closing, sampled),
         result = %{
           "format" => "wotex-home.external-input-snapshot@1",
           "scope" => "qualified_external_input_snapshot_only",
           "authority_epoch" => meta.epoch,
           "store_revision" => meta.revision,
           "store_boot_epoch" => config.clock_epoch,
           "sampled_ms" => sampled,
           "items" => items
         },
         :ok <- snapshot(result),
         :ok <- budget(deadline, 0),
         do: {:ok, result},
         else: (
           false -> {:error, :external_input_basis_changed}
           {:ok, _} -> {:error, :external_input_basis_changed}
           {:error, _} = error -> error
           _ -> {:error, :corrupt_external_inputs}
         )
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  defp scope(value), do: scope(value, [], 0)
  defp scope([], [], _), do: {:error, :invalid_external_input}

  defp scope([], reversed, _) do
    pairs = Enum.reverse(reversed)

    if pairs == Enum.sort(Enum.uniq(pairs)),
      do: {:ok, pairs},
      else: {:error, :invalid_external_input}
  end

  defp scope([_ | _], _, 32), do: {:error, :external_input_limit}

  defp scope([item | rest], pairs, count) do
    if EnvelopeCodec.keys?(item, ~w(capability_key target_id)) and
         Id.valid?(item["target_id"]) and Id.valid?(item["capability_key"]),
       do: scope(rest, [{item["target_id"], item["capability_key"]} | pairs], count + 1),
       else: {:error, :invalid_external_input}
  end

  defp scope(_, _, _), do: {:error, :invalid_external_input}

  defp authorize(db, credential, pairs) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- Enum.all?(~w(rule:review read), &(&1 in permissions)),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- Enum.all?(pairs, fn {target, _} -> MapSet.member?(grants, target) end),
         do: {:ok, {principal, permissions, grants}},
         else: (
           false -> {:error, :permission_denied}
           {:error, :invalid_credential} -> {:error, :unauthorized}
           error -> error
         )
  end

  defp meta(db) do
    with {:ok, [[epoch, revision]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='authority_epoch'),(SELECT value FROM meta WHERE key='revision')"
           ),
         true <-
           is_integer(epoch) and epoch in 1..@maximum and is_integer(revision) and
             revision in 0..@maximum,
         do: {:ok, %{epoch: epoch, revision: revision}},
         else: (
           false -> {:error, :corrupt_external_inputs}
           error -> error
         )
  end

  defp pass(db, config, credential, pairs, deadline, prior) do
    runtime = ExternalInputRuntime.current()

    with {:ok, entries} <-
           traverse(Enum.with_index(pairs), fn {{target, key}, index} ->
             previous = if prior, do: Enum.at(prior.entries, index)
             prepare(db, config, credential, target, key, deadline, runtime, previous)
           end),
         :ok <- source_guards(config, entries, deadline),
         :ok <- runtime_guard(runtime, entries),
         :ok <- budget(deadline, 0),
         do: {:ok, %{entries: entries, runtime: runtime}}
  end

  defp prepare(db, config, credential, target, key, deadline, runtime, previous) do
    item =
      Map.new(@nullable, &{&1, nil})
      |> Map.merge(%{"target_id" => target, "capability_key" => key})

    entry = %{
      item: item,
      evidence: %{},
      frame: nil,
      bounds: nil,
      report: nil,
      witness: nil,
      closing_expired: false,
      projection_reason: nil
    }

    with {:ok, rows} <-
           query(
             db,
             """
             SELECT c.state,c.install_revision,c.generation,c.history_revision,h.outcome_document,o.principal_id
             FROM routine_external_input_current c
             JOIN routine_external_input_history h ON h.target_id=c.target_id AND h.capability_key=c.capability_key AND h.revision=c.history_revision
             JOIN routine_external_input_operations o ON o.revision=c.install_revision
             WHERE c.target_id=? AND c.capability_key=?
             """,
             [target, key]
           ) do
      entry = put_in(entry.evidence[:slot], rows)

      case rows do
        [] ->
          unavailable(entry, "input_not_installed")

        [["revoked", install, _, _, _, _]] ->
          unavailable(put_in(entry.item["install_revision"], install), "input_revoked")

        [["installed", install, _, _, outcome, principal]] ->
          entry = put_in(entry.item["install_revision"], install)

          with {:ok, retained} <- ExternalInputOperation.decode_outcome(outcome),
               {:ok, package} <- ExternalInputPackage.decode(retained["package_document"]),
               {:ok, definition} <- ExternalInput.decode(package["data"]["definition_document"]) do
            installed(
              db,
              config,
              credential,
              entry,
              principal,
              retained,
              definition["data"],
              deadline,
              runtime,
              previous
            )
          end

        _ ->
          {:error, :corrupt_external_inputs}
      end
    end
  end

  defp installed(
         db,
         config,
         credential,
         entry,
         principal,
         retained,
         definition,
         deadline,
         runtime,
         previous
       ) do
    target = entry.item["target_id"]
    key = entry.item["capability_key"]

    cond do
      definition["context"]["store_boot_epoch"] != config.clock_epoch ->
        unavailable(entry, "old_store_boot")

      true ->
        with {:ok, cursor} <- ExternalTargets.cursor(db, target) do
          entry =
            if cursor.state == "selected",
              do: %{
                entry
                | item:
                    Map.merge(entry.item, %{
                      "selection_revision" => cursor.selection_revision,
                      "resource_revision" => cursor.resource_revision
                    })
              },
              else: entry

          entry = put_in(entry.evidence[:target], cursor)

          with true <-
                 cursor.state == "selected" and
                   config.external_target_boot[target] == cursor.selection_revision,
               {:ok, basis} <- ExternalInputContext.collection_basis(db, credential, target, key),
               entry = put_in(entry.evidence[:basis], basis) do
            with true <- durable_context(basis) == Map.take(definition["context"], @context_keys),
                 {:ok, installer} <- installer(db, principal, target),
                 {:ok, authors} <- ExternalInputContext.collection_authors(db, basis, target) do
              entry = put_in(entry.evidence[:authors], {installer, authors})

              with {:ok, r, sha} <- runtime,
                   {:ok, frame} <-
                     ExternalInputContext.collection_capture(
                       db,
                       config,
                       credential,
                       target,
                       key,
                       deadline,
                       {r, sha}
                     ),
                   true <- frame.context == definition["context"] do
                entry = %{entry | frame: frame}
                entry = put_in(entry.evidence[:capture], frame)

                with {:ok, _} <-
                       ExternalInputPackage.verify(
                         retained["package_document"],
                         frame.context,
                         config.qualification_case_keys,
                         config.qualification_decision_keys
                       ),
                     {:ok, binding} <- binding_basis(definition) do
                  entry = put_in(entry.item["binding_basis"], binding)
                  report(db, config, entry, definition, deadline, previous)
                else
                  {:error, code}
                  when code in [:invalid_external_input_decision, :qualification_unavailable] ->
                    unavailable(entry, "input_unqualified")

                  error ->
                    item_error(entry, error)
                end
              else
                false ->
                  unavailable(entry, "input_basis_changed")

                {:error, :runtime_artifact_unavailable} ->
                  unavailable(entry, "runtime_unavailable")

                error ->
                  item_error(entry, error)
              end
            else
              false -> unavailable(entry, "input_basis_changed")
              error -> item_error(entry, error)
            end
          else
            false -> unavailable(entry, "input_basis_changed")
            error -> item_error(entry, error)
          end
        end
    end
  end

  defp durable_context(basis) do
    selected = basis.selected

    %{
      "authority_epoch" => basis.epoch,
      "selection_revision" => selected.current.selection_revision,
      "resource_revision" => selected.current.resource_revision,
      "binding_revision" => selected.current.binding_revision,
      "trust_revision" => selected.selection_receipt["trust_revision"],
      "policy_generation" => selected.policy,
      "selection_author" => selected.principal,
      "trust_author" => basis.trust.principal,
      "declaration" => basis.declaration
    }
  end

  defp installer(db, principal, target) do
    with {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         true <- Enum.all?(~w(qualify:profile rule:review read), &(&1 in permissions)),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- MapSet.member?(grants, target),
         do: {:ok, {principal, permissions, grants}},
         else: (
           false -> {:item, "input_author_unavailable"}
           {:error, :principal_unavailable} -> {:item, "input_author_unavailable"}
           error -> error
         )
  end

  defp binding_basis(d) do
    Wotex.Routines.Input.binding_basis(d["mapping"], d["registry"], d["limits"])
  rescue
    _ -> {:item, "producer_unavailable"}
  end

  defp report(db, config, entry, definition, deadline, previous) do
    with {:ok, rows} <-
           query(
             db,
             """
             SELECT o.input_document,o.outcome_document,o.receipt_document
             FROM profile_external_observation_current c JOIN profile_external_observations o ON o.revision=c.revision
             WHERE c.target_id=? AND c.capability_key=?
             """,
             [entry.item["target_id"], entry.item["capability_key"]]
           ) do
      entry = put_in(entry.evidence[:report], rows)

      case rows do
        [] ->
          unavailable(entry, "missing_report")

        [[input, outcome, receipt]] ->
          with {:ok, _} <- ExternalObservation.decode(input),
               {:ok, outcome} <- ExternalObservation.decode_outcome(outcome),
               {:ok, receipt} <- ExternalObservation.decode_receipt(receipt),
               {:ok, raw} <- RetainedJSON.decode(outcome["report_document"]) do
            item =
              Map.merge(entry.item, %{
                "report_revision" => receipt["revision"],
                "report_ref" => %{
                  "owner_epoch" => receipt["report_owner_epoch"],
                  "report_id" => receipt["report_id"],
                  "report_sha256" => receipt["report_sha256"]
                }
              })

            entry = %{entry | item: item, report: raw}

            if receipt["store_boot_epoch"] != config.clock_epoch do
              unavailable(entry, "old_store_boot")
            else
              with {:ok, witness, expired} <- lifetime(config, receipt, deadline, previous),
                   :ok <- witness_matches(witness, receipt, raw, entry.frame.context),
                   {:ok, bounds} <-
                     ExternalInputMath.bounds(
                       config.clock_origin,
                       witness["receipt_monotonic_us"],
                       witness["expires_at_us"],
                       entry.frame.basis.declaration["freshness_ms"],
                       definition["mapping"]["basis"]["evidence"]["freshness_ms"]
                     ),
                   true <- bounds.received_store_ms == receipt["received_store_ms"] do
                entry = %{entry | bounds: bounds, witness: witness, closing_expired: expired}
                entry = put_in(entry.item["owner_expires_ms"], bounds.owner_expires_ms)
                project(entry, definition, outcome)
              else
                false -> unavailable(entry, "invalid")
                error -> item_error(entry, error)
              end
            end
          end

        _ ->
          {:error, :corrupt_external_observations}
      end
    end
  end

  defp lifetime(config, receipt, deadline, previous) do
    with :ok <- budget(deadline, 5000) do
      case ExternalReportOwner.lifetime(
             config.external_report_owner,
             receipt["report_owner_epoch"],
             receipt["report_id"]
           ) do
        {:ok, witness} ->
          if lifetime_shape?(witness),
            do: {:ok, witness, false},
            else: {:error, :external_input_unavailable}

        {:error, :external_report_retired} ->
          if previous && previous.witness &&
               previous.item["report_ref"] == %{
                 "owner_epoch" => receipt["report_owner_epoch"],
                 "report_id" => receipt["report_id"],
                 "report_sha256" => receipt["report_sha256"]
               }, do: {:ok, previous.witness, true}, else: {:item, "expired"}

        :not_found ->
          {:item, "missing_report"}

        {:error, :external_report_not_consumed} ->
          {:item, "missing_report"}

        {:error, :external_report_owner_changed} ->
          {:item, "source_unavailable"}

        {:error, :invalid_external_report_clock} ->
          {:item, "invalid"}

        _ ->
          {:error, :external_input_unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  defp lifetime_shape?(w) do
    EnvelopeCodec.keys?(w, @lifetime) and
      w["format"] == "wotex-home.external-report-lifetime@1" and w["state"] == "consumed" and
      Enum.all?(~w(owner_epoch source_owner_epoch source_epoch), &epoch?(w[&1])) and
      Enum.all?(~w(report_id source_ref channel_id), &Id.valid?(w[&1])) and
      Enum.all?(~w(report_sha256 source_selection_sha256), &EnvelopeCodec.digest?(w[&1])) and
      signed_clock?(w["receipt_monotonic_us"]) and signed_clock?(w["expires_at_us"]) and
      sequence_shape?(w["sequence"])
  end

  defp epoch?(v),
    do: is_binary(v) and byte_size(v) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, v)

  defp signed_clock?(v) when is_binary(v) and byte_size(v) in 1..20,
    do:
      v != "-0" and Regex.match?(~r/\A-?(0|[1-9][0-9]*)\z/, v) and
        String.to_integer(v) in (-@maximum - 1)..@maximum

  defp signed_clock?(_), do: false
  defp sequence_shape?(nil), do: true

  defp sequence_shape?(v) when is_binary(v) and byte_size(v) in 1..20,
    do:
      Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, v) and
        String.to_integer(v) <= 18_446_744_073_709_551_615

  defp sequence_shape?(_), do: false

  defp witness_matches(w, receipt, raw, context) do
    expected = %{
      "owner_epoch" => receipt["report_owner_epoch"],
      "report_id" => receipt["report_id"],
      "report_sha256" => receipt["report_sha256"],
      "source_owner_epoch" => context["source_owner_epoch"],
      "source_selection_sha256" => context["source_selection_sha256"],
      "source_ref" => raw["source_ref"],
      "source_epoch" => raw["source_epoch"],
      "channel_id" => raw["channel_id"],
      "sequence" => raw["sequence"]
    }

    if Map.take(w, Map.keys(expected)) == expected and
         raw["receipt_time"]["epoch"] == w["owner_epoch"] and
         raw["receipt_time"]["monotonic_us"] == w["receipt_monotonic_us"],
       do: :ok,
       else: {:item, "invalid"}
  end

  defp project(entry, d, outcome) do
    f = entry.frame

    with {:ok, native} <-
           ExternalObservationPreparation.build_native(
             f.basis.selected.input,
             Enum.sort_by(f.records, & &1["object"]["object_digest"]),
             f.source.selection,
             outcome["report_document"],
             f.basis.selected.current.outcome,
             f.context["selection_revision"]
           ),
         true <- native.outcome == outcome do
      entry = put_in(entry.evidence[:interpretation], native.outcome)

      with {:ok, metadata} <- metadata(entry, d),
           {:ok, projection} <-
             ExternalFact.project(native.native_value, d["mapping"], metadata, %{
               "envelope" => native.envelope,
               "consumer" => native.consumer,
               "reader_limits" => native.reader_limits,
               "registry" => d["registry"],
               "limits" => d["limits"]
             }) do
        {:ok, put_in(entry.item["projection"], projection)}
      else
        {:item, reason} ->
          {:ok, %{entry | projection_reason: reason}}

        {:error, :external_fact_limit} ->
          {:error, :external_input_limit}

        {:error, :external_fact_unavailable} ->
          {:ok, %{entry | projection_reason: "producer_unavailable"}}

        {:error, :stale_external_fact} ->
          unavailable(entry, "input_basis_changed")

        {:error, code} when code in [:unsupported_external_fact, :inexact_external_fact] ->
          {:ok, %{entry | projection_reason: "unsupported_external_input"}}

        _ ->
          {:ok, %{entry | projection_reason: "invalid"}}
      end
    else
      false -> unavailable(entry, "input_basis_changed")
      error -> item_error(entry, error)
    end
  end

  defp metadata(entry, d) do
    r = entry.report
    m = d["mapping"]
    ref = entry.item["report_ref"]

    with {:ok, id} <-
           ExternalInputMath.fact_id(
             entry.item["target_id"],
             entry.item["capability_key"],
             entry.item["install_revision"],
             ref["owner_epoch"],
             ref["report_id"],
             ref["report_sha256"]
           ),
         {:ok, time} <- source_time(r["source_time"], m["observation"]["source_time_basis"]),
         {:ok, sequence} <- sequence(r["sequence"]),
         {:ok, continuity, replay} <- continuity(r["continuity"]) do
      {:ok,
       Map.merge(time, %{
         "id" => id,
         "thing_id" => WotexHome.Rules.KernelMapping.thing_iri(entry.item["target_id"]),
         "affordance_type" => m["affordance"]["kind"],
         "affordance_name" => m["affordance"]["name"],
         "source_class" => "device_report",
         "source_id" => r["source_ref"],
         "source_epoch" => r["source_epoch"],
         "sequence" => sequence,
         "received_at" => nil,
         "receipt_epoch" => d["context"]["store_boot_epoch"],
         "receipt_ms" => entry.bounds.received_store_ms,
         "profile_digest" => "sha256:" <> m["profile_sha256"],
         "replay" => replay,
         "continuity" => continuity,
         "expires_ms" => entry.bounds.expires_ms,
         "derivation_digest" => nil,
         "contributors" => []
       })}
    end
  end

  defp source_time(nil, nil),
    do:
      {:ok,
       %{
         "source_time" => nil,
         "source_time_trust" => "unknown",
         "source_time_basis" => nil,
         "source_uncertainty_ms" => nil
       }}

  defp source_time(nil, _), do: {:item, "invalid"}
  defp source_time(_, nil), do: {:item, "invalid"}

  defp source_time(time, basis) do
    with {:ok, uncertainty} <- ExternalInputMath.uncertainty_ms(time["uncertainty_us"]),
         do:
           {:ok,
            %{
              "source_time" => time["utc"],
              "source_time_trust" => time["trust"],
              "source_time_basis" => basis,
              "source_uncertainty_ms" => uncertainty
            }}
  end

  defp sequence(nil), do: {:item, "missing_sequence"}

  defp sequence(value) do
    integer = String.to_integer(value)
    if integer <= @maximum, do: {:ok, integer}, else: {:item, "unsupported_external_input"}
  end

  defp continuity("continuous"), do: {:ok, "continuous", "fresh"}
  defp continuity("baseline"), do: {:ok, "baseline", "fresh"}
  defp continuity("gap"), do: {:ok, "lost", "fresh"}
  defp continuity("retained"), do: {:ok, "lost", "retained"}
  defp continuity("replayed"), do: {:ok, "lost", "replayed"}
  defp continuity("unknown"), do: {:item, "baseline_required"}

  defp source_guards(config, entries, deadline) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case entry.frame do
        nil ->
          {:cont, :ok}

        f ->
          result = ExternalInputContext.collection_guard(config, f, deadline)

          if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end
    end)
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  defp runtime_guard({:ok, r, sha}, entries) do
    if Enum.any?(entries, & &1.frame) do
      case ExternalInputRuntime.check_current(r, sha) do
        :ok -> :ok
        _ -> {:error, :external_input_basis_changed}
      end
    else
      :ok
    end
  end

  defp runtime_guard(_, _), do: :ok

  defp fingerprints(pass),
    do:
      {pass.runtime,
       Enum.map(
         pass.entries,
         &{&1.item, &1.evidence, &1.witness, &1.bounds, &1.projection_reason}
       )}

  defp finish(pass, sampled) do
    traverse(pass.entries, fn entry ->
      cond do
        entry.closing_expired and sampled < entry.bounds.owner_expires_ms ->
          {:error, :external_input_basis_changed}

        entry.bounds != nil and entry.item["reason"] == nil ->
          with {:ok, reason} <-
                 ExternalInputMath.classify(
                   entry.bounds,
                   sampled,
                   entry.report["quality"],
                   entry.report["sequence"],
                   entry.report["continuity"]
                 ) do
            reason =
              if entry.projection_reason == "invalid",
                do: "invalid",
                else: reason || entry.projection_reason

            {:ok, Map.put(entry.item, "reason", reason)}
          end

        true ->
          {:ok, entry.item}
      end
    end)
  end

  defp snapshot(result) do
    with :ok <- ExternalInputFormat.bounded(result),
         :ok <- ExternalInputFormat.byte_limit(JSON.encode!(result), 262_144),
         true <- ExternalInputFormat.shape?(result, "input_snapshot"),
         do: :ok,
         else: (
           false -> {:error, :external_input_limit}
           error -> error
         )
  end

  defp item_error(entry, {:item, reason}), do: unavailable(entry, reason)

  defp item_error(entry, {:item, reason, frame}) do
    entry = %{entry | frame: frame}
    entry = put_in(entry.evidence[:capture], frame)
    unavailable(entry, reason)
  end

  defp item_error(entry, {:error, code})
       when code in [
              :target_unavailable,
              :external_selection_changed,
              :external_trust_changed,
              :external_policy_changed,
              :external_target_collision,
              :stale_external_basis
            ],
       do: unavailable(entry, "input_basis_changed")

  defp item_error(entry, {:error, code})
       when code in [
              :unsupported_external_input,
              :unsupported_external_value,
              :inexact_external_value
            ],
       do: unavailable(entry, "unsupported_external_input")

  defp item_error(entry, {:error, code})
       when code in [
              :invalid_external_input,
              :invalid_external_value,
              :external_value_out_of_range
            ],
       do: unavailable(entry, "invalid")

  defp item_error(entry, {:error, :profiles_producer_unavailable}),
    do: unavailable(entry, "producer_unavailable")

  defp item_error(entry, {:error, code})
       when code in [
              :runtime_artifact_unavailable,
              :stale_profile_runtime,
              :profile_runtime_source_unavailable
            ],
       do: unavailable(entry, "runtime_unavailable")

  defp item_error(_entry, {:error, :external_profile_limit}),
    do: {:error, :external_input_limit}

  defp item_error(_entry, {:error, %{code: code}})
       when code in [:input_limit, :numeric_limit, :output_limit],
       do: {:error, :external_input_limit}

  defp item_error(_entry, {:error, _} = error), do: error
  defp item_error(_entry, _), do: {:error, :store_unavailable}
  defp unavailable(entry, reason), do: {:ok, put_in(entry.item["reason"], reason)}

  defp traverse(values, callback) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case callback.(value) do
        {:ok, output} -> {:cont, {:ok, [output | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp budget(deadline, reserve),
    do: if(deadline - now() >= reserve, do: :ok, else: {:error, :external_input_unavailable})

  defp now, do: System.monotonic_time(:millisecond)
end
