defmodule WotexHome.Authority do
  @moduledoc """
  Coordinates transport-independent Home application operations.

  Trusted host composition uses `new/1` to select the single Store and explicitly
  owned custody, review and device sessions. Adapters authenticate their local
  peer, decode a closed request and call this boundary with its credential and
  original operation identity. Authority sequences pure domain decisions,
  current Store checks and bounded device work without owning a socket or
  database connection.

  Reads, inert imports, authoring proposals, approval, target selection, rule
  admission and device dispatch remain separate use cases. Generator preparation
  records an exact authorized basis, but performs no provider handoff. Workers
  receive scoped work rather than a Store connection or operator bearer.

  `external_profile_context/2`, `external_source_catalogue/2` and
  `external_target_basis/3` expose authenticated reader/source/target comparison
  metadata. `external_inspection_artifact/3` rebuilds the caller's exact retained
  inspection manifest from currently checked bytes. These reads create no new
  original or source lease and grant no approval or target selection; later mutations
  still repeat current guards rather than trusting a cached guidance snapshot.

  `external_routine_input_context/4` takes the credential, target ID and capability
  key and returns `{:ok, context}` or `{:error, reason}`. Store measures the exact
  reader, private source, receipt-clock and current runtime basis for native input
  review. This bounded read creates no operation or lease and installs no input;
  its metadata grants no continuing authorization or physical qualification.

  `change_external_routine_input/3` takes a closed install/revoke input and returns
  `{:ok, receipt}` or `{:error, reason}`. `external_routine_input_status/4` recovers
  that actor's receipt by authority epoch and operation ID, or returns `:not_found`
  or an error. Both require current permissions and target grants. Exact original
  replay precedes fresh admission; replay, status and revocation need no live input
  producer or reviewer. Each new install requires a fresh signed decision and
  Store's repeated actual current-context checks, without granting effect authority.

  After a lost reply, recover the same original operation and immutable receipt
  before deciding whether further work is needed. Staging, admission, durable
  handoff, protocol acknowledgement and observed state are distinct outcomes;
  none alone proves a physical result. Dispatch remains subject to the explicit
  host flag and current qualification guards.
  """

  alias WotexHome.Authority.ReviewGate
  alias WotexHome.ControllerConnections.Codec, as: PairingCodec
  alias WotexHome.ControllerConnections.ConsumptionCodec
  alias WotexHome.ControllerConnections.PairingReview
  alias WotexHome.Discovery.{Candidate, Interview, Profile}
  alias WotexHome.Durable.{Store, SupportExport}

  alias WotexHome.Lifx.{
    CaptureSession,
    InterfaceSelection,
    PowerExecution,
    ProfileCatalogue,
    ProfileBasis,
    ReadPath,
    WotexUdp
  }

  alias WotexHome.Id
  alias WotexHome.Mutation
  alias WotexHome.Rules.{CandidateArtifact, CandidateReview, Codec, Rule}

  @diagnostic_principal "diagnostics:local"
  @enforce_keys [:store, :capture, :review_gate]
  defstruct @enforce_keys ++
              [
                power_supervisor: nil,
                power_dispatch: false,
                component_runner: nil,
                profile_custody: nil,
                profile_reviews: nil,
                recovery_reviews: nil,
                pairing_reviews: nil,
                authoring_uploads: nil,
                timezone_options: []
              ]

  @type process_ref :: GenServer.server() | nil
  @type t :: %__MODULE__{
          store: GenServer.server(),
          capture: process_ref(),
          review_gate: process_ref(),
          power_supervisor: process_ref(),
          power_dispatch: boolean(),
          component_runner: process_ref(),
          profile_custody: process_ref(),
          profile_reviews: process_ref(),
          recovery_reviews: process_ref(),
          pairing_reviews: process_ref(),
          authoring_uploads: process_ref(),
          timezone_options: keyword()
        }

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      store: Keyword.fetch!(opts, :store),
      capture: Keyword.get(opts, :capture, WotexHome.Host.LifxCapture),
      review_gate: Keyword.get(opts, :review_gate),
      power_supervisor: Keyword.get(opts, :power_supervisor),
      power_dispatch: Keyword.get(opts, :power_dispatch, false) == true,
      component_runner: Keyword.get(opts, :component_runner),
      profile_custody: Keyword.get(opts, :profile_custody),
      profile_reviews: Keyword.get(opts, :profile_reviews),
      recovery_reviews: Keyword.get(opts, :recovery_reviews),
      pairing_reviews: Keyword.get(opts, :pairing_reviews),
      authoring_uploads: Keyword.get(opts, :authoring_uploads),
      timezone_options: Keyword.get(opts, :timezone_options, [])
    }
  end

  @doc "Trusted in-process, unqualified component preview; no facts or effects are committed."
  def profile_preview(%__MODULE__{component_runner: nil}, _, _, _),
    do: {:error, :runner_unavailable}

  def profile_preview(%__MODULE__{component_runner: runner}, digest, operation, input),
    do: WotexHome.Plugins.Runner.preview(runner, digest, operation, input)

  @spec with_review_gate(t(), GenServer.server()) :: t()
  def with_review_gate(%__MODULE__{} = authority, gate),
    do: %{authority | review_gate: gate}

  def with_authoring_uploads(%__MODULE__{} = authority, owner),
    do: %{authority | authoring_uploads: owner}

  @doc "Reads the installed public authoring grammar and current authorized Store basis."
  def authoring_contract_export(authority, credential),
    do: Store.authoring_contract_export(authority.store, credential)

  def begin_authoring_upload(authority, credential, input),
    do:
      authoring_upload_call(
        authority,
        credential,
        &WotexHome.Profiles.AuthoringUpload.begin(&1, &2, input)
      )

  def append_authoring_upload(authority, credential, ref, offset, bytes),
    do:
      authoring_upload_call(
        authority,
        credential,
        &WotexHome.Profiles.AuthoringUpload.append(&1, &2, ref, offset, bytes)
      )

  def authoring_upload_status(authority, credential, id),
    do:
      authoring_upload_call(
        authority,
        credential,
        &WotexHome.Profiles.AuthoringUpload.status(&1, &2, id)
      )

  def cancel_authoring_upload(authority, credential, ref),
    do:
      authoring_upload_call(
        authority,
        credential,
        &WotexHome.Profiles.AuthoringUpload.cancel(&1, &2, ref)
      )

  def import_authoring_upload(%__MODULE__{} = authority, credential, input, ref) do
    if ref == nil or WotexHome.Profiles.AuthoringUpload.valid_ref?(ref) do
      case Store.authoring_import_original(authority.store, credential, input) do
        {:ok, _} = existing ->
          existing

        :not_found when ref == nil ->
          {:error, :authoring_upload_required}

        :not_found ->
          with_authoring_upload(
            authority,
            credential,
            ref,
            "import_payload",
            &import_authoring_object(authority, credential, input, &1)
          )

        error ->
          error
      end
    else
      {:error, :invalid_authoring_upload_reference}
    end
  end

  def review_authoring_upload(%__MODULE__{} = authority, credential, request) do
    alias WotexHome.Profiles.{AuthoringReview, EnvelopeCodec}

    with true <-
           EnvelopeCodec.keys?(request, ~w(authority_epoch input_ref input_sha256 operation_id)),
         true <- EnvelopeCodec.digest?(request["input_sha256"]),
         true <-
           request["input_ref"] == nil or
             WotexHome.Profiles.AuthoringUpload.valid_ref?(request["input_ref"]) do
      input_ref = request["input_ref"]

      case authoring_review_status(
             authority,
             credential,
             request["authority_epoch"],
             request["operation_id"]
           ) do
        {:ok, receipt} ->
          if receipt["input_sha256"] == request["input_sha256"],
            do: {:ok, receipt},
            else: {:error, :authoring_operation_conflict}

        :not_found when input_ref == nil ->
          {:error, :authoring_upload_required}

        :not_found ->
          with_authoring_upload(
            authority,
            credential,
            request["input_ref"],
            "review_original",
            fn bytes ->
              with {:ok, input} <- AuthoringReview.decode(bytes),
                   true <-
                     :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
                       request["input_sha256"],
                   true <-
                     input["authority_epoch"] == request["authority_epoch"] and
                       input["operation_id"] == request["operation_id"],
                   do: review_authoring_candidate(authority, credential, input),
                   else: (
                     false -> {:error, :invalid_authoring_review}
                     error -> error
                   )
            end
          )

        error ->
          error
      end
    else
      _ -> {:error, :invalid_authoring_review}
    end
  end

  defp authoring_upload_call(%__MODULE__{} = authority, credential, callback) do
    with {:ok, scope} <- Store.authoring_upload_scope(authority.store, credential) do
      if authority.authoring_uploads == nil,
        do: {:error, :authoring_upload_unavailable},
        else: callback.(authority.authoring_uploads, scope)
    end
  end

  defp with_authoring_upload(authority, credential, ref, purpose, callback) do
    alias WotexHome.Profiles.AuthoringUpload

    authoring_upload_call(authority, credential, fn owner, scope ->
      with {:ok, borrowed} <- AuthoringUpload.checkout(owner, scope, ref, purpose) do
        try do
          callback.(borrowed.bytes)
        after
          _ = AuthoringUpload.finish(owner, borrowed.token)
        end
      end
    end)
  end

  @spec owner(t()) :: pid() | nil
  def owner(%__MODULE__{store: store}), do: resolve(store)

  def health(%__MODULE__{store: store} = authority, credential) do
    with {:ok, health} <- Store.authorized_health(store, credential) do
      {:ok, %{health | dispatch_enabled: power_dispatch_enabled?(authority)}}
    end
  end

  @doc "Trusted one-time provisioning for the fixed local diagnostic principal."
  def provision_diagnostic(%__MODULE__{store: store}),
    do: Store.provision_principal(store, @diagnostic_principal, ["read"], [])

  @doc "Trusted one-time host-maintenance provisioning; no Thing or control grants."
  def provision_maintenance(%__MODULE__{store: store}),
    do: Store.provision_principal(store, "maintenance:local", ["host:maintain"], [])

  @doc "Explicit trusted source-transfer custody; no maintenance or Thing grants."
  def provision_transfer(%__MODULE__{store: store}),
    do: Store.provision_transfer(store)

  @doc "Trusted native custodian scope; not an ordinary socket operation."
  def native_setup_identity(%__MODULE__{store: store}), do: Store.native_setup_identity(store)

  @doc "Trusted local pairing scope; no ordinary socket operation or revision change."
  def pairing_setup_context(%__MODULE__{store: store}), do: Store.pairing_setup_context(store)

  @doc "Trusted local pairing opening from current Store scope and installed public identity."
  def pairing_open(authority, identity, duration_ms \\ 300_000) do
    pairing_review(authority, fn reviews ->
      with {:ok, scope} <- pairing_setup_context(authority),
           do: PairingReview.open(reviews, identity, scope, duration_ms)
    end)
  end

  @doc "Trusted private request preconfirmation, before the bounded network exchange."
  def pairing_prepare(authority, admin, request),
    do: pairing_review(authority, &PairingReview.prepare(&1, admin, request))

  def pairing_pending(authority, admin),
    do: pairing_review(authority, &PairingReview.pending(&1, admin))

  @doc "Trusted explicit approval; reads current Store scope outside the review process."
  def pairing_approve(
        authority,
        admin,
        reference,
        access \\ PairingCodec.default_access()
      ) do
    pairing_review(authority, fn reviews ->
      with {:ok, scope} <- pairing_setup_context(authority),
           do: PairingReview.approve(reviews, admin, reference, scope, access)
    end)
  end

  def pairing_deny(authority, admin, reference),
    do: pairing_review(authority, &PairingReview.deny(&1, admin, reference))

  def pairing_close(authority, admin),
    do: pairing_review(authority, &PairingReview.close(&1, admin))

  @doc "Post-TLS finite offer; no principal, approval or durable change is created."
  def pairing_offer(%__MODULE__{store: store} = authority, request) do
    with {:ok, _} <- PairingCodec.encode("request", request) do
      case Store.pairing_consumed(store, request["invitation_id"]) do
        :consumed -> {:error, :invitation_consumed}
        :available -> pairing_review(authority, &PairingReview.offer(&1, request))
        _ -> {:error, :pairing_unavailable}
      end
    else
      _ -> {:error, :invitation_unavailable}
    end
  catch
    :exit, _ -> {:error, :pairing_unavailable}
  end

  @doc "Post-TLS original bootstrap completion; a consumed invitation never reissues a secret."
  def pairing_complete(%__MODULE__{store: store} = authority, request) do
    with {:ok, _} <- PairingCodec.encode("request", request) do
      case Store.pairing_consumed(store, request["invitation_id"]) do
        :consumed ->
          {:error, :invitation_consumed}

        :available ->
          pairing_review(authority, fn reviews ->
            with {:ok, reference, approval} <- PairingReview.checkout(reviews, request) do
              try do
                complete_pairing(store, reviews, reference, approval)
              after
                finish_pairing(reviews, reference)
              end
            end
          end)
          |> pairing_refusal()

        _ ->
          {:error, :pairing_unavailable}
      end
    else
      _ -> {:error, :invitation_unavailable}
    end
  catch
    :exit, _ -> {:error, :pairing_unavailable}
  end

  @doc "Trusted exact association recovery; original receipt is separate from current status."
  def pairing_client_status(%__MODULE__{store: store}, lookup),
    do: Store.pairing_client_status(store, lookup)

  @doc "Trusted local reconciliation after lost delivery; requires exact original and Store CAS."
  def revoke_paired_client(%__MODULE__{store: store}, lookup, expected),
    do: Store.revoke_paired_client(store, lookup, expected)

  defp complete_pairing(store, reviews, reference, approval) do
    case Store.pairing_commit(store, reviews, reference, approval) do
      {:ok, receipt, credential} ->
        response =
          Map.take(
            approval,
            ConsumptionCodec.original_fields() ++
              ~w(deployment_id owner_id authority_epoch permissions target_ids)
          )
          |> Map.merge(Map.take(receipt, ~w(principal_id revision)))
          |> Map.put("credential", Base.url_encode64(credential, padding: false))

        with {:ok, _} <- PairingCodec.encode("paired", response),
             do: {:ok, response},
             else: (_ -> {:error, :outcome_unknown})

      error ->
        error
    end
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp finish_pairing(reviews, reference) do
    PairingReview.finish(reviews, reference)
  catch
    :exit, _ -> :ok
  end

  defp pairing_refusal({:ok, _} = success), do: success

  defp pairing_refusal({:error, reason})
       when reason in [
              :pairing_closed,
              :pairing_expired,
              :invitation_unavailable,
              :invitation_consumed,
              :confirmation_denied,
              :pairing_busy,
              :pairing_unavailable,
              :outcome_unknown
            ],
       do: {:error, reason}

  defp pairing_refusal(_), do: {:error, :pairing_unavailable}

  defp pairing_review(%__MODULE__{pairing_reviews: reviews} = authority, callback) do
    with owner when is_pid(owner) <- owner(authority),
         review when is_pid(review) <- resolve(reviews),
         :ok <- PairingReview.bound_owner(review, owner) do
      callback.(review)
    else
      _ -> {:error, :pairing_unavailable}
    end
  catch
    :exit, _ -> {:error, :pairing_unavailable}
  end

  @doc "Reconcile a durably held native secret's verifier; issues no credential."
  def ensure_native_principal(%__MODULE__{store: store}, input),
    do: Store.ensure_native_principal(store, input)

  @doc "Trusted read-only original native custody; not an ordinary socket operation."
  def existing_native_principal(%__MODULE__{store: store}, input),
    do: Store.existing_native_principal(store, input)

  @doc "Trusted native operator access mutation after original custody review."
  def native_target_change(%__MODULE__{store: store}, action, input, guard \\ fn -> :ok end),
    do: Store.native_target_change(store, action, input, guard)

  def native_target_status(%__MODULE__{store: store}, input),
    do: Store.native_target_status(store, input)

  def controller_status(%__MODULE__{store: store}, credential),
    do: Store.controller_status(store, credential)

  @doc "Authenticated active controller context; no provisioning or target access."
  def controller_identity(%__MODULE__{store: store}, credential),
    do: Store.controller_identity(store, credential)

  @doc "Authenticated current owner and own grants; a read does not authorize a later effect."
  def controller_scope(%__MODULE__{store: store}, credential),
    do: Store.controller_scope(store, credential)

  def retirement_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.retirement_status(store, credential, epoch, operation)

  def retire_controller(%__MODULE__{store: store}, credential, input),
    do: Store.retire_controller(store, credential, input)

  @doc "Trusted foreground destination recovery; absent from ordinary socket authority."
  def accept_controller_transfer(%__MODULE__{store: store}, token, credential, input),
    do: Store.accept_controller_transfer(store, token, credential, input)

  def transfer_acceptance_status(%__MODULE__{store: store}, credential, input),
    do: Store.transfer_acceptance_status(store, credential, input)

  @doc "Explicit foreground recovery review; the private owner checks the operator PID."
  def prepare_controller_transfer(%__MODULE__{recovery_reviews: nil}),
    do: {:error, :recovery_review_unavailable}

  def prepare_controller_transfer(%__MODULE__{recovery_reviews: reviews}),
    do: WotexHome.Recovery.ReviewOwner.prepare(reviews)

  def approve_controller_transfer(%__MODULE__{recovery_reviews: nil}, _, _, _),
    do: {:error, :recovery_review_unavailable}

  def approve_controller_transfer(%__MODULE__{recovery_reviews: reviews}, token, digest, package),
    do: WotexHome.Recovery.ReviewOwner.approve(reviews, token, digest, package)

  def controller_transfer_review_status(%__MODULE__{recovery_reviews: nil}, _),
    do: {:error, :recovery_review_unavailable}

  def controller_transfer_review_status(%__MODULE__{recovery_reviews: reviews}, token),
    do: WotexHome.Recovery.ReviewOwner.status(reviews, token)

  def cancel_controller_transfer(%__MODULE__{recovery_reviews: nil}, _),
    do: {:error, :recovery_review_unavailable}

  def cancel_controller_transfer(%__MODULE__{recovery_reviews: reviews}, token),
    do: WotexHome.Recovery.ReviewOwner.cancel(reviews, token)

  def export_retired_profile_backup(%__MODULE__{store: store}, destination, key),
    do: Store.export_retired_backup(store, destination, key)

  @doc "Offline trusted source export under a transient read-only owner; no Host is started."
  def export_retired_directory(directory, destination, key) do
    case WotexHome.Recovery.Source.start_link(directory) do
      {:ok, supervisor} ->
        try do
          with {:ok, authority} <- WotexHome.Recovery.Source.authority(supervisor),
               do: export_retired_profile_backup(authority, destination, key)
        after
          Supervisor.stop(supervisor)
        end

      {:error, :invalid_retired_source} = error ->
        error

      _ ->
        {:error, :retired_source_unavailable}
    end
  end

  @doc "Trusted one-time profile manager setup; no enrollment, qualification or control grants."
  def provision_profile_manager(%__MODULE__{store: store}),
    do: Store.provision_principal(store, "profiles:local", ["profile:manage"], [])

  @doc "Explicit foreground profile operator; enrollment review and management only."
  def provision_profile_operator(%__MODULE__{store: store}),
    do:
      Store.provision_principal(
        store,
        "profile-operator:local",
        ["profile:manage", "enroll:review"],
        []
      )

  def import_profile(%__MODULE__{} = authority, credential, bytes) do
    with {:ok, digest} <- stage_profile(authority, credential, bytes),
         {:ok, artifact} <- WotexHome.Profiles.Artifact.parse(bytes),
         true <- artifact.digest == digest do
      {:ok, WotexHome.Profiles.Wire.import_summary(artifact)}
    else
      false -> {:error, :profile_artifact_unavailable}
      error -> error
    end
  end

  def profile_review_status(authority, credential, token),
    do: profile_review_operation(authority, credential, token, :status)

  def cancel_profile_review(authority, credential, token),
    do: profile_review_operation(authority, credential, token, :cancel)

  defp profile_review_operation(authority, credential, token, action) do
    with {:ok, principal} <- Store.profile_review_actor(authority.store, credential),
         :ok <- profile_review_token(token),
         {:ok, owner} <- profile_review_owner(authority.profile_reviews) do
      case action do
        :status ->
          WotexHome.Profiles.ReviewSession.status(owner, principal, token)

        :cancel ->
          WotexHome.Profiles.ReviewSession.cancel(owner, principal, token)
      end
    else
      error -> error
    end
  catch
    :exit, _ -> {:error, :profile_review_unavailable}
  end

  defp profile_review_token(token),
    do: if(Id.valid?(token), do: :ok, else: {:error, :invalid_profile_review})

  defp profile_review_owner(nil), do: {:error, :profile_review_unavailable}
  defp profile_review_owner(owner), do: {:ok, owner}

  @doc "Authenticated inert import; approval and target selection remain separate."
  def stage_profile(%__MODULE__{store: store} = authority, credential, bytes) do
    with {:ok, _} <- Store.profile_review_actor(store, credential),
         {:ok, custody} <- profile_custody(authority),
         do: WotexHome.Profiles.Custody.stage(custody, bytes)
  catch
    :exit, _ -> {:error, :profile_custody_unavailable}
  end

  @doc "Authenticated inert authoring-object staging; no authoring operation or approval starts."
  def stage_authoring_object(%__MODULE__{store: store} = authority, credential, kind, bytes) do
    with {:ok, _} <- Store.profile_review_actor(store, credential),
         {:ok, custody} <- profile_custody(authority),
         {:ok, digest} <- WotexHome.Profiles.Custody.stage_object(custody, kind, bytes),
         {:ok, object} <- WotexHome.Profiles.Custody.read_object(custody, digest),
         do: WotexHome.Profiles.AuthoringObject.summary(object)
  catch
    :exit, _ -> {:error, :profile_custody_unavailable}
  end

  @doc "Imports bytes through the single Store's immutable actor/original ownership transaction."
  def import_authoring_object(%__MODULE__{store: store}, credential, input, bytes),
    do: Store.import_authoring_object(store, credential, input, bytes)

  @doc "Reads inert bytes only after current actor-owned import history is verified."
  def read_authoring_object(%__MODULE__{store: store}, credential, digest),
    do: Store.read_authoring_object(store, credential, digest)

  @doc "Projects only explicit bounded passages after verifying complete actor ownership."
  def authoring_source_passages(%__MODULE__{store: store}, credential, selectors),
    do: Store.authoring_source_passages(store, credential, selectors)

  def authoring_object_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.authoring_object_status(store, credential, epoch, operation)

  def prepare_authoring_generation(%__MODULE__{store: store}, credential, input),
    do: Store.prepare_authoring_generation(store, credential, input)

  @doc "Reads the caller's declared generation policy metadata without export permission or a provider call."
  def authoring_generation_options(%__MODULE__{store: store}, credential),
    do: Store.authoring_generation_options(store, credential)

  @doc "Starts one explicit original attempt against a retained preparation; retry never calls the provider again."
  def start_authoring_generation(%__MODULE__{store: store}, credential, input),
    do: Store.start_authoring_generation(store, credential, input)

  @doc "Reads an original handoff reservation and its separate inert generation result."
  def authoring_generation_attempt_status(
        %__MODULE__{store: store},
        credential,
        epoch,
        operation
      ),
      do: Store.authoring_generation_attempt_status(store, credential, epoch, operation)

  def authoring_generation_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.authoring_generation_status(store, credential, epoch, operation)

  def cancel_authoring_generation(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.cancel_authoring_generation(store, credential, epoch, operation)

  def assess_authoring_candidate(%__MODULE__{store: store}, credential, input),
    do: Store.assess_authoring_candidate(store, credential, input)

  def authoring_candidate_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.authoring_candidate_status(store, credential, epoch, operation)

  def review_authoring_candidate(%__MODULE__{store: store}, credential, input),
    do: Store.review_authoring_candidate(store, credential, input)

  def authoring_review_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.authoring_review_status(store, credential, epoch, operation)

  def inspect_external_profile(%__MODULE__{store: store}, credential, input),
    do: Store.inspect_external_profile(store, credential, input)

  def external_inspection_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.external_inspection_status(store, credential, epoch, operation)

  def change_external_trust(%__MODULE__{store: store}, credential, input),
    do: Store.change_external_trust(store, credential, input)

  def external_trust_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.external_trust_status(store, credential, epoch, operation)

  def change_external_target(%__MODULE__{store: store}, credential, input),
    do: Store.change_external_target(store, credential, input)

  def external_target_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.external_target_status(store, credential, epoch, operation)

  @doc "Measures the current native reader, private source and clock basis for input review."
  def external_routine_input_context(%__MODULE__{store: store}, credential, target, key),
    do: Store.external_routine_input_context(store, credential, target, key)

  @doc "Installs or revokes one reviewed external input under an immutable original operation."
  def change_external_routine_input(%__MODULE__{store: store}, credential, input),
    do: Store.change_external_routine_input(store, credential, input)

  @doc "Recovers this actor's exact input receipt without requiring a current reader or reviewer."
  def external_routine_input_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.external_routine_input_status(store, credential, epoch, operation)

  @doc "Native host receipt admission; no socket/model report body or credential enters this boundary."
  def accept_external_report(%__MODULE__{store: store}, input),
    do: Store.accept_external_report(store, input)

  def external_report_current(%__MODULE__{store: store}, credential, target, key),
    do: Store.external_report_current(store, credential, target, key)

  def external_report_status(%__MODULE__{store: store}, credential, input),
    do: Store.external_report_status(store, credential, input)

  def external_profile_catalogue(%__MODULE__{store: store}, credential),
    do: Store.external_profile_catalogue(store, credential)

  @doc "Reads current reader and maintenance comparison metadata without reserving an operation."
  def external_profile_context(%__MODULE__{store: store}, credential),
    do: Store.external_profile_context(store, credential)

  @doc "Reads safe configured source choices under current profile and enrollment permissions."
  def external_source_catalogue(%__MODULE__{store: store}, credential),
    do: Store.external_source_catalogue(store, credential)

  @doc "Reads exact external target counters, including absent and revoked identities."
  def external_target_basis(%__MODULE__{store: store}, credential, target),
    do: Store.external_target_basis(store, credential, target)

  @doc "Rebuilds the actor's inspected artifact from current reader and owned immutable bytes."
  def external_inspection_artifact(%__MODULE__{store: store}, credential, reference),
    do: Store.external_inspection_artifact(store, credential, reference)

  def profile_change(%__MODULE__{store: store}, credential, input),
    do: Store.profile_change(store, credential, input)

  def profile_operation_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.profile_operation_status(store, credential, epoch, operation)

  def profile_target(%__MODULE__{store: store}, credential, target),
    do: Store.profile_target(store, credential, target)

  def profile_catalogue(%__MODULE__{store: store}, credential),
    do: Store.profile_catalogue(store, credential)

  def collect_profiles(%__MODULE__{store: store}, credential),
    do: Store.collect_profiles(store, credential)

  @doc "Trusted foreground recovery export; not a socket route or a credential/authority transfer."
  def export_profile_backup(%__MODULE__{store: store}, destination, key),
    do: Store.export_profile_backup(store, destination, key)

  @doc "Retain a fresh one-use selection proposal with scoped transient byte custody."
  def prepare_profile_selection(%__MODULE__{} = authority, credential, input) do
    with {:ok, :new, basis} <- Store.profile_selection_basis(authority.store, credential, input),
         {:ok, document} <- WotexHome.Profiles.Operation.encode(input),
         {:ok, owner} <- profile_review_owner(authority.profile_reviews) do
      case WotexHome.Profiles.ReviewSession.pending(
             owner,
             basis["principal_id"],
             document
           ) do
        :not_found ->
          with {:ok, %WotexHome.Profiles.Review{} = review} <-
                 review_profile_selection(authority, credential, input) do
            WotexHome.Profiles.ReviewSession.hold(
              authority.profile_reviews,
              review.basis["principal_id"],
              review
            )
          end

        result ->
          result
      end
    end
  catch
    :exit, _ -> {:error, :profile_review_unavailable}
  end

  @doc "Trusted proposal from fresh operator-bound evidence; commits no selection or authority."
  def review_profile_selection(%__MODULE__{} = authority, credential, input) do
    with {:ok, :new, basis} <- Store.profile_selection_basis(authority.store, credential, input),
         {:ok, custody} <- profile_custody(authority),
         {:ok, lease} <- WotexHome.Profiles.Custody.lease(custody, input["artifact_digest"]) do
      try do
        with {:ok, runtime} <- ProfileBasis.runtime_digest(),
             {:ok, capture} <- capture(authority),
             {:ok, evidence} <-
               CaptureSession.checkout_auto(capture, basis["principal_id"], input["session_ref"]) do
          WotexHome.Profiles.Review.new(basis, lease.artifact, evidence, input, runtime)
        end
      after
        WotexHome.Profiles.Custody.release(custody, lease.token)
      end
    else
      {:ok, :existing, receipt} -> {:ok, :existing, receipt}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :profile_review_unavailable}
  end

  defp profile_custody(%__MODULE__{profile_custody: nil}),
    do: {:error, :profile_custody_unavailable}

  defp profile_custody(%__MODULE__{profile_custody: custody}), do: {:ok, custody}

  @doc "Trusted one-time controller provisioning after enrollment; never a request route."
  def provision_controller(%__MODULE__{store: store}, principal_id, thing_id),
    do: Store.provision_principal(store, principal_id, ["read", "control:ordinary"], [thing_id])

  @doc "Trusted target addition which replaces the principal's bearer credential atomically."
  def grant_target_and_rotate(%__MODULE__{store: store}, principal_id, thing_id),
    do: Store.grant_target_and_rotate(store, principal_id, thing_id)

  def support_preview(%__MODULE__{store: store}, credential),
    do: SupportExport.preview(store, credential)

  @doc "Read current Store-clock fact inputs for trusted draft evaluation, not admission."
  def rule_facts(%__MODULE__{store: store}, credential, fact_ids),
    do: Store.rule_facts_live(store, credential, fact_ids)

  @doc "Trusted local policy workflow; never grants control or bypasses qualification."
  def set_invariant(
        %__MODULE__{store: store},
        credential,
        epoch,
        operation,
        expected,
        target,
        previous,
        predicate
      ) do
    with {:ok, source} <- Codec.encode_predicate(predicate) do
      Store.set_invariant(store, credential, epoch, operation, expected, target, previous, source)
    end
  end

  def invariant_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.invariant_status(store, credential, epoch, operation)

  @doc "Admit only the supported explicit single-effect rule, independently of draft preview."
  def admit_rule(%__MODULE__{store: store}, credential, epoch, operation, expected, input) do
    with {:ok, rules} <- decode_rules(input),
         {:ok, source} <- Codec.encode(rules) do
      Store.admit_rule(store, credential, epoch, operation, expected, source)
    end
  end

  def activate_rule(%__MODULE__{store: store}, credential, epoch, operation, expected, admission),
    do: Store.activate_rule(store, credential, epoch, operation, expected, admission)

  def suspend_rules(%__MODULE__{} = authority, credential, epoch, operation, expected),
    do: activate_rule(authority, credential, epoch, operation, expected, 0)

  def invoke_rule(%__MODULE__{store: store}, credential, epoch, operation, generation, rule_id) do
    case Store.prepare_rule_invocation(store, credential, epoch, operation, generation, rule_id) do
      {:ok, :existing, receipt} ->
        {:ok, receipt}

      {:ok, preparation} ->
        with {:ok, projection} <- WotexHome.Rules.InvocationPreparation.proposal(preparation) do
          Store.commit_rule_invocation(store, credential, preparation, projection)
        end

      error ->
        error
    end
  end

  def begin_maintenance(%__MODULE__{store: store}, credential, epoch, operation, expected),
    do: Store.begin_maintenance(store, credential, epoch, operation, expected)

  def end_maintenance(
        %__MODULE__{store: store},
        credential,
        epoch,
        operation,
        expected,
        begin_revision
      ),
      do: Store.end_maintenance(store, credential, epoch, operation, expected, begin_revision)

  def maintenance_status(%__MODULE__{store: store}, credential),
    do: Store.maintenance_status(store, credential)

  def maintenance_update_status(%__MODULE__{store: store}, credential),
    do: Store.maintenance_update_status(store, credential)

  def maintenance_operation_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.maintenance_operation_status(store, credential, epoch, operation)

  def rule_status(%__MODULE__{store: store}, credential), do: Store.rule_status(store, credential)

  def current_rule_source(%__MODULE__{store: store}, credential),
    do: Store.current_rule_source(store, credential)

  def current_thing(%__MODULE__{store: store}, credential, thing_id),
    do: Store.current_thing(store, credential, thing_id)

  def rule_operation_status(%__MODULE__{store: store}, credential, epoch, operation),
    do: Store.rule_operation_status(store, credential, epoch, operation)

  def enrollment_status(%__MODULE__{store: store}, credential, review_ref),
    do: Store.enrollment_review_status(store, credential, review_ref)

  def lifx_discover(%__MODULE__{} = authority, credential) do
    with {:ok, operator_id} <- Store.authorize_capture(authority.store, credential),
         {:ok, capture} <- capture(authority),
         {:ok, session_ref, candidates} <- CaptureSession.discover_auto(capture, operator_id) do
      {:ok, session_ref, candidates}
    end
  end

  def lifx_interview(%__MODULE__{} = authority, credential, session_ref, candidate_ref) do
    with {:ok, operator_id} <- Store.authorize_capture(authority.store, credential),
         {:ok, capture} <- capture(authority),
         {:ok, interview} <-
           CaptureSession.interview_auto(capture, operator_id, session_ref, candidate_ref) do
      {:ok, interview, ProfileCatalogue.matching(interview)}
    end
  end

  @doc "Commit one host-held LIFX capture through an immutable packaged profile."
  def lifx_enroll(
        %__MODULE__{} = authority,
        credential,
        session_ref,
        candidate_ref,
        profile_ref,
        thing_id,
        review_ref
      ),
      do:
        commit_lifx_capture(
          authority,
          :enroll,
          credential,
          session_ref,
          candidate_ref,
          profile_ref,
          thing_id,
          review_ref
        )

  @doc "Re-review one enrolled LIFX Thing from a fresh host-held capture."
  def lifx_rereview(
        %__MODULE__{} = authority,
        credential,
        session_ref,
        candidate_ref,
        profile_ref,
        thing_id,
        review_ref
      ),
      do:
        commit_lifx_capture(
          authority,
          :rereview,
          credential,
          session_ref,
          candidate_ref,
          profile_ref,
          thing_id,
          review_ref
        )

  @doc "Refresh one enrolled LIFX Thing from fresh owner-held discovery and a scoped commit."
  def lifx_refresh(%__MODULE__{} = authority, credential, thing_id) do
    with {:ok, basis} <- Store.lifx_refresh_basis(authority.store, credential, thing_id),
         {:ok, capture} <- capture(authority),
         {:ok, reports} <- CaptureSession.refresh_auto(capture, basis.stable_id, basis.thing),
         {disposition, revisions} when disposition in [:ok, :duplicate] <-
           Store.commit_lifx_refresh(
             authority.store,
             credential,
             basis.stable_id,
             basis.binding_revision,
             basis.resource_revision,
             basis.thing,
             reports
           ) do
      {:ok,
       %{
         thing_id: thing_id,
         disposition: disposition,
         capability_keys: Enum.map(reports, & &1.capability_key),
         revisions: revisions
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Trusted no-send recovery against exact newer retained power evidence; not a wire route."
  def reconcile_lifx_power(
        %__MODULE__{store: store},
        credential,
        epoch,
        operation_id,
        receipt_revision,
        report_revision,
        boot_epoch,
        now_ms
      ),
      do:
        Store.reconcile_unknown_power(
          store,
          credential,
          epoch,
          operation_id,
          receipt_revision,
          report_revision,
          boot_epoch,
          now_ms
        )

  @doc "Run one bounded LIFX read and commit only its validated observations."
  def lifx_read(%__MODULE__{store: store}, candidate, target, thing, ledger, opts) do
    ReadPath.run(
      fn report_thing, reports -> Store.record_batch(store, report_thing, reports) end,
      candidate,
      target,
      thing,
      ledger,
      opts
    )
  end

  @doc "Run one supervised direct-power exchange through the selected interface."
  def lifx_execute_power(
        %__MODULE__{} = authority,
        principal_id,
        authority_epoch,
        operation_id,
        candidate,
        target,
        ledger,
        opts
      ) do
    with true <- authority.power_dispatch,
         supervisor when is_pid(supervisor) <- resolve(authority.power_supervisor),
         {:ok, timeout_ms} <- power_execution_timeout(opts) do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          run_power_worker(
            authority.store,
            principal_id,
            authority_epoch,
            operation_id,
            candidate,
            target,
            ledger,
            opts
          )
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :execution_worker_failed, ledger}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {:error, :execution_timeout, ledger}
      end
    else
      false -> {:error, :dispatch_disabled, ledger}
      nil -> {:error, :execution_unavailable, ledger}
      {:error, reason} -> {:error, reason, ledger}
    end
  end

  @doc "Deliver one retained explicit power original from fresh private capture through the supervised guarded exchange; accepts no bearer or caller routing."
  def deliver_explicit_power(%__MODULE__{} = authority, principal, epoch, operation, opts \\ []) do
    with :ok <- power_delivery_options(authority, opts),
         {:ok, basis} <-
           Store.explicit_power_delivery_basis(authority.store, principal, epoch, operation),
         {:ok, capture} <- capture(authority),
         {:ok, route} <-
           CaptureSession.power_route_auto(
             capture,
             basis.stable_id,
             basis.thing,
             basis.receipt.disposition
           ),
         {:ok, receipt} <- prepare_explicit_delivery(authority, basis, route) do
      execute_power_delivery(authority, receipt, route, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deliver one retained scheduled power original with Store-owned temporal guards, fresh private routing and supervised readback; no bearer or caller clock."
  def deliver_scheduled_power(%__MODULE__{} = authority, principal, epoch, operation, opts \\ []) do
    with :ok <- power_delivery_options(authority, opts),
         {:ok, basis} <-
           Store.scheduled_power_delivery_basis(authority.store, principal, epoch, operation),
         {:ok, owner} <- capture(authority),
         {:ok, route} <-
           CaptureSession.power_route_auto(
             owner,
             basis.stable_id,
             basis.thing,
             basis.receipt.disposition
           ),
         {:ok, receipt} <- prepare_scheduled_delivery(authority, basis, route) do
      execute_power_delivery(authority, receipt, route, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_scheduled_delivery(
         _authority,
         %{receipt: %{disposition: :queued} = receipt, baseline_source_epoch: source},
         %{source_epoch: source}
       ),
       do: {:ok, receipt}

  defp prepare_scheduled_delivery(_authority, %{receipt: %{disposition: :queued}}, _route),
    do: {:error, :observation_unavailable}

  defp prepare_scheduled_delivery(authority, basis, route) do
    Store.refresh_and_advance_scheduled_power(authority.store, basis, route.reports)
  end

  defp execute_power_delivery(authority, receipt, route, opts) do
    case receipt.disposition do
      :queued ->
        execution = [
          clock: route.clock,
          source_epoch: route.source_epoch,
          source_sequence: route.source_sequence,
          boot_epoch: route.boot_epoch,
          ack_timeout_ms: Keyword.get(opts, :ack_timeout_ms, 1_000),
          read_timeout_ms: Keyword.get(opts, :read_timeout_ms, 1_000),
          duration_ms: 0
        ]

        execution =
          case Keyword.fetch(opts, :transport_factory) do
            {:ok, factory} -> Keyword.put(execution, :transport_factory, factory)
            :error -> execution
          end

        case lifx_execute_power(
               authority,
               receipt.principal_id,
               receipt.authority_epoch,
               receipt.operation_id,
               route.candidate,
               route.target,
               route.ledger,
               execution
             ) do
          {:ok, settled, _ledger} -> {:ok, settled}
          {:error, reason, _ledger} -> {:error, reason}
        end

      _retained_phase ->
        {:ok, receipt}
    end
  end

  defp power_delivery_options(authority, opts) do
    cond do
      not authority.power_dispatch ->
        {:error, :dispatch_disabled}

      not is_pid(resolve(authority.power_supervisor)) ->
        {:error, :execution_unavailable}

      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, :invalid_power_delivery}

      Enum.any?(
        Keyword.keys(opts),
        &(&1 not in [:transport_factory, :ack_timeout_ms, :read_timeout_ms])
      ) ->
        {:error, :invalid_power_delivery}

      length(Enum.uniq(Keyword.keys(opts))) != length(opts) ->
        {:error, :invalid_power_delivery}

      not Enum.all?([:ack_timeout_ms, :read_timeout_ms], fn key ->
        value = Keyword.get(opts, key, 1_000)
        is_integer(value) and value in 1..5_000
      end) ->
        {:error, :invalid_power_delivery}

      Keyword.has_key?(opts, :transport_factory) and
          not is_function(Keyword.fetch!(opts, :transport_factory), 0) ->
        {:error, :invalid_power_delivery}

      true ->
        :ok
    end
  end

  defp prepare_explicit_delivery(
         _authority,
         %{receipt: %{disposition: :queued} = receipt},
         _route
       ),
       do: {:ok, receipt}

  defp prepare_explicit_delivery(authority, basis, route) do
    with {disposition, _} when disposition in [:ok, :duplicate] <-
           Store.commit_explicit_power_refresh(authority.store, basis, route.reports),
         {now, _utc} <- route.clock.(),
         do:
           advance_explicit_power(
             authority,
             basis.receipt.principal_id,
             basis.receipt.authority_epoch,
             basis.receipt.operation_id,
             route.boot_epoch,
             now
           )
  end

  def submit(%__MODULE__{store: store}, credential, input) do
    with {:ok, mutation} <- Mutation.new(input),
         {:ok, receipt} <- Store.submit_request(store, credential, mutation) do
      {:ok, receipt}
    end
  end

  def overrides(%__MODULE__{store: store}, credential, target_ids),
    do: Store.override_snapshot_live(store, credential, target_ids)

  def override_issue(
        %__MODULE__{store: store},
        credential,
        epoch,
        operation_id,
        target_id,
        basis_revision,
        duration_ms
      ),
      do:
        Store.issue_override_operation_live(
          store,
          credential,
          epoch,
          operation_id,
          target_id,
          basis_revision,
          duration_ms
        )

  def override_status(%__MODULE__{store: store}, credential, epoch, operation_id),
    do: Store.override_operation_status_live(store, credential, epoch, operation_id)

  def override_revoke(%__MODULE__{store: store}, credential, epoch, operation_id),
    do: Store.revoke_override_operation_live(store, credential, epoch, operation_id)

  def events(%__MODULE__{store: store}, credential, after_revision, page_size),
    do: Store.events_page(store, credential, after_revision, page_size)

  def request_events(%__MODULE__{store: store}, credential, after_revision, page_size),
    do: Store.request_events_page(store, credential, after_revision, page_size)

  def history(
        %__MODULE__{store: store},
        credential,
        thing_id,
        capability_key,
        watermark,
        after_revision,
        page_size
      ),
      do:
        Store.history_page(
          store,
          credential,
          thing_id,
          capability_key,
          watermark,
          after_revision,
          page_size
        )

  def catalogue(%__MODULE__{store: store}, credential, watermark, after_id, page_size),
    do: Store.catalogue_page(store, credential, watermark, after_id, page_size)

  def snapshot(%__MODULE__{store: store}, credential, watermark, after_key, page_size),
    do: Store.snapshot_page(store, credential, watermark, after_key, page_size)

  def request_status(%__MODULE__{store: store}, credential, epoch, operation_id),
    do: Store.request_status(store, credential, epoch, operation_id)

  def cancel(%__MODULE__{store: store}, credential, epoch, operation_id),
    do: Store.cancel_request(store, credential, epoch, operation_id)

  def review_rules(%__MODULE__{review_gate: nil}, _credential, _input),
    do: {:error, :review_unavailable}

  def review_rules(%__MODULE__{} = authority, credential, input) do
    with {:ok, rules} <- decode_rules(input),
         {:ok, things, watermark} <- Store.review_inputs(authority.store, credential) do
      ReviewGate.run(authority.review_gate, fn ->
        with {:ok, review} <- CandidateReview.review(rules, things),
             :ok <- Store.review_current(authority.store, credential, watermark) do
          {:ok, review, watermark}
        end
      end)
    end
  end

  def record_rule_review(
        %__MODULE__{} = authority,
        credential,
        epoch,
        operation_id,
        expected,
        input
      ) do
    with {:ok, rules} <- decode_rules(input),
         {:ok, document} <- Codec.encode(rules),
         {:ok, prepared} <-
           prepare_recorded_review(authority, credential, epoch, operation_id, expected, document) do
      case prepared do
        {:existing, receipt} ->
          {:ok, receipt}

        {:new, things, resources} ->
          if is_nil(authority.review_gate) do
            {:error, :review_unavailable}
          else
            ReviewGate.run(authority.review_gate, fn ->
              with {:ok, review} <- CandidateReview.review(rules, things),
                   {:ok, artifact} <- CandidateArtifact.build(rules, resources, review) do
                Store.commit_rule_review(
                  authority.store,
                  credential,
                  epoch,
                  operation_id,
                  expected,
                  document,
                  artifact
                )
              end
            end)
          end
      end
    end
  end

  def rule_review_status(%__MODULE__{store: store}, credential, epoch, operation_id),
    do: Store.rule_review_status(store, credential, epoch, operation_id)

  def original_rule_status(%__MODULE__{store: store}, credential, record) do
    with {:ok, _, _} <- WotexHome.Rules.OperationInput.from_record(record),
         do: Store.original_rule_status(store, credential, record)
  end

  @doc "Review or admit exact temporal content using fixed-root host timezone custody; remains inactive."
  def retain_schedule_content(%__MODULE__{} = authority, credential, kind, document)
      when kind in ["review", "admit"] do
    with {:ok, ^kind, input} <- WotexHome.Schedules.OperationInput.decode(document),
         {:ok, _scope} <- Store.authorize_schedule(authority.store, credential) do
      case Store.original_schedule_status(authority.store, credential, document) do
        {:ok, _receipt} ->
          Store.retain_schedule_content(authority.store, credential, document)

        :not_found ->
          if is_nil(authority.review_gate) do
            {:error, :review_unavailable}
          else
            ReviewGate.run(authority.review_gate, fn ->
              with {:ok, source, _rule} <- WotexHome.Schedules.OperationInput.source(kind, input),
                   {:ok, zone} <-
                     WotexHome.Schedules.Timezone.source(source, authority.timezone_options),
                   do: Store.retain_schedule_content(authority.store, credential, document, zone)
            end)
          end

        error ->
          error
      end
    else
      {:ok, _, _} -> {:error, :schedule_operation_kind_mismatch}
      error -> error
    end
  end

  def retain_schedule_content(%__MODULE__{}, _, _, _),
    do: {:error, :unsupported_schedule_operation}

  def original_schedule_status(%__MODULE__{store: store}, credential, document),
    do: Store.original_schedule_status(store, credential, document)

  @doc "Activate or suspend an original temporal operation through the Store's owned current basis."
  def change_schedule(%__MODULE__{store: store}, credential, kind, document)
      when kind in ["activate", "suspend"] do
    with {:ok, ^kind, _} <- WotexHome.Schedules.OperationInput.decode(document),
         do: Store.change_schedule(store, credential, document),
         else: (
           {:ok, _, _} -> {:error, :schedule_operation_kind_mismatch}
           error -> error
         )
  end

  def change_schedule(%__MODULE__{}, _, _, _), do: {:error, :unsupported_schedule_operation}

  def schedule_status(%__MODULE__{store: store}, credential),
    do: Store.schedule_status(store, credential)

  @doc "Read one retained own schedule through current review and target grants; no artifact or current admission claim."
  def schedule_source(%__MODULE__{store: store}, credential, revision),
    do: Store.schedule_source(store, credential, revision)

  @doc "Trusted one-flight occurrence calculation outside the writer, from one caller-bound Store snapshot. No bearer or caller clock."
  def consider_schedule(%__MODULE__{store: store}) do
    case Store.prepare_schedule_poll(store) do
      {:ok, reference, basis} ->
        try do
          with {:ok, record} <-
                 WotexHome.Schedules.Consideration.build(
                   basis.activation,
                   basis.artifact,
                   basis.snapshot,
                   basis.watermark
                 ),
               do: Store.commit_schedule_poll(store, reference, record)
        after
          Store.cancel_schedule_poll(store, reference)
        end

      result ->
        result
    end
  end

  @doc "Trusted bounded advancement of retained temporal intent, without a distributed operator credential."
  def advance_schedule(%__MODULE__{store: store}), do: Store.advance_schedule(store)

  @doc "Trusted advancement of one retained explicit power request under its original author; no bearer, timer or device send."
  def advance_explicit_power(%__MODULE__{store: store}, principal, epoch, operation, boot, now),
    do: Store.advance_explicit_power(store, principal, epoch, operation, boot, now)

  @doc "Trusted bounded selection of original explicit power work from the Store; no bearer or dispatch."
  def pending_explicit_power(%__MODULE__{store: store}, after_revision \\ 0),
    do: Store.pending_explicit_power(store, after_revision)

  @doc "Trusted bounded selection of original scheduled power work; author and temporal guards remain required."
  def pending_scheduled_power(%__MODULE__{store: store}, after_revision \\ 0),
    do: Store.pending_scheduled_power(store, after_revision)

  @doc "Close a failed unsent scheduled original; cannot recall claimed or handed work."
  def block_scheduled_power(%__MODULE__{store: store}, principal, epoch, operation, reason),
    do: Store.block_scheduled_power(store, principal, epoch, operation, reason)

  @doc "Read-only calendar resolution; its digest and instants do not establish a trusted clock."
  def schedule_timezone(%__MODULE__{} = authority, credential, name, local) do
    with {:ok, scope} <- Store.authorize_schedule(authority.store, credential),
         {:ok, result} <-
           WotexHome.Schedules.Timezone.resolve(name, local, authority.timezone_options),
         {:ok, current} <- Store.authorize_schedule(authority.store, credential),
         true <- current == scope,
         do: {:ok, result},
         else: (
           false -> {:error, :resnapshot_required}
           error -> error
         )
  end

  defp prepare_recorded_review(authority, credential, epoch, operation_id, expected, document) do
    case Store.prepare_rule_review(
           authority.store,
           credential,
           epoch,
           operation_id,
           expected,
           document
         ) do
      {:ok, :existing, receipt} -> {:ok, {:existing, receipt}}
      {:ok, :new, things, resources} -> {:ok, {:new, things, resources}}
      error -> error
    end
  end

  defp capture(%__MODULE__{capture: reference}) do
    case resolve(reference) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :capture_unavailable}
    end
  end

  defp commit_lifx_capture(
         authority,
         mode,
         credential,
         session_ref,
         candidate_ref,
         profile_ref,
         thing_id,
         review_ref
       )
       when mode in [:enroll, :rereview] do
    with true <- Id.valid?(session_ref) and Id.valid?(candidate_ref) and Id.valid?(review_ref),
         {:ok, package} <- ProfileCatalogue.fetch(profile_ref, thing_id),
         {:ok, operator_id} <- Store.authorize_capture(authority.store, credential),
         {:ok, capture} <- capture(authority),
         {:ok, evidence} <- CaptureSession.checkout_auto(capture, operator_id, session_ref),
         {:ok, candidates, interview} <- captured_selection(evidence, candidate_ref),
         profile = package.profile,
         {:ok, ^profile} <- Profile.match(interview, [profile]),
         selection = %{
           "operator_id" => operator_id,
           "candidate_ref" => candidate_ref,
           "stable_id" => interview.stable_id,
           "profile_ref" => profile_ref,
           "qualification_ref" => package.profile.qualification_ref,
           "method" => "legacy_tofu",
           "review_ref" => review_ref
         },
         {:ok, revision} <-
           commit_lifx_review(
             mode,
             authority.store,
             credential,
             candidates,
             interview,
             profile,
             package.thing,
             selection
           ) do
      {:ok,
       %{
         mode: mode,
         review_ref: review_ref,
         thing_id: thing_id,
         profile_ref: profile_ref,
         catalogue_digest: package.catalogue_digest,
         revision: revision
       }}
    else
      false -> {:error, :invalid_enrollment_selection}
      {:error, :unsupported} -> {:error, :profile_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_capture_evidence}
    end
  end

  defp captured_selection(
         %{
           candidates: candidates,
           selected_candidate_ref: candidate_ref,
           interview: %Interview{candidate_ref: candidate_ref} = interview
         },
         candidate_ref
       )
       when is_list(candidates) do
    case Enum.filter(candidates, &match?(%Candidate{raw_ref: ^candidate_ref}, &1)) do
      [_candidate] -> {:ok, candidates, interview}
      _ -> {:error, :invalid_capture_evidence}
    end
  end

  defp captured_selection(_evidence, _candidate_ref), do: {:error, :invalid_capture_evidence}

  defp commit_lifx_review(
         :enroll,
         store,
         credential,
         candidates,
         interview,
         profile,
         thing,
         selection
       ),
       do:
         Store.commit_enrollment(
           store,
           credential,
           candidates,
           interview,
           [profile],
           thing,
           selection
         )

  defp commit_lifx_review(
         :rereview,
         store,
         credential,
         candidates,
         interview,
         profile,
         thing,
         selection
       ),
       do:
         Store.rereview_enrollment(
           store,
           credential,
           candidates,
           interview,
           [profile],
           thing,
           selection
         )

  defp run_power_worker(
         store,
         principal_id,
         authority_epoch,
         operation_id,
         candidate,
         target,
         ledger,
         opts
       ) do
    {factory, execution_opts} = power_transport_factory(candidate, opts)

    case safe_open_transport(factory) do
      {:ok, transport, close} ->
        try do
          hooks = power_hooks(store, principal_id, authority_epoch, operation_id)

          PowerExecution.run(hooks, candidate, target, ledger, [
            {:transport, transport} | execution_opts
          ])
        after
          safe_close_transport(close)
        end

      {:error, reason} ->
        {:error, reason, ledger}
    end
  end

  defp power_hooks(store, principal_id, authority_epoch, operation_id) do
    %{
      claim: fn boot_epoch, now_ms ->
        Store.claim_lifx_power(
          store,
          principal_id,
          authority_epoch,
          operation_id,
          boot_epoch,
          now_ms
        )
      end,
      handoff: fn claim, now_ms ->
        Store.handoff_claimed_power(
          store,
          principal_id,
          authority_epoch,
          operation_id,
          claim.token,
          now_ms
        )
      end,
      ack: fn claim ->
        Store.accept_power_ack(
          store,
          principal_id,
          authority_epoch,
          operation_id,
          claim.token
        )
      end,
      settle: fn claim, observation ->
        Store.settle_power_readback(
          store,
          principal_id,
          authority_epoch,
          operation_id,
          claim.token,
          observation
        )
      end,
      unknown: fn claim, reason ->
        Store.mark_power_outcome_unknown(
          store,
          principal_id,
          authority_epoch,
          operation_id,
          claim.token,
          reason
        )
      end
    }
  end

  defp power_transport_factory(candidate, opts) do
    case Keyword.pop(opts, :transport_factory) do
      {nil, execution_opts} ->
        factory = fn ->
          with {:ok, scope} <- InterfaceSelection.select(candidate.interface_id),
               {:ok, adapter} <- WotexUdp.open(scope) do
            {:ok, {WotexUdp, adapter}, fn -> WotexUdp.close(adapter) end}
          end
        end

        {factory, Keyword.delete(execution_opts, :transport)}

      {factory, execution_opts} ->
        {factory, Keyword.delete(execution_opts, :transport)}
    end
  end

  defp safe_open_transport(factory) when is_function(factory, 0) do
    case factory.() do
      {:ok, {module, _handle} = transport, close}
      when is_atom(module) and is_function(close, 0) ->
        {:ok, transport, close}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :transport_unavailable}
    end
  rescue
    _ -> {:error, :transport_unavailable}
  catch
    _, _ -> {:error, :transport_unavailable}
  end

  defp safe_open_transport(_factory), do: {:error, :transport_unavailable}

  defp safe_close_transport(close) do
    _ = close.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp power_execution_timeout(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         ack when is_integer(ack) and ack in 1..5_000 <- Keyword.get(opts, :ack_timeout_ms),
         read when is_integer(read) and read in 1..5_000 <- Keyword.get(opts, :read_timeout_ms) do
      {:ok, ack + read + 5_000}
    else
      _ -> {:error, :invalid_power_execution}
    end
  end

  defp power_execution_timeout(_opts), do: {:error, :invalid_power_execution}

  defp resolve(nil), do: nil

  defp resolve(reference) do
    GenServer.whereis(reference)
  rescue
    ArgumentError -> nil
  end

  defp power_dispatch_enabled?(%__MODULE__{power_dispatch: true, power_supervisor: reference}),
    do: is_pid(resolve(reference))

  defp power_dispatch_enabled?(%__MODULE__{}), do: false

  defp decode_rules(input) when is_list(input) and length(input) in 1..64 do
    Enum.reduce_while(input, {:ok, []}, fn raw, {:ok, rules} ->
      case Rule.new(raw) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  defp decode_rules(_input), do: {:error, :invalid_rule_set}
end
