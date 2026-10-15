defmodule WotexHome.Durable.Store.ExternalInputContext do
  @moduledoc """
  Measures an exact current review context for one external routine input.

  Native callers use `WotexHome.Authority.external_routine_input_context/4`.
  Store invokes `current/5` with its borrowed SQLite connection, owned dependency
  configuration, caller credential, target ID and capability key. Success returns
  `{:ok, context}` as a closed string-key map; refusal returns `{:error, reason}`.

  Before private reads, the caller must have `qualify:profile`, `rule:review`,
  `read` and a whole-Thing grant. The original selector and trust approver must
  independently retain their permissions and target grants. The selected target
  must be current for this Store boot and its capability must be a supported read.

  Preparation rebuilds the envelope from checked private objects and the live
  source selection, derives the reader from its projection and retained
  declaration, and measures the receipt-clock relation and all four groups in
  `WotexHome.Rules.ExternalInputRuntime`. It captures the complete basis twice
  and requires exact equality. Each pass also repeats source/report-owner identity
  checks after private reads and freshly checks the closing runtime inventory.
  Synthetic-lab sources refuse `:unsupported_external_input`.

  One 10-second monotonic budget covers preparation; each five-second owner call
  requires at least five seconds remaining before it starts. Exhaustion or an
  unavailable owner returns `{:error, :external_input_unavailable}`; differing
  opening/closing captures return `{:error, :external_input_basis_changed}`.
  Authentication, limit, maintenance and corruption refusals retain their named
  codes. There is no partial context or background continuation.

  Store retains connection ownership; source and custody owners receive neither
  its handle nor the bearer. This read allocates no lease, retains no operation,
  changes no revision and installs no input. The returned basis is review metadata,
  not continuing authorization, a current Fact or physical qualification.
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
    deadline = now() + 10_000

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

  defp capture(db, config, credential, target, key, deadline) do
    with {:ok, basis} <- basis(db, credential, target, key),
         :ok <- boot_selection(config, target, basis.selected.current.selection_revision),
         {:ok, runtime, runtime_sha} <- ExternalInputRuntime.current(),
         {:ok, source} <- source(config, basis, deadline),
         {:ok, clock} <- report_clock(config, deadline),
         {:ok, inspection} <-
           native(fn ->
             ExternalTargetPreparation.inspection_input(
               basis.selected.input,
               source.selection.inputs["reader"]
             )
           end),
         {:ok, owned} <-
           ExternalInspections.owned_records(db, basis.selected.principal, inspection),
         {:ok, records} <- records(config.profile_custody, owned, deadline),
         {:ok, prepared} <-
           native(fn ->
             ExternalTargetPreparation.build_with_envelope(
               basis.selected.input,
               Enum.sort_by(records, & &1["object"]["object_digest"]),
               source.selection,
               basis.selected.current.outcome["artifact_document"]
             )
           end),
         :ok <- same(prepared.outcome, basis.selected.current.outcome),
         {:ok, %{"data" => summary}} <-
           native(fn -> ExternalSourceSelection.to_map(source.selection) end),
         :ok <- supported_source(summary),
         limits = source.selection.inputs["reader"].inputs["reader_limits"],
         {:ok, projection} <-
           native(fn ->
             Wotex.Profiles.Projection.to_map(prepared.envelope.projection, limits)
           end),
         :ok <-
           native_producer(source.selection, basis.declaration, runtime["profiles"]),
         {:ok, reader} <- native(fn -> reader(projection, basis.declaration) end),
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
         {:ok, current_source} <- source(config, basis, deadline),
         :ok <- same(current_source, source),
         {:ok, current_clock} <- report_clock(config, deadline),
         :ok <- same(current_clock["epoch"], clock["epoch"]),
         {:ok, current_basis} <- basis(db, credential, target, key),
         :ok <- same(current_basis, basis),
         :ok <- ExternalInputRuntime.check_current(runtime, runtime_sha),
         :ok <- budget(deadline, 0) do
      {:ok, %{context: context, basis: basis, records: records, source: source}}
    end
  end

  defp basis(db, credential, target, key) do
    with {:ok, actor} <- actor(db, credential, target),
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
           ExternalTargets.observation_basis(db, %{
             "source_ref" => retained.inputs["source"]["source_ref"],
             "source_owner_epoch" => retained.owner_epoch,
             "source_selection_sha256" => retained.sha256
           }),
         true <- selected.target_id == target and selected.current == cursor,
         {:ok, trust} <- ExternalTargets.trust(db, selected.input["artifact_digest"]),
         {:ok, selector} <- author(db, selected.principal, target, @selector),
         {:ok, approver} <- author(db, trust.principal, target, ["profile:manage"]),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key='authority_epoch'") do
      {:ok,
       %{
         actor: actor,
         selector: selector,
         approver: approver,
         selected: Map.delete(selected, :revision),
         trust: trust,
         retained: retained,
         thing: thing,
         declaration: declaration,
         epoch: epoch
       }}
    else
      false -> {:error, :external_input_basis_changed}
      error -> refusal(error)
    end
  end

  defp actor(db, credential, target) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal, permissions} <- Access.authenticate(db, hash),
         true <- Enum.all?(@caller, &(&1 in permissions)),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- MapSet.member?(grants, target) do
      {:ok, %{principal: principal, permissions: permissions, grants: grants}}
    else
      false -> {:error, :permission_denied}
      {:error, :invalid_credential} -> {:error, :unauthorized}
      error -> error
    end
  end

  defp author(db, principal, target, required) do
    with {:ok, permissions} <- Access.active_principal_permissions(db, principal),
         true <- Enum.all?(required, &(&1 in permissions)),
         {:ok, grants} <- Access.allowed_targets(db, principal),
         true <- MapSet.member?(grants, target) do
      {:ok, %{principal: principal, permissions: permissions, grants: grants}}
    else
      false -> {:error, :external_input_basis_changed}
      {:error, :principal_unavailable} -> {:error, :external_input_basis_changed}
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

  defp source(config, basis, deadline) do
    owner_call(deadline, fn ->
      ExternalSourceOwner.current(
        config.external_source_owner,
        basis.selected.principal,
        basis.retained.inputs["source"]["source_ref"],
        basis.retained.owner_epoch,
        basis.retained.sha256
      )
    end)
  end

  defp report_clock(config, deadline),
    do:
      owner_call(deadline, fn ->
        ExternalReportOwner.receipt_clock(config.external_report_owner)
      end)

  defp records(custody, owned, deadline) do
    Enum.reduce_while(owned, {:ok, []}, fn item, {:ok, records} ->
      with {:ok, object} <-
             owner_call(deadline, fn ->
               Custody.read_object(custody, item["object"]["object_digest"])
             end),
           {:ok, summary} <- AuthoringObject.summary(object),
           :ok <- same(summary, item["object"]) do
        {:cont, {:ok, [Map.put(item, "payload", object.payload) | records]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp supported_source(%{"trust" => "synthetic_lab"}),
    do: {:error, :unsupported_external_input}

  defp supported_source(_), do: :ok

  defp native_producer(selection, declaration, producer) do
    if selection.inputs["reader"].inputs["installed"]["producer"] == producer and
         declaration["producer"] == producer,
       do: :ok,
       else: {:error, :external_input_unavailable}
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

  defp owner_call(deadline, callback) do
    with :ok <- budget(deadline, 5000) do
      case callback.() do
        {:ok, _} = result ->
          result

        {:error, code}
        when code in [
               :stale_external_source,
               :external_source_owner_changed,
               :external_source_retired
             ] ->
          {:error, :external_input_basis_changed}

        _ ->
          {:error, :external_input_unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :external_input_unavailable}
  end

  defp native(callback) do
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

  defp budget(deadline, reserve) do
    if deadline - now() >= reserve, do: :ok, else: {:error, :external_input_unavailable}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
