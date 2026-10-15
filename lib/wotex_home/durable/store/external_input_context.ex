defmodule WotexHome.Durable.Store.ExternalInputContext do
  @moduledoc """
  Measures the current native basis for reviewing or collecting external inputs.

  Native review callers use
  `WotexHome.Authority.external_routine_input_context/4`.
  `WotexHome.Durable.Store.ExternalInputContext.current/5` takes Store's borrowed
  SQLite connection, owned dependency configuration, caller credential, target
  ID and capability key. It returns `{:ok, context}` with a closed string-keyed
  map, or `{:error, reason}` with no partial context.

  Review requires the caller's current `qualify:profile`, `rule:review`, `read`
  and whole-Thing grant before private reads. The selected target must belong to
  this Store boot and expose a supported read. Its original selector and trust
  approver independently retain their required permissions and target grants.

  Preparation rebuilds the envelope from checked private objects and the live
  source selection, derives the reader from its projection and retained
  declaration, and measures the receipt-clock relation and all four groups in
  `WotexHome.Rules.ExternalInputRuntime`. Review captures the complete basis
  twice and requires equality, including closing source/report-owner identity
  and a fresh runtime inventory. Synthetic-lab sources refuse
  `:unsupported_external_input`.

  `WotexHome.Durable.Store.ExternalInputContext.current/5` starts a ten-second
  monotonic budget; `WotexHome.Durable.Store.ExternalInputContext.current/6`
  accepts Store's existing deadline so installation shares its preparation and
  commit budget. Each five-second owner call requires at least five seconds
  remaining before it starts. Exhaustion or an unavailable owner returns
  `{:error, :external_input_unavailable}`; changed witnesses return
  `{:error, :external_input_basis_changed}`. Authentication, limit, maintenance
  and corruption refusals retain their named codes.

  `WotexHome.Durable.Store.ExternalInputCollection` first calls
  `WotexHome.Durable.Store.ExternalInputContext.collection_basis/4` to measure
  durable correspondence with author checks deferred. This preserves refusal
  order: compare the installed durable context before classifying current author
  availability. The result alone authorizes no private read or Fact projection.

  `WotexHome.Durable.Store.ExternalInputContext.collection_authors/3` then takes
  that basis and target ID and returns the current selector/approver permission
  and grant witnesses, or an author refusal. The collector separately checks
  the original installer's `qualify:profile`, `rule:review`, `read` and target
  grant. Its caller needs only `rule:review`, `read` and a target grant.

  `WotexHome.Durable.Store.ExternalInputContext.collection_capture/7` repeats
  current author checks before private reads and returns an internal frame with
  the actual envelope. It uses the collector's fresh pass-wide runtime inventory
  and shared deadline.
  `WotexHome.Durable.Store.ExternalInputContext.collection_guard/3` closes source
  and report-owner identity against that frame. The collector owns whole-scope
  repetition and final classification. These internal entry points preserve
  review's three-permission requirement and supply no continuing authorization.

  Store retains connection ownership; source and custody owners receive neither
  its handle nor the bearer. Measurement creates no lease, operation, revision
  or input installation. A returned context is review metadata, with no
  continuing authorization, current Fact or physical qualification.
  """

  alias WotexHome.Durable.Registry

  alias WotexHome.Durable.Store.{
    Access,
    ExternalInputs,
    ExternalInspections,
    ExternalTargets,
    MaintenanceWriter
  }

  alias WotexHome.Profiles.{
    AuthoringObject,
    Custody,
    EnvelopeCodec,
    ExternalReportOwner,
    ExternalSourceOwner,
    ExternalSourceSelection,
    ExternalTargetPreparation,
    ReadDeclarationCodec,
    RetainedSource
  }

  alias WotexHome.Rules.{ExternalInputFormat, ExternalInputRuntime}
  alias WotexHome.Semantics.{ReadCapability, Thing}
  import WotexHome.Durable.Store.SQL, only: [query: 2]

  @caller ~w(qualify:profile rule:review read)
  @selector ~w(profile:manage enroll:review)
  @maximum 9_223_372_036_854_775_807
  @minimum -9_223_372_036_854_775_808
  @policy ~w(unauthorized permission_denied target_unavailable maintenance_active invalid_external_input external_input_limit external_input_unavailable unsupported_external_input external_input_basis_changed runtime_artifact_unavailable)a
  @corrupt ~w(corrupt_principal corrupt_native_setup corrupt_controller_pairing corrupt_enrollment corrupt_maintenance corrupt_authoring_objects corrupt_external_inspections corrupt_external_trust corrupt_external_targets corrupt_external_inputs)a
  @basis_changed ~w(external_selection_changed external_trust_changed external_policy_changed profile_author_unavailable external_target_collision)a

  @doc "Rebuilds a bounded review context without retaining an operation or lease."
  def current(db, configuration, credential, target, key) do
    current(db, configuration, credential, target, key, now() + 10_000)
  end

  @doc false
  def current(db, configuration, credential, target, key, deadline) do
    with :ok <- identity(target, key),
         {:ok, opening} <- capture(db, configuration, credential, target, key, deadline),
         {:ok, closing} <- capture(db, configuration, credential, target, key, deadline),
         true <- opening == closing,
         :ok <- budget(deadline, 0) do
      {:ok, closing.context}
    else
      false -> {:error, :external_input_basis_changed}
      error -> refusal(error)
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  @doc false
  def collection_basis(db, credential, target, key),
    do: basis(db, credential, target, key, :collection_durable)

  @doc false
  def collection_authors(db, basis, target),
    do: authors(db, basis.selected.principal, basis.trust.principal, target, :collection)

  @doc false
  def collection_guard(config, frame, deadline) do
    with {:ok, source} <- closing_source(config, frame.basis, deadline, :collection),
         :ok <- same(source, frame.source),
         {:ok, clock} <- report_clock(config, deadline, :collection),
         do: same(clock["epoch"], frame.context["report_owner_epoch"])
  end

  @doc false
  def collection_capture(db, config, credential, target, key, deadline, {runtime, sha}) do
    capture(db, config, credential, target, key, deadline, {:collection, runtime, sha})
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  defp capture(db, config, credential, target, key, deadline, mode \\ :review) do
    with {:ok, basis} <- basis(db, credential, target, key, mode),
         :ok <- boot_selection(config, target, basis.selected.current.selection_revision),
         {:ok, runtime, runtime_sha} <- runtime(mode),
         {:ok, source} <- source(config, basis, deadline, mode) do
      with {:ok, clock} <- report_clock(config, deadline, mode) do
        result =
          capture_native(
            db,
            config,
            credential,
            target,
            key,
            deadline,
            mode,
            basis,
            runtime,
            runtime_sha,
            source,
            clock
          )

        case result do
          {:item, reason} ->
            {:item, reason,
             %{basis: basis, source: source, context: %{"report_owner_epoch" => clock["epoch"]}}}

          _ ->
            result
        end
      end
    end
  end

  defp capture_native(
         db,
         config,
         credential,
         target,
         key,
         deadline,
         mode,
         basis,
         runtime,
         runtime_sha,
         source,
         clock
       ) do
    with {:ok, inspection} <-
           native(
             fn ->
               ExternalTargetPreparation.inspection_input(
                 basis.selected.input,
                 source.selection.inputs["reader"]
               )
             end,
             mode
           ),
         {:ok, owned} <-
           ExternalInspections.owned_records(db, basis.selected.principal, inspection),
         {:ok, records} <- records(config.profile_custody, owned, deadline, mode),
         {:ok, prepared} <-
           native(
             fn ->
               ExternalTargetPreparation.build_with_envelope(
                 basis.selected.input,
                 Enum.sort_by(records, & &1["object"]["object_digest"]),
                 source.selection,
                 basis.selected.current.outcome["artifact_document"]
               )
             end,
             mode
           ),
         :ok <- static_same(prepared.outcome, basis.selected.current.outcome, mode),
         {:ok, %{"data" => summary}} <-
           native(fn -> ExternalSourceSelection.to_map(source.selection) end, mode),
         :ok <- supported_source(summary),
         limits = source.selection.inputs["reader"].inputs["reader_limits"],
         {:ok, projection} <-
           native(
             fn ->
               Wotex.Profiles.Projection.to_map(prepared.envelope.projection, limits)
             end,
             mode
           ),
         :ok <-
           native_producer(source.selection, basis.declaration, runtime["profiles"], mode),
         {:ok, reader} <- native(fn -> reader(projection, basis.declaration) end, mode),
         {:ok, receipt_clock} <- receipt_clock(config, clock),
         context =
           context(
             config,
             basis,
             summary,
             clock,
             limits,
             reader,
             receipt_clock,
             runtime,
             runtime_sha
           ),
         :ok <- checked_context(context),
         {:ok, current_source} <- closing_source(config, basis, deadline, mode),
         :ok <- same(current_source, source),
         {:ok, current_clock} <- report_clock(config, deadline, mode),
         :ok <- same(current_clock["epoch"], clock["epoch"]),
         {:ok, current_basis} <- basis(db, credential, target, key, mode),
         :ok <- same(current_basis, basis),
         :ok <- closing_runtime(mode, runtime, runtime_sha),
         :ok <- budget(deadline, 0) do
      frame = %{context: context, basis: basis, records: records, source: source}
      {:ok, if(mode == :review, do: frame, else: Map.put(frame, :envelope, prepared.envelope))}
    end
  end

  defp basis(db, credential, target, key, mode) do
    with {:ok, actor} <- actor(db, credential, target, mode),
         :ok <- MaintenanceWriter.guard(db),
         :ok <- ExternalInputs.validate_if_current(db),
         {:ok, thing, resource} <- Access.enrolled_thing(db, target),
         {:ok, %ReadCapability{} = capability} <- capability(thing, key),
         {:ok, ^capability} <- ReadCapability.new(capability.record),
         {:ok, %{"data" => declaration}} <- ReadDeclarationCodec.decode(capability.record),
         {:ok, cursor} <- ExternalTargets.cursor(db, target),
         true <- cursor.state == "selected" and cursor.resource_revision == resource,
         {:ok, retained} <- RetainedSource.decode(cursor.outcome["source_document"]),
         {:ok, selected} <-
           ExternalTargets.observation_basis(
             db,
             %{
               "source_ref" => retained.inputs["source"]["source_ref"],
               "source_owner_epoch" => retained.owner_epoch,
               "source_selection_sha256" => retained.sha256
             },
             if(mode == :review, do: :current, else: :deferred)
           ),
         true <- selected.target_id == target and selected.current == cursor,
         {:ok, trust} <- ExternalTargets.trust(db, selected.input["artifact_digest"]),
         {:ok, authors} <- authors(db, selected.principal, trust.principal, target, mode),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key='authority_epoch'") do
      {:ok,
       %{
         actor: actor,
         selector: authors.selector,
         approver: authors.approver,
         selected: Map.delete(selected, :revision),
         trust: trust,
         retained: retained,
         thing: thing,
         declaration: declaration,
         epoch: epoch
       }}
    else
      false -> {:error, :external_input_basis_changed}
      error -> if(mode == :review, do: refusal(error), else: error)
    end
  end

  defp authors(_db, _selector, _approver, _target, :collection_durable),
    do: {:ok, %{selector: nil, approver: nil}}

  defp authors(db, selector, approver, target, mode) do
    with {:ok, selector} <- author(db, selector, target, @selector, mode),
         {:ok, approver} <- author(db, approver, target, ["profile:manage"], mode),
         do: {:ok, %{selector: selector, approver: approver}}
  end

  defp actor(db, credential, target, mode) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         required = if(mode == :review, do: @caller, else: ~w(rule:review read)),
         true <- Enum.all?(required, &(&1 in permissions)),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- MapSet.member?(grants, target) do
      {:ok, %{principal: principal, permissions: permissions, grants: grants}}
    else
      false -> {:error, :permission_denied}
      {:error, :invalid_credential} -> {:error, :unauthorized}
      error -> error
    end
  end

  defp author(db, principal, target, required, mode) do
    with {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         true <- Enum.all?(required, &(&1 in permissions)),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- MapSet.member?(grants, target) do
      {:ok, %{principal: principal, permissions: permissions, grants: grants}}
    else
      false -> author_unavailable(mode)
      {:error, :principal_unavailable} -> author_unavailable(mode)
      error -> error
    end
  end

  defp capability(thing, key) do
    case Thing.capability(thing, key) do
      {:ok, %ReadCapability{}} = result -> result
      _ -> {:error, :unsupported_external_input}
    end
  end

  defp identity(target, key) do
    if WotexHome.Id.valid?(target) and WotexHome.Id.valid?(key),
      do: :ok,
      else: {:error, :invalid_external_input}
  end

  defp boot_selection(config, target, revision) do
    if config.external_target_boot[target] == revision,
      do: :ok,
      else: {:error, :external_input_basis_changed}
  end

  defp source(config, basis, deadline, mode) do
    with {:ok, source} <-
           owner_call(deadline, :source, mode, fn ->
             ExternalSourceOwner.current(
               config.external_source_owner,
               basis.selected.principal,
               basis.retained.inputs["source"]["source_ref"],
               basis.retained.owner_epoch,
               basis.retained.sha256
             )
           end) do
      expected = %{
        owner_epoch: basis.retained.owner_epoch,
        source_ref: basis.retained.inputs["source"]["source_ref"],
        source_selection_sha256: basis.retained.sha256
      }

      if mode == :review or source.guard == expected,
        do: {:ok, source},
        else: {:error, :external_input_unavailable}
    end
  end

  defp report_clock(config, deadline, mode),
    do:
      owner_call(deadline, :clock, mode, fn ->
        ExternalReportOwner.receipt_clock(config.external_report_owner)
      end)

  defp closing_source(config, basis, deadline, mode) do
    case source(config, basis, deadline, mode) do
      {:item, _} -> {:error, :external_input_basis_changed}
      result -> result
    end
  end

  defp records(custody, owned, deadline, mode) do
    Enum.reduce_while(owned, {:ok, []}, fn item, {:ok, records} ->
      with {:ok, object} <-
             owner_call(deadline, :object, mode, fn ->
               Custody.read_object(custody, item["object"]["object_digest"])
             end),
           {:ok, summary} <- AuthoringObject.summary(object),
           :ok <- static_same(summary, item["object"], mode) do
        {:cont, {:ok, [Map.put(item, "payload", object.payload) | records]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp supported_source(%{"trust" => "synthetic_lab"}),
    do: {:error, :unsupported_external_input}

  defp supported_source(_), do: :ok

  defp native_producer(selection, declaration, producer, mode) do
    if selection.inputs["reader"].inputs["installed"]["producer"] == producer and
         declaration["producer"] == producer,
       do: :ok,
       else:
         if(mode == :review,
           do: {:error, :external_input_unavailable},
           else: {:item, "producer_unavailable"}
         )
  end

  defp reader(projection, declaration) do
    case Enum.find(projection["channel_plans"], &(&1["channel_id"] == declaration["channel_id"])) do
      %{"disposition" => "supported"} = plan ->
        {:ok,
         projection
         |> Map.take(~w(profile_sha256 closure_sha256 capture_digest compiler_ref))
         |> Map.merge(%{
           "reader_contract_ref" => Wotex.Profiles.Proposal.identity(),
           "channel_id" => plan["channel_id"],
           "affordance" => plan["affordance"],
           "semantic_ref" => plan["semantic"],
           "external_unit" => plan["definition"]["unit"],
           "value_schema" => plan["definition"]["value_schema"]
         })}

      _ ->
        {:error, :unsupported_external_input}
    end
  end

  defp receipt_clock(config, clock) do
    origin = 1000 * config.clock_origin

    if origin in @minimum..@maximum do
      {:ok,
       %{
         "format" => "wotex.routines.receipt-clock@1",
         "projection" => "floor_millisecond",
         "source_epoch" => clock["epoch"],
         "source_origin_us" => Integer.to_string(origin),
         "target_epoch" => config.clock_epoch,
         "target_origin_ms" => 0
       }}
    else
      {:error, :external_input_limit}
    end
  end

  defp context(config, basis, summary, clock, limits, reader, receipt_clock, runtime, sha) do
    selected = basis.selected

    %{
      "format" => "wotex-home.external-input-context@1",
      "authority_epoch" => basis.epoch,
      "store_boot_epoch" => config.clock_epoch,
      "target_id" => selected.target_id,
      "capability_key" => basis.declaration["capability_key"],
      "selection_revision" => selected.current.selection_revision,
      "resource_revision" => selected.current.resource_revision,
      "binding_revision" => selected.current.binding_revision,
      "trust_revision" => selected.selection_receipt["trust_revision"],
      "policy_generation" => selected.policy,
      "selection_author" => selected.principal,
      "trust_author" => basis.trust.principal,
      "source_owner_epoch" => basis.retained.owner_epoch,
      "source_selection_sha256" => basis.retained.sha256,
      "source_ref" => summary["source_ref"],
      "source_epoch" => summary["source_epoch"],
      "source_generation" => summary["source_generation"],
      "source_method" => summary["method"],
      "source_trust" => summary["trust"],
      "stable_id_sha256" => summary["stable_id_sha256"],
      "report_owner_epoch" => clock["epoch"],
      "reader_limits" => limits,
      "declaration" => basis.declaration,
      "reader" => reader,
      "receipt_clock" => receipt_clock,
      "runtime" => runtime,
      "runtime_sha256" => sha
    }
  end

  defp checked_context(data) do
    with true <- ExternalInputFormat.shape?(data, "input_context"),
         :ok <- ExternalInputFormat.bounded(data),
         :ok <- ExternalInputFormat.byte_limit(JSON.encode!(data), 262_144),
         do: :ok,
         else: (
           false -> {:error, :unsupported_external_input}
           error -> error
         )
  end

  defp owner_call(deadline, kind, mode, callback) do
    with :ok <- budget(deadline, 5000) do
      case callback.() do
        {:ok, value} when mode != :review ->
          collection_owner_result(kind, value)

        {:ok, _} = result ->
          result

        {:error, code}
        when code in [
               :stale_external_source,
               :external_source_owner_changed,
               :external_source_retired
             ] ->
          if mode == :review,
            do: {:error, :external_input_basis_changed},
            else: {:item, "source_unavailable"}

        :not_found when mode != :review and kind == :source ->
          {:item, "source_unavailable"}

        :not_found when mode != :review and kind == :object ->
          {:item, "input_basis_changed"}

        {:error, :authoring_object_unavailable} when mode != :review and kind == :object ->
          {:item, "input_basis_changed"}

        _ ->
          {:error, :external_input_unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  defp collection_owner_result(
         :source,
         %{selection: %ExternalSourceSelection{} = selection, guard: guard} = value
       )
       when map_size(value) == 2 and is_map(guard) do
    if Enum.sort(Map.keys(guard)) == [:owner_epoch, :source_ref, :source_selection_sha256] and
         epoch?(guard.owner_epoch) and WotexHome.Id.valid?(guard.source_ref) and
         EnvelopeCodec.digest?(guard.source_selection_sha256) and
         guard.source_selection_sha256 == selection.sha256 and is_map(selection.data) and
         guard.source_ref == selection.data["source_ref"] and is_map(selection.inputs),
       do: {:ok, value},
       else: {:error, :external_input_unavailable}
  end

  defp collection_owner_result(:clock, value) do
    if EnvelopeCodec.keys?(value, ~w(epoch monotonic_us)) and epoch?(value["epoch"]) and
         signed_clock?(value["monotonic_us"]),
       do: {:ok, value},
       else: {:error, :external_input_unavailable}
  end

  defp collection_owner_result(:object, %AuthoringObject{} = value) do
    case AuthoringObject.summary(value) do
      {:ok, _} -> {:ok, value}
      _ -> {:error, :external_input_unavailable}
    end
  end

  defp collection_owner_result(_, _), do: {:error, :external_input_unavailable}

  defp epoch?(value),
    do: is_binary(value) and byte_size(value) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp signed_clock?(value) when is_binary(value) and byte_size(value) in 1..20 do
    value != "-0" and Regex.match?(~r/\A-?(0|[1-9][0-9]*)\z/, value) and
      String.to_integer(value) in @minimum..@maximum
  end

  defp signed_clock?(_), do: false

  defp native(callback, mode) do
    result = native_result(callback)

    if mode != :review and result == {:error, :external_input_unavailable},
      do: {:item, "producer_unavailable"},
      else: result
  end

  defp native_result(callback) do
    case callback.() do
      {:ok, _} = result ->
        result

      {:error, :unsupported_external_input} = error ->
        error

      {:error, :external_profile_limit} ->
        {:error, :external_input_limit}

      {:error, code}
      when code in [
             :runtime_artifact_unavailable,
             :stale_profile_runtime,
             :profile_runtime_source_unavailable
           ] ->
        {:error, :runtime_artifact_unavailable}

      {:error, %{code: code}} when code in [:input_limit, :numeric_limit, :output_limit] ->
        {:error, :external_input_limit}

      _ ->
        {:error, :external_input_unavailable}
    end
  rescue
    _ -> {:error, :external_input_unavailable}
  end

  defp refusal({:error, code}) when code in @policy or code in @corrupt, do: {:error, code}

  defp refusal({:error, code}) when code in @basis_changed,
    do: {:error, :external_input_basis_changed}

  defp refusal(:not_found), do: {:error, :external_input_unavailable}
  defp refusal(_), do: {:error, :store_unavailable}
  defp same(value, value), do: :ok
  defp same(_, _), do: {:error, :external_input_basis_changed}

  defp runtime(:review), do: ExternalInputRuntime.current()
  defp runtime({:collection, runtime, sha}), do: {:ok, runtime, sha}

  defp closing_runtime(:review, runtime, sha),
    do: ExternalInputRuntime.check_current(runtime, sha)

  defp closing_runtime(_, _, _), do: :ok
  defp author_unavailable(:review), do: {:error, :external_input_basis_changed}
  defp author_unavailable(_), do: {:item, "input_author_unavailable"}
  defp static_same(value, value, _mode), do: :ok
  defp static_same(_, _, :review), do: {:error, :external_input_basis_changed}
  defp static_same(_, _, _), do: {:item, "input_basis_changed"}

  defp budget(deadline, reserve) do
    if deadline - now() >= reserve, do: :ok, else: {:error, :external_input_unavailable}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
