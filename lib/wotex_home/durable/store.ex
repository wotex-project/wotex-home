defmodule WotexHome.Durable.Store do
  @moduledoc """
  Single-process SQLite writer for observations, enrollment and held receipts.

  Held requests, queued direct Light power and pre-handoff worker claims share
  one writer. Claims carry no send authority. The host must provide an owned
  database path and supervise this process. Qualified transport handoff and
  readback guards are required before a mutating driver can be connected.

  Start one Store per owned data directory with `start_link/1`. Observation
  adapters use `record/3` or `record_batch/3`; local API handlers read current
  state and submit scoped operations through this writer. Every accepted
  transaction advances a revision, so clients can detect stale views and
  reconcile a lost response with the same operation ID.

  The Store persists decisions and effect claims. It never opens a device
  transport. Treat its returned receipts as durable state, not proof that a
  bulb changed or that an unqualified worker may send.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias WotexHome.{Id, Mutation}
  alias WotexHome.Discovery.EnrollmentReview
  alias WotexHome.Durable.{Backup, HostLock, Receipt, Registry}
  alias WotexHome.Durable.Store.Access
  alias WotexHome.Durable.Store.ControllerWriter
  alias WotexHome.Durable.Store.EnrollmentWriter
  alias WotexHome.Durable.Store.CandidateWriter
  alias WotexHome.Durable.Store.ExecutionWriter
  alias WotexHome.Durable.Store.FactReadModel
  alias WotexHome.Durable.Store.HealthReadModel
  alias WotexHome.Durable.Store.Integrity
  alias WotexHome.Durable.Store.InvariantWriter
  alias WotexHome.Durable.Store.Journal
  alias WotexHome.Durable.Store.MaintenanceWriter
  alias WotexHome.Durable.Store.NativePrincipalWriter
  alias WotexHome.Durable.Store.NativeTargetHistory
  alias WotexHome.Durable.Store.NativeTargetWriter
  alias WotexHome.Durable.Store.ObservationCodec
  alias WotexHome.Durable.Store.ObservationWriter
  alias WotexHome.Durable.Store.OverrideWriter
  alias WotexHome.Durable.Store.PrincipalWriter
  alias WotexHome.Durable.Store.ProfileTransition
  alias WotexHome.Durable.Store.ProfileWriter
  alias WotexHome.Durable.Store.ProfileByteContext
  alias WotexHome.Durable.Store.QualificationWriter
  alias WotexHome.Durable.Store.RefreshWriter
  alias WotexHome.Durable.Store.RequestLedger
  alias WotexHome.Durable.Store.RuleWriter
  alias WotexHome.Durable.Store.ReviewReadModel
  alias WotexHome.Durable.Store.Schema
  alias WotexHome.Durable.Store.StateReadModel
  alias WotexHome.Durable.Store.ThingReadModel
  alias WotexHome.Durable.Store.TransferWriter
  alias WotexHome.Lifx.{ColorPlan, PowerClaim, ProfileBasis}
  alias WotexHome.Qualification.Decision
  alias WotexHome.Semantics.{Capability, Observation, Thing}
  alias WotexHome.Profiles.{Custody, Operation, Review, ReviewSession}
  alias WotexHome.Recovery.{ReviewOwner, TransferAcceptanceCodec, TransferReviewCodec}

  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  import Access, only: [authenticate: 2]

  import Journal, only: [next_revision: 1]

  import ExecutionWriter,
    only: [
      admit_held_power_tx: 9,
      claim_queued_power_tx: 9,
      handoff_claimed_power_tx: 8,
      accept_power_ack_tx: 5,
      settle_power_readback_tx: 7,
      mark_power_outcome_unknown_tx: 6,
      abandoned_worker_tx: 4,
      reject_abandoned_claim_tx: 5,
      fence_rule_generation_tx: 3,
      settle_held_color_noop_tx: 7,
      settle_held_power_noop_tx: 8,
      inspect_held_color_result: 6,
      inspect_held_power_result: 6,
      reconcile_unknown_power_tx: 10
    ]

  import EnrollmentWriter,
    only: [
      commit_enrollment_tx: 6,
      enroll_thing_tx: 3,
      enrollment_review_status_result: 3,
      narrow_thing_tx: 4,
      rereview_enrollment_tx: 6,
      revoke_thing_tx: 2
    ]

  import ObservationCodec, only: [decode_current: 3]

  import RequestLedger,
    only: [submit_request_tx: 4, cancel_request_tx: 4, select_request: 4, decode_receipt: 4]

  import RefreshWriter,
    only: [lifx_refresh_basis_result: 3, commit_lifx_refresh_tx: 8, valid_lifx_stable_id?: 1]

  import StateReadModel,
    only: [
      snapshot_page_result: 5,
      catalogue_page_result: 5,
      history_page_result: 7,
      events_page_result: 4,
      request_events_page_result: 4
    ]

  import OverrideWriter,
    only: [
      active_override_leases_query: 5,
      issue_override_lease_tx: 8,
      issue_override_operation_tx: 9,
      override_operation_status_query: 6,
      owned_override_operation_ids: 3,
      revoke_override_lease_tx: 5,
      revoke_override_operation_tx: 6
    ]

  import PrincipalWriter,
    only: [
      grant_target_and_rotate_tx: 5,
      provision_principal_tx: 6,
      revoke_principal_tx: 2,
      revoke_target_grant_tx: 3,
      rotate_principal_credential_tx: 4
    ]

  @select_current """
  SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch,
         source_time_utc_ms, received_time_utc_ms, received_monotonic_ms,
         quality, trust, value_kind, value_a, value_b, revision
  FROM observation_current WHERE thing_id = ? AND capability_key = ?
  """
  @profile_guard_denials WotexHome.Durable.Store.ProfileGuard.denials()
  @max_i64 9_223_372_036_854_775_807
  @max_receipts 65_536
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    receipt_limit = Keyword.get(opts, :receipt_limit, @max_receipts)
    case_keys = Keyword.get(opts, :qualification_case_keys, %{})
    decision_keys = Keyword.get(opts, :qualification_decision_keys, %{})

    GenServer.start_link(
      __MODULE__,
      {path, receipt_limit, case_keys, decision_keys, Keyword.get(opts, :profile_custody),
       Keyword.get(opts, :profile_reviews), Keyword.get(opts, :controller_mode, :normal),
       Keyword.get(opts, :recovery_operator), Keyword.get(opts, :recovery_reviews)},
      Keyword.take(opts, [:name])
    )
  end

  @spec record(GenServer.server(), Observation.t(), Capability.t()) ::
          {:ok, non_neg_integer()} | {:duplicate, non_neg_integer()} | {:error, atom()}
  def record(server, observation, capability),
    do: GenServer.call(server, {:record, observation, capability})

  @doc "Trusted native scope read; no public API route or credential material."
  def native_setup_identity(server), do: GenServer.call(server, :native_setup_identity)

  @doc "Trusted original custody lookup; never provisions or rotates."
  def existing_native_principal(server, input),
    do: GenServer.call(server, {:existing_native_principal, input})

  @doc "Trusted fixed-role custody reconciliation; accepts a verifier, never a secret."
  def ensure_native_principal(server, input),
    do: GenServer.call(server, {:ensure_native_principal, input})

  @doc "Trusted original operator target review; no ordinary socket route."
  def native_target_change(server, action, input, guard \\ fn -> :ok end),
    do: GenServer.call(server, {:native_target_change, action, input, guard})

  @doc "Trusted original native access receipt lookup; missing is unresolved."
  def native_target_status(server, input),
    do: GenServer.call(server, {:native_target_status, input})

  @doc "Atomically record one device reply's declared capability observations."
  @spec record_batch(GenServer.server(), Thing.t(), [Observation.t()]) ::
          {:ok, [non_neg_integer()]}
          | {:duplicate, [non_neg_integer()]}
          | {:error, atom()}
  def record_batch(server, thing, observations),
    do: GenServer.call(server, {:record_batch, thing, observations})

  @doc "Resolve one authenticated, target-scoped LIFX refresh without exposing routing state."
  @spec lifx_refresh_basis(GenServer.server(), binary(), String.t()) ::
          {:ok,
           %{
             stable_id: String.t(),
             binding_revision: pos_integer(),
             thing: Thing.t(),
             resource_revision: non_neg_integer()
           }}
          | {:error, atom()}
  def lifx_refresh_basis(server, credential, thing_id),
    do: GenServer.call(server, {:lifx_refresh_basis, credential, thing_id})

  @doc "Recheck one LIFX refresh basis and atomically retain its validated report batch."
  @spec commit_lifx_refresh(
          GenServer.server(),
          binary(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          Thing.t(),
          [Observation.t()]
        ) ::
          {:ok, [non_neg_integer()]}
          | {:duplicate, [non_neg_integer()]}
          | {:error, atom()}
  def commit_lifx_refresh(
        server,
        credential,
        stable_id,
        binding_revision,
        resource_revision,
        thing,
        observations
      ),
      do:
        GenServer.call(
          server,
          {:commit_lifx_refresh, credential, stable_id, binding_revision, resource_revision,
           thing, observations}
        )

  @doc "Trusted, one-use source-epoch approval after device identity requalification."
  @spec authorize_source_epoch(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  def authorize_source_epoch(
        server,
        thing_id,
        capability_key,
        old_epoch,
        new_epoch,
        current_revision
      ),
      do:
        GenServer.call(
          server,
          {:authorize_source_epoch, thing_id, capability_key, old_epoch, new_epoch,
           current_revision}
        )

  @spec current(GenServer.server(), String.t(), String.t()) ::
          {:ok, Observation.t(), non_neg_integer()} | :not_found | {:error, atom()}
  def current(server, thing_id, capability_key),
    do: GenServer.call(server, {:current, thing_id, capability_key})

  @spec revision(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def revision(server), do: GenServer.call(server, :revision)

  @doc "Bounded in-process recovery view without principal, target or secret data."
  @spec health(GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def health(server), do: GenServer.call(server, :health)

  @spec authorized_health(GenServer.server(), binary()) :: {:ok, map()} | {:error, atom()}
  def authorized_health(server, credential),
    do: GenServer.call(server, {:authorized_health, credential})

  @doc "Checks an operator's current enrollment-review permission before a read-only capture."
  @spec authorize_capture(GenServer.server(), binary()) ::
          {:ok, String.t()} | {:error, atom()}
  def authorize_capture(server, credential),
    do: GenServer.call(server, {:authorize_capture, credential})

  @doc "A scoped, revision-stable page of current reports. Any intervening write requires a new snapshot."
  @spec snapshot_page(
          GenServer.server(),
          binary(),
          nil | non_neg_integer(),
          nil | map(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def snapshot_page(server, credential, watermark, after_key, page_size),
    do: GenServer.call(server, {:snapshot_page, credential, watermark, after_key, page_size})

  @doc "Inspect one granted active Thing using the Store's current receipt clock."
  def current_thing(server, credential, thing_id),
    do: GenServer.call(server, {:current_thing, credential, thing_id})

  @doc "A scoped, revision-stable page of active Thing declarations."
  @spec catalogue_page(
          GenServer.server(),
          binary(),
          nil | non_neg_integer(),
          nil | String.t(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def catalogue_page(server, credential, watermark, after_id, page_size),
    do: GenServer.call(server, {:catalogue_page, credential, watermark, after_id, page_size})

  @doc "A scoped page of the append-only observation journal for one capability."
  @spec history_page(
          GenServer.server(),
          binary(),
          String.t(),
          String.t(),
          nil | non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def history_page(
        server,
        credential,
        thing_id,
        capability_key,
        watermark,
        after_revision,
        page_size
      ),
      do:
        GenServer.call(
          server,
          {:history_page, credential, thing_id, capability_key, watermark, after_revision,
           page_size}
        )

  @doc "A scoped observation feed after a global revision cursor; no device I/O or subscription."
  @spec events_page(GenServer.server(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def events_page(server, credential, after_revision, page_size),
    do: GenServer.call(server, {:events_page, credential, after_revision, page_size})

  @doc "A principal's durable request events after a global revision cursor."
  @spec request_events_page(GenServer.server(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def request_events_page(server, credential, after_revision, page_size),
    do: GenServer.call(server, {:request_events_page, credential, after_revision, page_size})

  @doc "Read-only, target-scoped inputs for an external draft review."
  @spec review_inputs(GenServer.server(), binary()) ::
          {:ok, %{String.t() => Thing.t()}, non_neg_integer()} | {:error, atom()}
  def review_inputs(server, credential), do: GenServer.call(server, {:review_inputs, credential})

  @doc "Confirm that the review credential and inputs remain current after external checking."
  @spec review_current(GenServer.server(), binary(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def review_current(server, credential, watermark),
    do: GenServer.call(server, {:review_current, credential, watermark})

  @doc "Authenticated preview facts using only the Store's own receipt clock; no effect authority."
  def rule_facts_live(server, credential, fact_ids),
    do: GenServer.call(server, {:rule_facts_live, credential, fact_ids})

  @doc "Authenticated in-process constraint replacement; not a public request route."
  def set_invariant(server, credential, epoch, operation, expected, target, previous, source),
    do:
      GenServer.call(
        server,
        {:set_invariant, credential, epoch, operation, expected, target, previous, source}
      )

  def invariant_status(server, credential, epoch, operation),
    do: GenServer.call(server, {:invariant_status, credential, epoch, operation})

  def admit_rule(server, credential, epoch, operation, expected, source),
    do:
      GenServer.call(
        server,
        {:admit_rule, credential, epoch, operation, expected, source},
        10_000
      )

  def activate_rule(server, credential, epoch, operation, expected, admission),
    do:
      GenServer.call(
        server,
        {:activate_rule, credential, epoch, operation, expected, admission},
        10_000
      )

  def invoke_rule(server, credential, epoch, operation, generation, rule_id),
    do:
      GenServer.call(
        server,
        {:invoke_rule, credential, epoch, operation, generation, rule_id},
        10_000
      )

  def begin_maintenance(server, credential, epoch, operation, expected),
    do:
      GenServer.call(
        server,
        {:maintenance_change, credential, epoch, operation, expected, "begin", 0},
        10_000
      )

  def end_maintenance(server, credential, epoch, operation, expected, begin_revision),
    do:
      GenServer.call(
        server,
        {:maintenance_change, credential, epoch, operation, expected, "end", begin_revision},
        10_000
      )

  def maintenance_status(server, credential),
    do: GenServer.call(server, {:maintenance_status, credential})

  def maintenance_operation_status(server, credential, epoch, operation),
    do: GenServer.call(server, {:maintenance_operation_status, credential, epoch, operation})

  def controller_status(server, credential),
    do: GenServer.call(server, {:controller_status, credential})

  def controller_identity(server, credential),
    do: GenServer.call(server, {:controller_identity, credential})

  def retirement_status(server, credential, epoch, operation),
    do: GenServer.call(server, {:retirement_status, credential, epoch, operation})

  def retire_controller(server, credential, input),
    do: GenServer.call(server, {:retire_controller, credential, input})

  @doc "Trusted foreground recovery only; consumes a bound private one-use review."
  def accept_controller_transfer(server, token, credential, input),
    do: GenServer.call(server, {:accept_controller_transfer, token, credential, input}, 180_000)

  @doc "Trusted recovery-mode original receipt; no challenge, current trust or mutation."
  def transfer_acceptance_status(server, credential, input),
    do: GenServer.call(server, {:transfer_acceptance_status, credential, input}, 60_000)

  @doc "Current profile lifecycle actor, derived from its credential."
  def profile_review_actor(server, credential),
    do: GenServer.call(server, {:profile_review_actor, credential})

  @doc "Authenticated retained profile lifecycle operation."
  def profile_change(server, credential, input),
    do: GenServer.call(server, {:profile_change, credential, input}, 15_000)

  def profile_operation_status(server, credential, epoch, operation),
    do: GenServer.call(server, {:profile_operation_status, credential, epoch, operation})

  def profile_target(server, credential, target),
    do: GenServer.call(server, {:profile_target, credential, target}, 15_000)

  def profile_catalogue(server, credential),
    do: GenServer.call(server, {:profile_catalogue, credential}, 15_000)

  def profile_selection_basis(server, credential, input),
    do: GenServer.call(server, {:profile_selection_basis, credential, input})

  def collect_profiles(server, credential),
    do: GenServer.call(server, {:collect_profiles, credential}, 20_000)

  def rule_status(server, credential), do: GenServer.call(server, {:rule_status, credential})

  def current_rule_source(server, credential),
    do: GenServer.call(server, {:current_rule_source, credential})

  def rule_operation_status(server, credential, epoch, operation),
    do: GenServer.call(server, {:rule_operation_status, credential, epoch, operation})

  @doc "Prepare an immutable review or return its exact original result before checking."
  def prepare_rule_review(server, credential, epoch, operation_id, expected, rules_document),
    do:
      GenServer.call(
        server,
        {:prepare_rule_review, credential, epoch, operation_id, expected, rules_document}
      )

  @doc "Trusted Authority-only checked candidate retention; never effect admission."
  def commit_rule_review(
        server,
        credential,
        epoch,
        operation_id,
        expected,
        rules_document,
        artifact_document
      ),
      do:
        GenServer.call(
          server,
          {:commit_rule_review, credential, epoch, operation_id, expected, rules_document,
           artifact_document}
        )

  def rule_review_status(server, credential, epoch, operation_id),
    do: GenServer.call(server, {:rule_review_status, credential, epoch, operation_id})

  def original_rule_status(server, credential, record),
    do: GenServer.call(server, {:original_rule_status, credential, record})

  @doc "Trusted local encrypted backup export; key custody and restore authorization stay outside Store."
  @spec export_backup(GenServer.server(), String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def export_backup(server, destination, key),
    do: GenServer.call(server, {:export_backup, destination, key}, 120_000)

  @doc "Trusted local consistent archive including every retained portable profile byte."
  def export_profile_backup(server, destination, key),
    do: GenServer.call(server, {:export_profile_backup, destination, key}, 120_000)

  @doc "Trusted original retired-source export; an existing exact archive is a retry."
  def export_retired_backup(server, destination, key),
    do: GenServer.call(server, {:export_retired_backup, destination, key}, 120_000)

  @doc "Trusted local provisioning boundary; never expose this through a request facade."
  @spec enroll_thing(GenServer.server(), Thing.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def enroll_thing(server, thing), do: GenServer.call(server, {:enroll_thing, thing})

  @doc "Authenticate an explicit reviewed enrollment; this records identity selection, not control qualification."
  def commit_enrollment(server, credential, candidates, interview, profiles, thing, selection),
    do:
      GenServer.call(
        server,
        {:commit_enrollment, credential, candidates, interview, profiles, thing, selection}
      )

  @doc "Authenticate a fresh identity interview for an existing reviewed Thing, retaining the prior review."
  def rereview_enrollment(server, credential, candidates, interview, profiles, thing, selection),
    do:
      GenServer.call(
        server,
        {:rereview_enrollment, credential, candidates, interview, profiles, thing, selection}
      )

  @doc "Read one review reference for its authenticated enrollment operator after an uncertain commit."
  @spec enrollment_review_status(GenServer.server(), binary(), String.t()) ::
          {:ok, map()} | :not_found | {:error, atom()}
  def enrollment_review_status(server, credential, review_ref),
    do: GenServer.call(server, {:enrollment_review_status, credential, review_ref})

  @doc "Trusted compare-and-swap reduction of an enrolled declaration; clears current reports and held work."
  @spec narrow_thing(GenServer.server(), Thing.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def narrow_thing(server, thing, expected_revision),
    do: GenServer.call(server, {:narrow_thing, thing, expected_revision})

  @doc "Trusted local removal boundary; atomically rejects this Thing's held requests."
  @spec revoke_thing(GenServer.server(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_thing(server, thing_id), do: GenServer.call(server, {:revoke_thing, thing_id})

  @doc "Trusted local provisioning boundary; returns a new random credential once."
  @spec provision_principal(GenServer.server(), String.t(), [String.t()], [String.t()]) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def provision_principal(server, principal_id, permissions, target_ids),
    do: GenServer.call(server, {:provision_principal, principal_id, permissions, target_ids})

  @doc "Trusted one-time transfer role derived atomically from the active ownership epoch."
  def provision_transfer(server), do: GenServer.call(server, :provision_transfer)

  @doc "Trusted grant expansion with mandatory atomic credential rotation."
  @spec grant_target_and_rotate(GenServer.server(), String.t(), String.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def grant_target_and_rotate(server, principal_id, thing_id),
    do: GenServer.call(server, {:grant_target_and_rotate, principal_id, thing_id})

  @doc "Trusted local revocation boundary."
  @spec revoke_principal(GenServer.server(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_principal(server, principal_id),
    do: GenServer.call(server, {:revoke_principal, principal_id})

  @doc "Trusted target-grant revocation; atomically rejects this principal's held work for the target."
  @spec revoke_target_grant(GenServer.server(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_target_grant(server, principal_id, thing_id),
    do: GenServer.call(server, {:revoke_target_grant, principal_id, thing_id})

  @doc "Trusted one-time credential rotation; invalidates the prior credential and held work."
  @spec rotate_principal_credential(GenServer.server(), String.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def rotate_principal_credential(server, principal_id),
    do: GenServer.call(server, {:rotate_principal_credential, principal_id})

  @doc "Authenticate and durably stage a typed request from current registry state."
  @spec submit_request(GenServer.server(), binary(), Mutation.t()) ::
          {:ok, Receipt.t()} | {:error, atom()}
  def submit_request(server, credential, mutation),
    do: GenServer.call(server, {:submit_request, credential, mutation})

  @spec request_status(GenServer.server(), binary(), non_neg_integer(), String.t()) ::
          {:ok, Receipt.t()} | :not_found | {:error, atom()}
  def request_status(server, credential, authority_epoch, operation_id),
    do: GenServer.call(server, {:request_status, credential, authority_epoch, operation_id})

  @doc "Withdraw held or still-queued work before claim while retaining its operation-ID receipt."
  @spec cancel_request(GenServer.server(), binary(), non_neg_integer(), String.t()) ::
          {:ok, Receipt.t()} | :not_found | {:error, atom()}
  def cancel_request(server, credential, authority_epoch, operation_id),
    do: GenServer.call(server, {:cancel_request, credential, authority_epoch, operation_id})

  @doc "Read-only current-state check for a held absolute Light power request; never admits or dispatches."
  @spec inspect_held_power(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, :already_reported | :requires_effect, map()} | {:error, atom()}
  def inspect_held_power(server, credential, authority_epoch, operation_id, boot_epoch, now_ms),
    do:
      GenServer.call(
        server,
        {:inspect_held_power, credential, authority_epoch, operation_id, boot_epoch, now_ms}
      )

  @doc "Read-only current-state plan for a held partial Light colour request; never admits or dispatches."
  @spec inspect_held_color(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, ColorPlan.t(), map()} | {:error, atom()}
  def inspect_held_color(server, credential, authority_epoch, operation_id, boot_epoch, now_ms),
    do:
      GenServer.call(
        server,
        {:inspect_held_color, credential, authority_epoch, operation_id, boot_epoch, now_ms}
      )

  @doc "Atomically close a held Light power request only when a fresh current report already matches."
  @spec settle_held_power_noop(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, Receipt.t()} | {:error, atom()}
  def settle_held_power_noop(
        server,
        credential,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms
      ),
      do:
        GenServer.call(
          server,
          {:settle_held_power_noop, credential, authority_epoch, operation_id, boot_epoch, now_ms}
        )

  @doc "Atomically close held Light colour work only when its fresh complete HSBK value already matches."
  @spec settle_held_color_noop(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, Receipt.t()} | {:error, atom()}
  def settle_held_color_noop(
        server,
        credential,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms
      ),
      do:
        GenServer.call(
          server,
          {:settle_held_color_noop, credential, authority_epoch, operation_id, boot_epoch, now_ms}
        )

  @doc "Promote one held direct Light power request only after current authority and qualified evidence checks."
  def admit_held_power(server, credential, authority_epoch, operation_id, boot_epoch, now_ms),
    do:
      GenServer.call(
        server,
        {:admit_held_power, credential, authority_epoch, operation_id, boot_epoch, now_ms}
      )

  @doc "Trusted worker claim for one queued direct-power operation; the token has no send authority."
  def claim_queued_power(
        server,
        principal_id,
        authority_epoch,
        operation_id,
        boot_epoch,
        now_ms
      ),
      do:
        GenServer.call(
          server,
          {:claim_queued_power, principal_id, authority_epoch, operation_id, boot_epoch, now_ms}
        )

  @doc "Claim queued direct power and return the exact immutable LIFX command context."
  @spec claim_lifx_power(
          GenServer.server(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, PowerClaim.t()} | {:error, atom()}
  def claim_lifx_power(server, principal_id, authority_epoch, operation_id, boot_epoch, now_ms),
    do:
      GenServer.call(
        server,
        {:claim_lifx_power, principal_id, authority_epoch, operation_id, boot_epoch, now_ms}
      )

  @doc "Persist the final authority recheck immediately before a claimed power send."
  def handoff_claimed_power(
        server,
        principal_id,
        authority_epoch,
        operation_id,
        claim_token,
        now_ms
      ),
      do:
        GenServer.call(
          server,
          {:handoff_claimed_power, principal_id, authority_epoch, operation_id, claim_token,
           now_ms}
        )

  @doc "Record a correlated device ACK for the current handed-off power claim."
  @spec accept_power_ack(
          GenServer.server(),
          String.t(),
          non_neg_integer(),
          String.t(),
          binary()
        ) :: {:ok, Receipt.t()} | {:error, atom()}
  def accept_power_ack(server, principal_id, authority_epoch, operation_id, claim_token),
    do:
      GenServer.call(
        server,
        {:accept_power_ack, principal_id, authority_epoch, operation_id, claim_token}
      )

  @doc "Atomically retain a correlated power readback and settle its handed-off receipt."
  @spec settle_power_readback(
          GenServer.server(),
          String.t(),
          non_neg_integer(),
          String.t(),
          binary(),
          Observation.t()
        ) :: {:ok, Receipt.t()} | {:error, atom()}
  def settle_power_readback(
        server,
        principal_id,
        authority_epoch,
        operation_id,
        claim_token,
        observation
      ),
      do:
        GenServer.call(
          server,
          {:settle_power_readback, principal_id, authority_epoch, operation_id, claim_token,
           observation}
        )

  @doc "Conservatively close an unsettled handed-off power claim as outcome unknown."
  @spec mark_power_outcome_unknown(
          GenServer.server(),
          String.t(),
          non_neg_integer(),
          String.t(),
          binary(),
          atom()
        ) :: {:ok, Receipt.t()} | {:error, atom()}
  def mark_power_outcome_unknown(
        server,
        principal_id,
        authority_epoch,
        operation_id,
        claim_token,
        reason
      ),
      do:
        GenServer.call(
          server,
          {:mark_power_outcome_unknown, principal_id, authority_epoch, operation_id, claim_token,
           reason}
        )

  @doc """
  Explicitly reconcile an unknown direct-power receipt with a newer retained report.

  This trusted recovery seam performs no device I/O. The host must own and stop
  old transports across Store restart. Both expected revisions fence the exact
  evidence; current credentials, grants, declaration and qualification recheck.
  """
  @spec reconcile_unknown_power(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer()
        ) ::
          {:ok, Receipt.t()} | {:error, atom()}
  def reconcile_unknown_power(
        server,
        credential,
        epoch,
        operation_id,
        receipt_revision,
        report_revision,
        boot_epoch,
        now_ms
      ),
      do:
        GenServer.call(
          server,
          {:reconcile_unknown_power, credential, epoch, operation_id, receipt_revision,
           report_revision, boot_epoch, now_ms}
        )

  @doc "Trusted recovery of a claimed operation whose worker exited before any handoff."
  def reject_abandoned_claim(server, principal_id, authority_epoch, operation_id),
    do:
      GenServer.call(
        server,
        {:reject_abandoned_claim, principal_id, authority_epoch, operation_id}
      )

  @doc "Trusted empty-policy generation fence; invalidates all unsent prior work."
  def fence_rule_generation(server, expected_store_revision, authority_epoch),
    do: GenServer.call(server, {:fence_rule_generation, expected_store_revision, authority_epoch})

  @doc "Trusted reviewed LIFX direct-power qualification; no socket route or driver send authority."
  @spec qualify_lifx_power(GenServer.server(), binary(), map(), map(), map(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def qualify_lifx_power(server, credential, signed_decision, basis, cohort, attestations),
    do:
      GenServer.call(
        server,
        {:qualify_lifx_power, credential, signed_decision, basis, cohort, attestations},
        10_000
      )

  @doc "Issue one authenticated, current-boot Light power override; no driver authority."
  @spec issue_override_lease(
          GenServer.server(),
          binary(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, OverrideLease.t(), non_neg_integer()} | {:error, atom()}
  def issue_override_lease(
        server,
        credential,
        target_id,
        authority_epoch,
        basis_revision,
        now_ms,
        duration_ms
      ),
      do:
        GenServer.call(
          server,
          {:issue_override_lease, credential, target_id, authority_epoch, basis_revision, now_ms,
           duration_ms}
        )

  @doc "Issue an override using the Store's own monotonic time since its current start."
  @spec issue_override_lease_live(
          GenServer.server(),
          binary(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: {:ok, OverrideLease.t(), non_neg_integer()} | {:error, atom()}
  def issue_override_lease_live(
        server,
        credential,
        target_id,
        authority_epoch,
        basis_revision,
        duration_ms
      ),
      do:
        GenServer.call(
          server,
          {:issue_override_lease_live, credential, target_id, authority_epoch, basis_revision,
           duration_ms}
        )

  @doc "Read only current-boot leases for authenticated, granted targets."
  @spec active_override_leases(GenServer.server(), binary(), [String.t()], non_neg_integer()) ::
          {:ok, [OverrideLease.t()]} | {:error, atom()}
  def active_override_leases(server, credential, target_ids, now_ms),
    do: GenServer.call(server, {:active_override_leases, credential, target_ids, now_ms})

  @doc "Read current leases using the Store's own monotonic time since its current start."
  @spec active_override_leases_live(GenServer.server(), binary(), [String.t()]) ::
          {:ok, [OverrideLease.t()]} | {:error, atom()}
  def active_override_leases_live(server, credential, target_ids),
    do: GenServer.call(server, {:active_override_leases_live, credential, target_ids})

  @doc "Return a consistent live lease read and its Store-relative monotonic timestamp."
  @spec override_snapshot_live(GenServer.server(), binary(), [String.t()]) ::
          {:ok,
           %{now_ms: non_neg_integer(), leases: [OverrideLease.t()], owned_operation_ids: map()}}
          | {:error, atom()}
  def override_snapshot_live(server, credential, target_ids),
    do: GenServer.call(server, {:override_snapshot_live, credential, target_ids})

  @doc "Issue an idempotent, authenticated override operation using Store time."
  @spec issue_override_operation_live(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer()
        ) :: {:ok, map()} | {:error, atom()}
  def issue_override_operation_live(
        server,
        credential,
        authority_epoch,
        operation_id,
        target_id,
        basis_revision,
        duration_ms
      ),
      do:
        GenServer.call(
          server,
          {:issue_override_operation_live, credential, authority_epoch, operation_id, target_id,
           basis_revision, duration_ms}
        )

  @doc "Return the original override issue receipt and current active state."
  @spec override_operation_status_live(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t()
        ) ::
          {:ok, map()} | :not_found | {:error, atom()}
  def override_operation_status_live(server, credential, authority_epoch, operation_id),
    do:
      GenServer.call(
        server,
        {:override_operation_status_live, credential, authority_epoch, operation_id}
      )

  @doc "Revoke one current override operation idempotently."
  @spec revoke_override_operation_live(
          GenServer.server(),
          binary(),
          non_neg_integer(),
          String.t()
        ) ::
          {:ok, map()} | :not_found | {:error, atom()}
  def revoke_override_operation_live(server, credential, authority_epoch, operation_id),
    do:
      GenServer.call(
        server,
        {:revoke_override_operation_live, credential, authority_epoch, operation_id}
      )

  @doc "Revoke the caller's current override; historical issue/revocation events remain."
  @spec revoke_override_lease(GenServer.server(), binary(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_override_lease(server, credential, target_id, authority_epoch),
    do: GenServer.call(server, {:revoke_override_lease, credential, target_id, authority_epoch})

  @impl true
  def init(
        {path, receipt_limit, case_keys, decision_keys, profile_custody, profile_reviews, mode,
         operator, reviews}
      )
      when is_binary(path) and path != "" and path != ":memory:" and
             is_integer(receipt_limit) and receipt_limit >= 1 and
             receipt_limit <= @max_receipts do
    if valid_qualification_keys?(case_keys) and valid_qualification_keys?(decision_keys) and
         valid_controller_mode?(mode, operator, reviews) do
      Process.flag(:trap_exit, true)

      open_store(
        path,
        receipt_limit,
        case_keys,
        decision_keys,
        profile_custody,
        profile_reviews,
        mode,
        operator,
        reviews
      )
    else
      {:stop, :invalid_store_options}
    end
  end

  def init(
        {path, _receipt_limit, _case_keys, _decision_keys, _profile_custody, _profile_reviews,
         _mode, _operator, _reviews}
      )
      when not is_binary(path) or path == "" or path == ":memory:",
      do: {:stop, :invalid_store_path}

  def init(_options), do: {:stop, :invalid_store_options}

  defp open_store(
         path,
         receipt_limit,
         case_keys,
         decision_keys,
         profile_custody,
         profile_reviews,
         mode,
         operator,
         reviews
       ) do
    case HostLock.acquire(path) do
      {:ok, lock} ->
        case Sqlite3.open(path) do
          {:ok, db} ->
            case with :ok <- File.chmod(path, 0o600), do: boot(db, mode) do
              :ok ->
                {:ok,
                 %{
                   db: db,
                   lock: lock,
                   writable: mode == :normal,
                   retired: mode == :retired_readonly,
                   controller_mode: mode,
                   recovery_operator: operator,
                   recovery_reviews: reviews,
                   recovery_monitors:
                     if(mode == :recovery,
                       do: [Process.monitor(operator), Process.monitor(reviews)],
                       else: []
                     ),
                   receipt_limit: receipt_limit,
                   profile_custody: profile_custody,
                   profile_reviews: profile_reviews,
                   qualification_case_keys: case_keys,
                   qualification_decision_keys: decision_keys,
                   qualification_claim_root:
                     Path.join(Path.dirname(path), "qualification_claims"),
                   clock_epoch:
                     "boot:" <>
                       (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)),
                   clock_origin: System.monotonic_time(:millisecond),
                   claim_owners: %{}
                 }}

              {:error, reason} ->
                _ = Sqlite3.close(db)
                _ = HostLock.release(lock)
                {:stop, {:store_open_failed, reason}}
            end

          {:error, reason} ->
            _ = HostLock.release(lock)
            {:stop, {:store_open_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:store_open_failed, reason}}
    end
  end

  defp valid_qualification_keys?(keys) when is_map(keys) and map_size(keys) <= 32,
    do:
      Enum.all?(keys, fn {id, key} ->
        Id.valid?(id) and is_binary(key) and byte_size(key) == 32
      end)

  defp valid_qualification_keys?(_), do: false

  defp valid_controller_mode?(:recovery, operator, reviews),
    do:
      is_pid(operator) and is_pid(reviews) and operator != reviews and
        Process.alive?(operator) and Process.alive?(reviews)

  defp valid_controller_mode?(mode, nil, nil), do: mode in [:normal, :retired_readonly]
  defp valid_controller_mode?(_, _, _), do: false

  defp boot(db, :normal) do
    with :ok <- ensure_not_quarantined(db),
         :ok <- ensure_not_retired_before_migration(db),
         :ok <- configure(db),
         :ok <- initialize_schema(db),
         :ok <- ensure_active_controller(db),
         :ok <- ProfileByteContext.initialize(db),
         :ok <- Integrity.check_sqlite(db),
         :ok <- recover_handed_off(db) do
      :ok
    end
  end

  defp boot(db, :retired_readonly) do
    with :ok <- ensure_not_quarantined(db),
         :ok <- configure(db),
         :ok <- Integrity.check_sqlite(db),
         :ok <- Integrity.validate_snapshot(db),
         {:ok, %{state: "retired"}} <- ControllerWriter.identity(db),
         :ok <- ProfileByteContext.initialize(db) do
      :ok
    else
      {:ok, _} -> {:error, :source_not_retired}
      {:error, _} = error -> error
      _ -> {:error, :corrupt_controller_history}
    end
  end

  defp boot(db, :recovery) do
    with {:ok, [[version]]} when version in [21, 22, 23] <- query(db, "PRAGMA user_version"),
         :ok <- Integrity.check_sqlite(db),
         :ok <- Integrity.validate_snapshot(db),
         {:ok, identity} <- ControllerWriter.identity(db),
         {:ok, marker} <- query(db, "SELECT value FROM meta WHERE key='restore_quarantine'"),
         :ok <- recovery_source(db, version, identity, marker),
         :ok <- configure(db) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recovery_source}
    end
  end

  defp recovery_source(_db, _version, %{state: "retired"}, [[marker]])
       when is_integer(marker) and marker == 1,
       do: :ok

  defp recovery_source(db, version, %{state: "active"}, []) when version in [22, 23] do
    case query(db, "SELECT COUNT(*) FROM controller_acceptances") do
      {:ok, [[count]]} when is_integer(count) and count > 0 -> :ok
      _ -> {:error, :invalid_recovery_source}
    end
  end

  defp recovery_source(_, _, _, _), do: {:error, :invalid_recovery_source}

  defp recover_handed_off(db) do
    case transaction(db, fn db ->
           case query(
                  db,
                  "SELECT principal_id, authority_epoch, operation_id FROM request_execution WHERE state IN ('dispatching', 'protocol_accepted') ORDER BY principal_id, authority_epoch, operation_id LIMIT 1025"
                ) do
             {:ok, []} ->
               {:rollback, {:unchanged, :ok}}

             {:ok, rows} when length(rows) <= 1_024 ->
               case Enum.reduce_while(rows, :ok, fn [principal_id, epoch, operation_id], :ok ->
                      case recover_handed_off_row(db, principal_id, epoch, operation_id) do
                        :ok -> {:cont, :ok}
                        error -> {:halt, error}
                      end
                    end) do
                 :ok -> {:commit, :ok}
                 {:error, reason} -> {:rollback, reason}
               end

             {:ok, _rows} ->
               {:rollback, :recovery_capacity}

             {:error, reason} ->
               {:rollback, reason}
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, {:recovery_failed, reason}}
    end
  end

  defp recover_handed_off_row(db, principal_id, epoch, operation_id) do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = 'outcome_unknown', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state IN ('dispatching', 'protocol_accepted')",
             [revision, principal_id, epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'outcome_unknown', reason = 'crash_after_handoff', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition IN ('dispatching', 'protocol_accepted')",
             [revision, principal_id, epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO request_journal VALUES (?, ?, ?, ?, 'outcome_unknown', 'crash_after_handoff')",
             [revision, principal_id, epoch, operation_id]
           ),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp ensure_not_quarantined(db) do
    case query(db, "SELECT value FROM meta WHERE key = 'restore_quarantine'") do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :restore_requires_transfer}
      {:error, _} -> :ok
    end
  end

  defp ensure_active_controller(db) do
    case ControllerWriter.identity(db) do
      {:ok, %{state: "active"}} -> :ok
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  defp ensure_not_retired_before_migration(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in [21, 22, 23] -> ensure_active_controller(db)
      _ -> :ok
    end
  end

  @impl true
  def terminate(_reason, %{db: db, lock: lock}) do
    _ = Sqlite3.close(db)
    HostLock.release(lock)
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{controller_mode: :recovery} = state
      ) do
    if monitor in state.recovery_monitors,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{retired: true} = state),
    do: {:noreply, %{state | claim_owners: Map.delete(state.claim_owners, monitor)}}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.claim_owners, monitor) do
      {nil, owners} ->
        {:noreply, %{state | claim_owners: owners}}

      {{_caller, _token, {principal_id, epoch, operation_id}}, owners} ->
        next_state = %{state | claim_owners: owners}

        case transaction(state.db, fn db ->
               abandoned_worker_tx(db, principal_id, epoch, operation_id)
             end) do
          {:ok, _result} -> {:noreply, next_state}
          {:error, _reason} -> {:noreply, %{next_state | writable: false}}
        end
    end
  end

  @impl true
  def handle_call(request, {caller, _} = from, %{controller_mode: :recovery} = state) do
    if caller == state.recovery_operator,
      do: handle_recovery_call(request, from, state),
      else: {:reply, {:error, :recovery_operation_forbidden}, state}
  end

  def handle_call(request, from, state) do
    case ControllerWriter.identity(state.db) do
      {:ok, %{state: "retired"}} ->
        state = %{state | writable: false, retired: true}

        if retired_read?(request),
          do: handle_profile_call(request, from, state),
          else: {:reply, {:error, :source_retired}, state}

      {:ok, %{state: "active"}} when state.retired ->
        {:reply, {:error, :corrupt_controller_history}, %{state | writable: false}}

      {:ok, %{state: "active"}} ->
        handle_profile_call(request, from, state)

      {:error, _} ->
        state = %{state | writable: false}

        if request in [:health, :revision],
          do: handle_current_call(request, from, state),
          else: {:reply, {:error, :corrupt_controller_history}, state}
    end
  end

  defp handle_recovery_call(:health, from, state),
    do: handle_current_call(:health, from, state)

  defp handle_recovery_call({:transfer_acceptance_status, credential, input}, _from, state),
    do: {:reply, TransferWriter.existing(state.db, credential, input), state}

  defp handle_recovery_call({:accept_controller_transfer, token, credential, input}, _from, state) do
    result =
      case TransferWriter.existing(state.db, credential, input) do
        :not_found -> accept_recovery_review(state, token, credential, input)
        existing -> existing
      end

    {:reply, result, state}
  end

  defp handle_recovery_call(_, _, state),
    do: {:reply, {:error, :recovery_operation_forbidden}, state}

  defp accept_recovery_review(state, token, credential, input) do
    with {:ok, %{state: "retired"}} <- ControllerWriter.identity(state.db),
         {:ok, document} <- TransferAcceptanceCodec.encode("operation", input),
         {:ok, material} <- recovery_owner(state, &ReviewOwner.checkout(&1, token, document)) do
      try do
        with {:ok, review} <- TransferReviewCodec.decode(material.review_document),
             {:ok, hash} <- Registry.credential_hash(credential),
             true <- review["credential_hash"] == Base.encode16(hash, case: :lower) do
          case transaction(state.db, fn db ->
                 TransferWriter.accept_tx(
                   db,
                   material.review_document,
                   material.domain_document,
                   input,
                   fn -> recovery_owner(state, &ReviewOwner.guard(&1, token)) end
                 )
               end) do
            {:ok, result} -> result
            {:error, reason} when is_atom(reason) -> {:error, reason}
            {:error, {:policy, reason}} when is_atom(reason) -> {:error, reason}
            _ -> {:error, :store_unavailable}
          end
        else
          false -> {:error, :unauthorized}
          {:error, reason} when is_atom(reason) -> {:error, reason}
          _ -> {:error, :recovery_review_unavailable}
        end
      after
        _ = recovery_owner(state, &ReviewOwner.finish(&1, token))
      end
    else
      {:ok, _} -> {:error, :recovery_already_accepted}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :recovery_review_unavailable}
    end
  end

  defp recovery_owner(state, callback) do
    callback.(state.recovery_reviews)
  rescue
    _ -> {:error, :recovery_review_unavailable}
  catch
    _, _ -> {:error, :recovery_review_unavailable}
  end

  @impl true
  def format_status(%{state: %{controller_mode: :recovery}} = status),
    do: status |> Map.put(:state, :private_recovery_store) |> Map.put(:message, :redacted)

  def format_status(status), do: status

  defp retired_read?(request) when request in [:health, :revision], do: true

  defp retired_read?(request) when is_tuple(request) and tuple_size(request) > 0,
    do:
      elem(request, 0) in [
        :current,
        :authorized_health,
        :snapshot_page,
        :catalogue_page,
        :history_page,
        :events_page,
        :request_events_page,
        :request_status,
        :maintenance_status,
        :maintenance_operation_status,
        :profile_operation_status,
        :profile_target,
        :profile_catalogue,
        :enrollment_review_status,
        :rule_status,
        :rule_operation_status,
        :rule_review_status,
        :invariant_status,
        :controller_status,
        :retirement_status,
        :retire_controller,
        :export_backup,
        :export_profile_backup,
        :export_retired_backup
      ]

  defp retired_read?(_), do: false

  defp handle_profile_call(request, from, state) do
    state =
      case ProfileByteContext.prepare(state.db, state.profile_custody, request) do
        :ok -> state
        {:error, _} -> %{state | writable: false}
      end

    try do
      handle_current_call(request, from, state)
    after
      ProfileByteContext.clear(state.db)
    end
  end

  defp handle_current_call(
         {:record, _observation, _capability},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:accept_controller_transfer, _, _, _}, _from, state),
    do: {:reply, {:error, :recovery_operation_required}, state}

  defp handle_current_call({:transfer_acceptance_status, _, _}, _from, state),
    do: {:reply, {:error, :recovery_operation_required}, state}

  defp handle_current_call({:record_batch, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:commit_lifx_refresh, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:authorize_source_epoch, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:record, %Observation{} = observation, %Capability{} = capability},
         _from,
         state
       ) do
    if valid_pair?(observation, capability) do
      case transaction(state.db, fn db ->
             ObservationWriter.record(
               db,
               observation,
               capability,
               {state.clock_epoch, store_now_ms(state)}
             )
           end) do
        {:ok, result} -> {:reply, result, state}
        {:error, {:policy, reason}} -> {:reply, {:error, reason}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  defp handle_current_call({:record, _observation, _capability}, _from, state),
    do: {:reply, {:error, :invalid_observation}, state}

  defp handle_current_call({:record_batch, %Thing{} = thing, observations}, _from, state) do
    with {:ok, pairs} <- ObservationWriter.valid_batch(thing, observations) do
      case transaction(state.db, fn db ->
             ObservationWriter.record_batch(db, pairs, {state.clock_epoch, store_now_ms(state)})
           end) do
        {:ok, result} -> {:reply, result, state}
        {:error, {:policy, reason}} -> {:reply, {:error, reason}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_current_call({:record_batch, _thing, _observations}, _from, state),
    do: {:reply, {:error, :invalid_observation_batch}, state}

  defp handle_current_call({:lifx_refresh_basis, credential, thing_id}, _from, state) do
    result = lifx_refresh_basis_result(state.db, credential, thing_id)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:commit_lifx_refresh, credential, stable_id, binding_revision, resource_revision,
          %Thing{} = thing, observations},
         _from,
         state
       ) do
    with true <- valid_lifx_stable_id?(stable_id),
         true <- is_integer(binding_revision) and binding_revision in 1..@max_i64,
         true <- is_integer(resource_revision) and resource_revision in 0..@max_i64,
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, pairs} <- ObservationWriter.valid_batch(thing, observations) do
      write_reply(state, fn db ->
        commit_lifx_refresh_tx(
          db,
          hash,
          stable_id,
          binding_revision,
          resource_revision,
          thing,
          pairs,
          {state.clock_epoch, store_now_ms(state)}
        )
      end)
    else
      _ -> {:reply, {:error, :invalid_lifx_refresh}, state}
    end
  end

  defp handle_current_call({:commit_lifx_refresh, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_lifx_refresh}, state}

  defp handle_current_call(
         {:authorize_source_epoch, thing_id, capability_key, old_epoch, new_epoch,
          current_revision},
         _from,
         state
       ) do
    if Enum.all?([thing_id, capability_key, old_epoch, new_epoch], &Id.valid?/1) and
         old_epoch != new_epoch and is_integer(current_revision) and current_revision >= 0 and
         current_revision <= @max_i64 do
      write_reply(state, fn db ->
        ObservationWriter.authorize_source_epoch(
          db,
          thing_id,
          capability_key,
          old_epoch,
          new_epoch,
          current_revision
        )
      end)
    else
      {:reply, {:error, :invalid_source_epoch_grant}, state}
    end
  end

  defp handle_current_call({:current, thing_id, capability_key}, _from, state) do
    result =
      if Id.valid?(thing_id) and Id.valid?(capability_key) do
        case query(state.db, @select_current, [thing_id, capability_key]) do
          {:ok, []} -> :not_found
          {:ok, [row]} -> decode_current(thing_id, capability_key, row)
          {:error, _reason} -> {:error, :store_unavailable}
        end
      else
        {:error, :invalid_id}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(:revision, _from, state) do
    result =
      case query(state.db, "SELECT value FROM meta WHERE key = 'revision'") do
        {:ok, [[revision]]} -> {:ok, revision}
        _ -> {:error, :store_unavailable}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(:health, _from, state) do
    result = HealthReadModel.read(state.db, state.receipt_limit, state.writable)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:authorized_health, credential}, _from, state) do
    result =
      with {:ok, hash} <- Registry.credential_hash(credential),
           {:ok, _principal_id, permissions} <- authenticate(state.db, hash),
           true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])) do
        HealthReadModel.read(state.db, state.receipt_limit, state.writable)
      else
        false -> {:error, :permission_denied}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:authorize_capture, credential}, _from, state) do
    result =
      with {:ok, hash} <- Registry.credential_hash(credential),
           {:ok, principal_id, permissions} <- authenticate(state.db, hash),
           true <- "enroll:review" in permissions do
        {:ok, principal_id}
      else
        false -> {:error, :permission_denied}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:rule_facts_live, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:current_thing, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:current_thing, credential, thing_id}, _from, state) do
    result =
      ThingReadModel.read(
        state.db,
        credential,
        thing_id,
        {state.clock_epoch, store_now_ms(state)}
      )

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:rule_facts_live, credential, fact_ids}, _from, state) do
    result =
      FactReadModel.read(state.db, credential, fact_ids, {state.clock_epoch, store_now_ms(state)})

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:set_invariant, _, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:set_invariant, credential, epoch, operation, expected, target, previous, source},
         _from,
         state
       ) do
    write_reply(
      state,
      &InvariantWriter.set(&1, credential, epoch, operation, expected, target, previous, source)
    )
  end

  defp handle_current_call({:invariant_status, credential, epoch, operation}, _from, state) do
    result = InvariantWriter.status(state.db, credential, epoch, operation)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:admit_rule, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:activate_rule, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:invoke_rule, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:admit_rule, credential, epoch, operation, expected, source},
         _from,
         state
       ),
       do:
         write_reply(state, &RuleWriter.admit(&1, credential, epoch, operation, expected, source))

  defp handle_current_call(
         {:activate_rule, credential, epoch, operation, expected, admission},
         _from,
         state
       ),
       do:
         write_reply(
           state,
           &RuleWriter.activate(&1, credential, epoch, operation, expected, admission)
         )

  defp handle_current_call(
         {:invoke_rule, credential, epoch, operation, generation, rule_id},
         _from,
         state
       ),
       do:
         write_reply(
           state,
           &RuleWriter.invoke(
             &1,
             credential,
             epoch,
             operation,
             generation,
             rule_id,
             state.receipt_limit,
             fn -> {state.clock_epoch, store_now_ms(state)} end
           )
         )

  defp handle_current_call(
         {:maintenance_change, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:maintenance_change, credential, epoch, operation, expected, action, begin_revision},
         _from,
         state
       ),
       do:
         write_reply(
           state,
           &MaintenanceWriter.change(
             &1,
             credential,
             epoch,
             operation,
             expected,
             action,
             begin_revision
           )
         )

  defp handle_current_call({:maintenance_status, credential}, _from, state) do
    result = MaintenanceWriter.status(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:controller_status, credential}, _from, state) do
    result = ControllerWriter.status(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:controller_identity, credential}, _from, state) do
    result = ControllerWriter.authenticated_identity(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:export_retired_backup, destination, key}, _from, state) do
    result =
      with {:ok, receipt} <- ControllerWriter.source_receipt(state.db) do
        case Backup.export_profiles(state.db, destination, key, state.profile_custody) do
          {:ok, _} -> Backup.verify_retired_source(destination, key, receipt)
          {:error, :backup_exists} -> Backup.verify_retired_source(destination, key, receipt)
          error -> error
        end
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:retirement_status, credential, epoch, operation}, _from, state) do
    result = ControllerWriter.operation_status(state.db, credential, epoch, operation)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:retire_controller, _, _},
         _from,
         %{writable: false, retired: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:retire_controller, credential, input}, _from, state) do
    case write_reply(state, &ControllerWriter.retire(&1, credential, input)) do
      {:reply, {:ok, _} = result, next} ->
        {:reply, result, %{next | writable: false, retired: true}}

      result ->
        result
    end
  end

  defp handle_current_call(
         {:maintenance_operation_status, credential, epoch, operation},
         _from,
         state
       ) do
    result = MaintenanceWriter.operation_status(state.db, credential, epoch, operation)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:profile_change, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:profile_change, credential, input}, _from, state) do
    with {:ok, document} <- Operation.encode(input),
         {:ok, prepared} <- prepare_profile_change(state, credential, document) do
      case prepared do
        {:existing, receipt} ->
          {:reply, {:ok, receipt}, state}

        {:new, "approve", digest} ->
          case profile_lease(state.profile_custody, digest) do
            {:ok, lease} ->
              try do
                write_reply(
                  state,
                  &ProfileWriter.change(&1, credential, document, lease.artifact)
                )
              after
                profile_release(state.profile_custody, lease.token)
              end

            error ->
              {:reply, error, state}
          end

        {:new, action, _} when action in ["revoke", "revoke_selection"] ->
          write_reply(state, &ProfileWriter.change(&1, credential, document, nil))

        {:new, "select", _} ->
          commit_profile_selection(state, credential, document)
      end
    else
      error -> {:reply, error, read_health(state, error)}
    end
  end

  defp handle_current_call(
         {:profile_operation_status, credential, epoch, operation},
         _from,
         state
       ) do
    result = ProfileWriter.operation_status(state.db, credential, epoch, operation)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:profile_review_actor, credential}, _from, state) do
    result = ProfileWriter.review_actor(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:profile_catalogue, credential}, _from, state) do
    result =
      with {:ok, _} <- ProfileWriter.review_actor(state.db, credential),
           :ok <- ProfileByteContext.prepare_catalogue(state.db, state.profile_custody),
           do: ProfileWriter.catalogue(state.db, credential)

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:profile_target, credential, target}, _from, state) do
    result =
      with {:ok, _} <- ProfileWriter.review_actor(state.db, credential),
           true <- Id.valid?(target),
           :ok <- ProfileByteContext.prepare_catalogue(state.db, state.profile_custody),
           do: WotexHome.Durable.Store.ProfileTarget.snapshot(state.db, target)

    result = if result == false, do: {:error, :invalid_target}, else: result
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:profile_selection_basis, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:profile_selection_basis, credential, input}, _from, state) do
    result =
      with {:ok, document} <- Operation.encode(input),
           do: ProfileWriter.selection_basis(state.db, credential, document)

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:collect_profiles, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:collect_profiles, credential}, _from, state) do
    result =
      with {:ok, retained} <- ProfileWriter.collection_references(state.db, credential),
           do: collect_profile_custody(state.profile_custody, retained)

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:rule_status, credential}, _from, state) do
    result = RuleWriter.status(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:current_rule_source, credential}, _from, state) do
    result = RuleWriter.current_source(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:rule_operation_status, credential, epoch, operation}, _from, state) do
    result = RuleWriter.operation_status(state.db, credential, epoch, operation)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:review_inputs, credential}, _from, state) do
    result = ReviewReadModel.inputs(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:review_current, credential, watermark}, _from, state) do
    result = ReviewReadModel.current(state.db, credential, watermark)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:prepare_rule_review, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:commit_rule_review, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:prepare_rule_review, credential, epoch, operation_id, expected, document},
         _from,
         state
       ) do
    result =
      CandidateWriter.prepare(state.db, credential, epoch, operation_id, expected, document)

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:commit_rule_review, credential, epoch, operation_id, expected, rules, artifact},
         _from,
         state
       ) do
    write_reply(
      state,
      &CandidateWriter.commit(&1, credential, epoch, operation_id, expected, rules, artifact)
    )
  end

  defp handle_current_call({:rule_review_status, credential, epoch, operation_id}, _from, state) do
    result = CandidateWriter.status(state.db, credential, epoch, operation_id)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:original_rule_status, credential, record}, _from, state) do
    result = WotexHome.Durable.Store.RuleOriginalRead.status(state.db, credential, record)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:snapshot_page, credential, watermark, after_key, page_size},
         _from,
         state
       ) do
    result = snapshot_page_result(state.db, credential, watermark, after_key, page_size)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:catalogue_page, credential, watermark, after_id, page_size},
         _from,
         state
       ) do
    result = catalogue_page_result(state.db, credential, watermark, after_id, page_size)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:history_page, credential, thing_id, capability_key, watermark, after_revision,
          page_size},
         _from,
         state
       ) do
    result =
      history_page_result(
        state.db,
        credential,
        thing_id,
        capability_key,
        watermark,
        after_revision,
        page_size
      )

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:events_page, credential, after_revision, page_size}, _from, state) do
    result = events_page_result(state.db, credential, after_revision, page_size)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:request_events_page, credential, after_revision, page_size},
         _from,
         state
       ) do
    result = request_events_page_result(state.db, credential, after_revision, page_size)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:enrollment_review_status, credential, review_ref}, _from, state) do
    result = enrollment_review_status_result(state.db, credential, review_ref)
    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call({:export_backup, destination, key}, _from, state) do
    {:reply, Backup.export(state.db, destination, key), state}
  end

  defp handle_current_call({:export_profile_backup, destination, key}, _from, state) do
    {:reply, Backup.export_profiles(state.db, destination, key, state.profile_custody), state}
  end

  defp handle_current_call({:enroll_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:commit_enrollment, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:rereview_enrollment, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:narrow_thing, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:revoke_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:submit_request, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:cancel_request, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:settle_held_power_noop, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:settle_held_color_noop, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:admit_held_power, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:claim_queued_power, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:claim_lifx_power, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:handoff_claimed_power, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:accept_power_ack, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:settle_power_readback, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:mark_power_outcome_unknown, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:reject_abandoned_claim, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:reconcile_unknown_power, _, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:fence_rule_generation, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:qualify_lifx_power, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:issue_override_lease, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:issue_override_lease_live, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:revoke_override_lease, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:active_override_leases, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:active_override_leases_live, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:override_snapshot_live, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:issue_override_operation_live, _, _, _, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:revoke_override_operation_live, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(
         {:override_operation_status_live, _, _, _},
         _from,
         %{writable: false} = state
       ),
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({operation, _, _, _}, _from, %{writable: false} = state)
       when operation in [:provision_principal],
       do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(:provision_transfer, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call(:native_setup_identity, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:ensure_native_principal, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:native_target_change, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:native_target_change, action, input, guard}, _from, state),
    do: write_reply(state, &NativeTargetWriter.change_tx(&1, action, input, guard), guard)

  defp handle_current_call({:native_target_status, input}, _from, state) do
    result = NativeTargetWriter.status(state.db, input)

    writable =
      state.writable and
        result not in [
          {:error, :corrupt_native_setup},
          {:error, :corrupt_native_target_history}
        ]

    {:reply, result, %{state | writable: writable}}
  end

  defp handle_current_call({:revoke_principal, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:revoke_target_grant, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:grant_target_and_rotate, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:rotate_principal_credential, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  defp handle_current_call({:enroll_thing, %Thing{} = thing}, _from, state) do
    case Registry.encode_thing(thing) do
      {:ok, document} -> write_reply(state, fn db -> enroll_thing_tx(db, thing, document) end)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_current_call({:enroll_thing, _thing}, _from, state),
    do: {:reply, {:error, :invalid_thing}, state}

  defp handle_current_call(
         {:commit_enrollment, credential, candidates, interview, profiles, %Thing{} = thing,
          selection},
         _from,
         state
       ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, review} <-
           EnrollmentReview.new(candidates, interview, profiles, thing, selection),
         {:ok, document} <- Registry.encode_thing(thing) do
      write_reply(state, fn db ->
        commit_enrollment_tx(db, hash, review, interview, thing, document)
      end)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_current_call({:commit_enrollment, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_enrollment_review}, state}

  defp handle_current_call(
         {:rereview_enrollment, credential, candidates, interview, profiles, %Thing{} = thing,
          selection},
         _from,
         state
       ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, review} <-
           EnrollmentReview.new(candidates, interview, profiles, thing, selection),
         {:ok, document} <- Registry.encode_thing(thing) do
      write_reply(state, fn db ->
        rereview_enrollment_tx(db, hash, review, interview, thing, document)
      end)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_current_call({:rereview_enrollment, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_enrollment_review}, state}

  defp handle_current_call(
         {:qualify_lifx_power, credential, signed, basis, cohort, attestations},
         _from,
         state
       ) do
    with true <-
           map_size(state.qualification_case_keys) > 0 and
             map_size(state.qualification_decision_keys) > 0,
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, verified} <-
           Decision.verify(
             signed,
             basis,
             cohort,
             attestations,
             state.qualification_case_keys,
             state.qualification_decision_keys
           ) do
      write_reply(state, fn db ->
        QualificationWriter.qualify_lifx_power(
          db,
          hash,
          verified,
          basis,
          state.qualification_claim_root
        )
      end)
    else
      false -> {:reply, {:error, :qualification_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_current_call(
         {:issue_override_lease_live, credential, target_id, authority_epoch, basis_revision,
          duration_ms},
         from,
         state
       ) do
    handle_current_call(
      {:issue_override_lease, credential, target_id, authority_epoch, basis_revision,
       store_now_ms(state), duration_ms},
      from,
      state
    )
  end

  defp handle_current_call(
         {:issue_override_lease, credential, target_id, authority_epoch, basis_revision, now_ms,
          duration_ms},
         _from,
         state
       ) do
    if Id.valid?(target_id) and valid_stored_integer?(authority_epoch) and
         authority_epoch >= 1 and valid_stored_integer?(basis_revision) and
         valid_stored_integer?(now_ms) and is_integer(duration_ms) and
         duration_ms in 1..86_400_000 and now_ms <= @max_i64 - duration_ms do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          issue_override_lease_tx(
            db,
            hash,
            target_id,
            authority_epoch,
            basis_revision,
            now_ms,
            duration_ms,
            state.clock_epoch
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_override_lease}, state}
    end
  end

  defp handle_current_call(
         {:active_override_leases, credential, target_ids, now_ms},
         _from,
         state
       ) do
    if is_list(target_ids) and length(target_ids) <= 32 and
         Enum.all?(target_ids, &Id.valid?/1) and Enum.uniq(target_ids) == target_ids and
         valid_stored_integer?(now_ms) do
      result =
        with {:ok, hash} <- Registry.credential_hash(credential) do
          active_override_leases_query(
            state.db,
            hash,
            target_ids,
            now_ms,
            state.clock_epoch
          )
        end

      {:reply, result, read_health(state, result)}
    else
      {:reply, {:error, :invalid_override_query}, state}
    end
  end

  defp handle_current_call({:active_override_leases_live, credential, target_ids}, from, state) do
    handle_current_call(
      {:active_override_leases, credential, target_ids, store_now_ms(state)},
      from,
      state
    )
  end

  defp handle_current_call({:override_snapshot_live, credential, target_ids}, from, state) do
    now_ms = store_now_ms(state)

    case handle_current_call(
           {:active_override_leases, credential, target_ids, now_ms},
           from,
           state
         ) do
      {:reply, {:ok, leases}, next_state} ->
        result =
          with {:ok, hash} <- Registry.credential_hash(credential),
               {:ok, principal_id, _permissions} <- authenticate(next_state.db, hash),
               {:ok, owned_ids} <-
                 owned_override_operation_ids(next_state.db, principal_id, leases) do
            {:ok, %{now_ms: now_ms, leases: leases, owned_operation_ids: owned_ids}}
          end

        {:reply, result, read_health(next_state, result)}

      other ->
        other
    end
  end

  defp handle_current_call(
         {:issue_override_operation_live, credential, authority_epoch, operation_id, target_id,
          basis_revision, duration_ms},
         _from,
         state
       ) do
    now_ms = store_now_ms(state)

    if valid_override_operation_input?(authority_epoch, operation_id) and Id.valid?(target_id) and
         valid_stored_integer?(basis_revision) and is_integer(duration_ms) and
         duration_ms in 1..86_400_000 and now_ms <= @max_i64 - duration_ms do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        case write_reply(state, fn db ->
               issue_override_operation_tx(
                 db,
                 hash,
                 authority_epoch,
                 operation_id,
                 target_id,
                 basis_revision,
                 duration_ms,
                 now_ms,
                 state.clock_epoch
               )
             end) do
          {:reply, {:ok, _original}, next_state} ->
            result =
              override_operation_status_query(
                next_state.db,
                hash,
                authority_epoch,
                operation_id,
                next_state.clock_epoch,
                store_now_ms(next_state)
              )

            case result do
              {:ok, _receipt} -> {:reply, result, next_state}
              _ -> {:reply, {:error, :store_unavailable}, %{next_state | writable: false}}
            end

          other ->
            other
        end
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_override_operation}, state}
    end
  end

  defp handle_current_call(
         {:override_operation_status_live, credential, epoch, operation_id},
         _from,
         state
       ) do
    if valid_override_operation_input?(epoch, operation_id) do
      result =
        with {:ok, hash} <- Registry.credential_hash(credential) do
          override_operation_status_query(
            state.db,
            hash,
            epoch,
            operation_id,
            state.clock_epoch,
            store_now_ms(state)
          )
        end

      {:reply, result, read_health(state, result)}
    else
      {:reply, {:error, :invalid_override_operation}, state}
    end
  end

  defp handle_current_call(
         {:revoke_override_operation_live, credential, epoch, operation_id},
         _from,
         state
       ) do
    if valid_override_operation_input?(epoch, operation_id) do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          revoke_override_operation_tx(
            db,
            hash,
            epoch,
            operation_id,
            state.clock_epoch,
            store_now_ms(state)
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_override_operation}, state}
    end
  end

  defp handle_current_call(
         {:revoke_override_lease, credential, target_id, authority_epoch},
         _from,
         state
       ) do
    if Id.valid?(target_id) and valid_stored_integer?(authority_epoch) and
         authority_epoch >= 1 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          revoke_override_lease_tx(
            db,
            hash,
            target_id,
            authority_epoch,
            state.clock_epoch
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_override_lease}, state}
    end
  end

  defp handle_current_call({:narrow_thing, %Thing{} = thing, expected_revision}, _from, state) do
    with true <-
           is_integer(expected_revision) and expected_revision >= 0 and
             expected_revision < @max_i64,
         {:ok, document} <- Registry.encode_thing(thing) do
      write_reply(state, fn db -> narrow_thing_tx(db, thing, document, expected_revision) end)
    else
      _ -> {:reply, {:error, :invalid_declaration_change}, state}
    end
  end

  defp handle_current_call({:narrow_thing, _, _}, _from, state),
    do: {:reply, {:error, :invalid_declaration_change}, state}

  defp handle_current_call({:revoke_thing, thing_id}, _from, state) do
    if Id.valid?(thing_id),
      do: write_reply(state, fn db -> revoke_thing_tx(db, thing_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  defp handle_current_call(
         {:provision_principal, principal_id, permissions, target_ids},
         _from,
         state
       ) do
    with true <-
           Id.valid?(principal_id) and not WotexHome.NativeSetup.Codec.reserved?(principal_id) and
             valid_target_ids?(target_ids, permissions),
         {:ok, permissions_json} <- Registry.encode_permissions(permissions) do
      credential = :crypto.strong_rand_bytes(32)
      {:ok, hash} = Registry.credential_hash(credential)

      write_reply(state, fn db ->
        provision_principal_tx(db, principal_id, hash, permissions_json, target_ids, credential)
      end)
    else
      _ -> {:reply, {:error, :invalid_provisioning}, state}
    end
  end

  defp handle_current_call(:provision_transfer, _from, state) do
    credential = :crypto.strong_rand_bytes(32)
    {:ok, hash} = Registry.credential_hash(credential)
    write_reply(state, &PrincipalWriter.provision_transfer_tx(&1, hash, credential))
  end

  defp handle_current_call(:native_setup_identity, _from, state) do
    result = NativePrincipalWriter.identity(state.db)
    writable = state.writable and result != {:error, :corrupt_native_setup}
    {:reply, result, %{state | writable: writable}}
  end

  defp handle_current_call({:ensure_native_principal, input}, _from, state),
    do: write_reply(state, &NativePrincipalWriter.ensure_tx(&1, input))

  defp handle_current_call({:existing_native_principal, input}, _from, state) do
    result = NativePrincipalWriter.existing(state.db, input)
    writable = state.writable and result != {:error, :corrupt_native_setup}
    {:reply, result, %{state | writable: writable}}
  end

  defp handle_current_call({:revoke_principal, principal_id}, _from, state) do
    if Id.valid?(principal_id),
      do: write_reply(state, fn db -> revoke_principal_tx(db, principal_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  defp handle_current_call({:revoke_target_grant, principal_id, thing_id}, _from, state) do
    if Id.valid?(principal_id) and Id.valid?(thing_id),
      do: write_reply(state, fn db -> revoke_target_grant_tx(db, principal_id, thing_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  defp handle_current_call({:grant_target_and_rotate, principal_id, thing_id}, _from, state) do
    if WotexHome.NativeSetup.Codec.reserved?(principal_id) do
      {:reply, {:error, :native_custody_required}, state}
    else
      grant_target_and_rotate_reply(principal_id, thing_id, state)
    end
  end

  defp handle_current_call({:rotate_principal_credential, principal_id}, _from, state) do
    if WotexHome.NativeSetup.Codec.reserved?(principal_id) do
      {:reply, {:error, :native_custody_required}, state}
    else
      rotate_principal_reply(principal_id, state)
    end
  end

  defp handle_current_call({:submit_request, credential, %Mutation{} = mutation}, _from, state) do
    with true <- Mutation.valid?(mutation),
         {:ok, hash} <- Registry.credential_hash(credential) do
      write_reply(state, fn db -> submit_request_tx(db, hash, mutation, state.receipt_limit) end)
    else
      _ -> {:reply, {:error, :invalid_request}, state}
    end
  end

  defp handle_current_call({:submit_request, _credential, _mutation}, _from, state),
    do: {:reply, {:error, :invalid_request}, state}

  defp handle_current_call(
         {:cancel_request, credential, authority_epoch, operation_id},
         _from,
         state
       ) do
    if Id.valid?(operation_id) and is_integer(authority_epoch) and authority_epoch >= 0 and
         authority_epoch <= @max_i64 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db -> cancel_request_tx(db, hash, authority_epoch, operation_id) end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_id}, state}
    end
  end

  defp handle_current_call(
         {:request_status, credential, authority_epoch, operation_id},
         _from,
         state
       ) do
    result =
      with {:ok, hash} <- Registry.credential_hash(credential),
           true <-
             Id.valid?(operation_id) and is_integer(authority_epoch) and
               authority_epoch >= 0 and authority_epoch <= @max_i64,
           {:ok, principal_id, _permissions} <- authenticate(state.db, hash) do
        case select_request(state.db, principal_id, authority_epoch, operation_id) do
          {:ok, []} -> :not_found
          {:ok, [row]} -> decode_receipt(principal_id, authority_epoch, operation_id, row)
          {:error, _reason} -> {:error, :store_unavailable}
        end
      else
        false -> {:error, :invalid_id}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:inspect_held_power, credential, authority_epoch, operation_id, boot_epoch, now_ms},
         _from,
         state
       ) do
    result =
      if Id.valid?(operation_id) and Id.valid?(boot_epoch) and
           is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
           is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
        inspect_held_power_result(
          state.db,
          credential,
          authority_epoch,
          operation_id,
          boot_epoch,
          now_ms
        )
      else
        {:error, :invalid_guard_input}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:inspect_held_color, credential, authority_epoch, operation_id, boot_epoch, now_ms},
         _from,
         state
       ) do
    result =
      if Id.valid?(operation_id) and Id.valid?(boot_epoch) and
           is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
           is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
        inspect_held_color_result(
          state.db,
          credential,
          authority_epoch,
          operation_id,
          boot_epoch,
          now_ms
        )
      else
        {:error, :invalid_guard_input}
      end

    {:reply, result, read_health(state, result)}
  end

  defp handle_current_call(
         {:claim_queued_power, principal_id, authority_epoch, operation_id, boot_epoch, now_ms},
         from,
         state
       ) do
    claim_power_reply(
      :legacy,
      principal_id,
      authority_epoch,
      operation_id,
      boot_epoch,
      now_ms,
      from,
      state
    )
  end

  defp handle_current_call(
         {:claim_lifx_power, principal_id, authority_epoch, operation_id, boot_epoch, now_ms},
         from,
         state
       ) do
    claim_power_reply(
      :context,
      principal_id,
      authority_epoch,
      operation_id,
      boot_epoch,
      now_ms,
      from,
      state
    )
  end

  defp handle_current_call(
         {:handoff_claimed_power, principal_id, authority_epoch, operation_id, token, now_ms},
         {caller, _tag},
         state
       ) do
    key = {principal_id, authority_epoch, operation_id}

    cond do
      not valid_handoff_input?(principal_id, authority_epoch, operation_id, token, now_ms) ->
        {:reply, {:error, :invalid_claim_input}, state}

      not claim_owned?(state, caller, token, key) ->
        {:reply, {:error, :claim_not_owned}, state}

      true ->
        case transaction(state.db, fn db ->
               handoff_claimed_power_tx(
                 db,
                 principal_id,
                 authority_epoch,
                 operation_id,
                 token,
                 now_ms,
                 qualification_basis(state),
                 fn -> {state.clock_epoch, store_now_ms(state)} end
               )
             end) do
          {:ok, receipt} ->
            {:reply, {:ok, receipt}, state}

          {:error, {:policy, reason}} ->
            {:reply, {:error, reason}, state}

          {:error, reason}
          when reason in [
                 :corrupt_receipt,
                 :corrupt_enrollment,
                 :corrupt_principal,
                 :corrupt_rule_admission,
                 :corrupt_maintenance,
                 :corrupt_invariant,
                 :corrupt_override,
                 :corrupt_value
               ] ->
            {:reply, {:error, reason}, %{state | writable: false}}

          {:error, _reason} ->
            {:reply, {:error, :store_unavailable}, %{state | writable: false}}
        end
    end
  end

  defp handle_current_call(
         {:accept_power_ack, principal_id, authority_epoch, operation_id, token},
         {caller, _tag},
         state
       ) do
    execution_transition_reply(
      principal_id,
      authority_epoch,
      operation_id,
      token,
      caller,
      state,
      fn db -> accept_power_ack_tx(db, principal_id, authority_epoch, operation_id, token) end
    )
  end

  defp handle_current_call(
         {:settle_power_readback, principal_id, authority_epoch, operation_id, token,
          %Observation{} = observation},
         {caller, _tag},
         state
       ) do
    execution_transition_reply(
      principal_id,
      authority_epoch,
      operation_id,
      token,
      caller,
      state,
      fn db ->
        settle_power_readback_tx(
          db,
          principal_id,
          authority_epoch,
          operation_id,
          token,
          observation,
          {state.clock_epoch, store_now_ms(state)}
        )
      end
    )
  end

  defp handle_current_call({:settle_power_readback, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_power_readback}, state}

  defp handle_current_call(
         {:mark_power_outcome_unknown, principal_id, authority_epoch, operation_id, token,
          reason},
         {caller, _tag},
         state
       ) do
    execution_transition_reply(
      principal_id,
      authority_epoch,
      operation_id,
      token,
      caller,
      state,
      fn db ->
        mark_power_outcome_unknown_tx(
          db,
          principal_id,
          authority_epoch,
          operation_id,
          token,
          reason
        )
      end
    )
  end

  defp handle_current_call(
         {:reconcile_unknown_power, credential, epoch, operation_id, receipt_revision,
          report_revision, boot_epoch, now_ms},
         _from,
         state
       ) do
    if valid_guard_input?(epoch, operation_id, boot_epoch, now_ms) and
         valid_stored_integer?(receipt_revision) and valid_stored_integer?(report_revision) do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        active_owners =
          state.claim_owners
          |> Enum.filter(fn {_monitor, {pid, _token, _key}} -> Process.alive?(pid) end)
          |> Enum.map(fn {_monitor, {_pid, _token, key}} -> key end)
          |> MapSet.new()

        write_reply(state, fn db ->
          reconcile_unknown_power_tx(
            db,
            hash,
            epoch,
            operation_id,
            receipt_revision,
            report_revision,
            boot_epoch,
            now_ms,
            qualification_basis(state),
            active_owners
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_reconciliation_input}, state}
    end
  end

  defp handle_current_call(
         {:reject_abandoned_claim, principal_id, authority_epoch, operation_id},
         _from,
         state
       ) do
    key = {principal_id, authority_epoch, operation_id}

    owner_active? =
      Enum.any?(state.claim_owners, fn {_monitor, {pid, _token, owner_key}} ->
        owner_key == key and Process.alive?(pid)
      end)

    cond do
      not (Id.valid?(principal_id) and Id.valid?(operation_id) and
             is_integer(authority_epoch) and authority_epoch >= 0 and
               authority_epoch <= @max_i64) ->
        {:reply, {:error, :invalid_claim_input}, state}

      true ->
        case transaction(state.db, fn db ->
               reject_abandoned_claim_tx(
                 db,
                 principal_id,
                 authority_epoch,
                 operation_id,
                 owner_active?
               )
             end) do
          {:ok, receipt} ->
            owners =
              Enum.reduce(state.claim_owners, %{}, fn {monitor, {_pid, _token, owner_key} = value},
                                                      acc ->
                if owner_key == key do
                  Process.demonitor(monitor, [:flush])
                  acc
                else
                  Map.put(acc, monitor, value)
                end
              end)

            {:reply, {:ok, receipt}, %{state | claim_owners: owners}}

          {:error, {:policy, reason}} ->
            {:reply, {:error, reason}, state}

          {:error, reason} when reason in [:corrupt_receipt] ->
            {:reply, {:error, reason}, %{state | writable: false}}

          {:error, _reason} ->
            {:reply, {:error, :store_unavailable}, %{state | writable: false}}
        end
    end
  end

  defp handle_current_call(
         {:fence_rule_generation, expected_revision, authority_epoch},
         _from,
         state
       ) do
    if is_integer(expected_revision) and expected_revision >= 0 and expected_revision <= @max_i64 and
         is_integer(authority_epoch) and authority_epoch >= 1 and
         authority_epoch <= @max_i64 do
      write_reply(state, fn db ->
        fence_rule_generation_tx(db, expected_revision, authority_epoch)
      end)
    else
      {:reply, {:error, :invalid_generation_input}, state}
    end
  end

  defp handle_current_call(
         {:admit_held_power, credential, authority_epoch, operation_id, boot_epoch, now_ms},
         _from,
         state
       ) do
    if Id.valid?(operation_id) and Id.valid?(boot_epoch) and
         is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
         is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          admit_held_power_tx(
            db,
            credential,
            hash,
            authority_epoch,
            operation_id,
            boot_epoch,
            now_ms,
            qualification_basis(state),
            fn -> {state.clock_epoch, store_now_ms(state)} end
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_guard_input}, state}
    end
  end

  defp handle_current_call(
         {:settle_held_power_noop, credential, authority_epoch, operation_id, boot_epoch, now_ms},
         _from,
         state
       ) do
    if Id.valid?(operation_id) and Id.valid?(boot_epoch) and
         is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
         is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          settle_held_power_noop_tx(
            db,
            credential,
            hash,
            authority_epoch,
            operation_id,
            boot_epoch,
            now_ms,
            fn -> {state.clock_epoch, store_now_ms(state)} end
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_guard_input}, state}
    end
  end

  defp handle_current_call(
         {:settle_held_color_noop, credential, authority_epoch, operation_id, boot_epoch, now_ms},
         _from,
         state
       ) do
    if Id.valid?(operation_id) and Id.valid?(boot_epoch) and
         is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
         is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          settle_held_color_noop_tx(
            db,
            credential,
            hash,
            authority_epoch,
            operation_id,
            boot_epoch,
            now_ms
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_guard_input}, state}
    end
  end

  defp qualification_basis(state),
    do:
      Map.take(state, [
        :qualification_claim_root,
        :qualification_case_keys,
        :qualification_decision_keys
      ])

  defp store_now_ms(state),
    do: max(0, System.monotonic_time(:millisecond) - state.clock_origin)

  defp valid_override_operation_input?(epoch, operation_id),
    do: valid_stored_integer?(epoch) and epoch >= 1 and Id.valid?(operation_id)

  defp claim_power_reply(
         mode,
         principal_id,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms,
         {caller, _tag},
         state
       ) do
    if valid_claim_input?(principal_id, authority_epoch, operation_id, boot_epoch, now_ms) do
      token = :crypto.strong_rand_bytes(32)

      case transaction(state.db, fn db ->
             claim_queued_power_tx(
               db,
               principal_id,
               authority_epoch,
               operation_id,
               boot_epoch,
               now_ms,
               token,
               qualification_basis(state),
               fn -> {state.clock_epoch, store_now_ms(state)} end
             )
           end) do
        {:ok, {receipt, claim}} ->
          monitor = Process.monitor(caller)
          key = {principal_id, authority_epoch, operation_id}
          owners = Map.put(state.claim_owners, monitor, {caller, token, key})

          reply =
            case mode do
              :legacy -> {:ok, receipt, token}
              :context -> {:ok, claim}
            end

          {:reply, reply, %{state | claim_owners: owners}}

        {:error, {:policy, reason}} ->
          {:reply, {:error, reason}, state}

        {:error, reason}
        when reason in [
               :corrupt_receipt,
               :corrupt_enrollment,
               :corrupt_principal,
               :corrupt_rule_admission,
               :corrupt_maintenance,
               :corrupt_invariant,
               :corrupt_override
             ] ->
          {:reply, {:error, reason}, %{state | writable: false}}

        {:error, _reason} ->
          {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:reply, {:error, :invalid_claim_input}, state}
    end
  end

  defp valid_claim_input?(principal_id, authority_epoch, operation_id, boot_epoch, now_ms) do
    Id.valid?(principal_id) and
      valid_guard_input?(authority_epoch, operation_id, boot_epoch, now_ms)
  end

  defp valid_guard_input?(authority_epoch, operation_id, boot_epoch, now_ms) do
    Id.valid?(operation_id) and Id.valid?(boot_epoch) and
      is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
      is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64
  end

  defp execution_transition_reply(
         principal_id,
         authority_epoch,
         operation_id,
         token,
         caller,
         state,
         transaction_fun
       ) do
    key = {principal_id, authority_epoch, operation_id}

    cond do
      not valid_execution_input?(principal_id, authority_epoch, operation_id, token) ->
        {:reply, {:error, :invalid_claim_input}, state}

      not claim_owned?(state, caller, token, key) ->
        {:reply, {:error, :claim_not_owned}, state}

      true ->
        case transaction(state.db, transaction_fun) do
          {:ok, receipt} ->
            {:reply, {:ok, receipt}, prune_claim_owners(state)}

          {:error, {:policy, reason}} ->
            {:reply, {:error, reason}, state}

          {:error, reason}
          when reason in [
                 :corrupt_receipt,
                 :corrupt_enrollment,
                 :corrupt_principal,
                 :corrupt_rule_admission,
                 :corrupt_maintenance,
                 :corrupt_invariant,
                 :corrupt_override,
                 :corrupt_value
               ] ->
            {:reply, {:error, reason}, %{state | writable: false}}

          {:error, _reason} ->
            {:reply, {:error, :store_unavailable}, %{state | writable: false}}
        end
    end
  end

  defp valid_execution_input?(principal_id, authority_epoch, operation_id, token) do
    Id.valid?(principal_id) and Id.valid?(operation_id) and is_binary(token) and
      byte_size(token) == 32 and is_integer(authority_epoch) and authority_epoch >= 0 and
      authority_epoch <= @max_i64
  end

  defp valid_handoff_input?(principal_id, authority_epoch, operation_id, token, now_ms) do
    Id.valid?(principal_id) and Id.valid?(operation_id) and is_binary(token) and
      byte_size(token) == 32 and is_integer(authority_epoch) and authority_epoch >= 0 and
      authority_epoch <= @max_i64 and is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64
  end

  defp claim_owned?(state, caller, token, key) do
    Enum.any?(state.claim_owners, fn {_monitor, owner} ->
      owner == {caller, token, key}
    end)
  end

  defp read_health(state, {:error, :store_unavailable}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_value}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_receipt}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_enrollment}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_principal}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_override}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_rule_review}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_invariant}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_maintenance}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_controller_history}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_rule_admission}), do: %{state | writable: false}

  defp read_health(state, {:error, :corrupt_qualification_history}),
    do: %{state | writable: false}

  defp read_health(state, {:error, :corrupt_profile_ledger}), do: %{state | writable: false}
  defp read_health(state, _result), do: state

  defp grant_target_and_rotate_reply(principal_id, thing_id, state) do
    if Id.valid?(principal_id) and Id.valid?(thing_id) do
      credential = :crypto.strong_rand_bytes(32)
      {:ok, hash} = Registry.credential_hash(credential)

      write_reply(state, fn db ->
        grant_target_and_rotate_tx(db, principal_id, thing_id, hash, credential)
      end)
    else
      {:reply, {:error, :invalid_id}, state}
    end
  end

  defp rotate_principal_reply(principal_id, state) do
    if Id.valid?(principal_id) do
      credential = :crypto.strong_rand_bytes(32)
      {:ok, hash} = Registry.credential_hash(credential)

      write_reply(state, fn db ->
        rotate_principal_credential_tx(db, principal_id, hash, credential)
      end)
    else
      {:reply, {:error, :invalid_id}, state}
    end
  end

  defp write_reply(state, fun, commit_guard \\ fn -> :ok end) do
    case transaction(state.db, fun, commit_guard) do
      {:ok, result} ->
        {:reply, result, prune_claim_owners(state)}

      {:error, {:policy, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, reason} when reason in @profile_guard_denials ->
        {:reply, {:error, reason}, state}

      {:error, :corrupt_enrollment} ->
        {:reply, {:error, :corrupt_enrollment}, %{state | writable: false}}

      {:error, :corrupt_principal} ->
        {:reply, {:error, :corrupt_principal}, %{state | writable: false}}

      {:error, :corrupt_native_setup} ->
        {:reply, {:error, :corrupt_native_setup}, %{state | writable: false}}

      {:error, :corrupt_native_target_history} ->
        {:reply, {:error, :corrupt_native_target_history}, %{state | writable: false}}

      {:error, :corrupt_receipt} ->
        {:reply, {:error, :corrupt_receipt}, %{state | writable: false}}

      {:error, :corrupt_rule_review} ->
        {:reply, {:error, :corrupt_rule_review}, %{state | writable: false}}

      {:error, :corrupt_invariant} ->
        {:reply, {:error, :corrupt_invariant}, %{state | writable: false}}

      {:error, :corrupt_maintenance} ->
        {:reply, {:error, :corrupt_maintenance}, %{state | writable: false}}

      {:error, :corrupt_controller_history} ->
        {:reply, {:error, :corrupt_controller_history}, %{state | writable: false}}

      {:error, :corrupt_rule_admission} ->
        {:reply, {:error, :corrupt_rule_admission}, %{state | writable: false}}

      {:error, :corrupt_profile_ledger} ->
        {:reply, {:error, :corrupt_profile_ledger}, %{state | writable: false}}

      {:error, :corrupt_qualification_history} ->
        {:reply, {:error, :corrupt_qualification_history}, %{state | writable: false}}

      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, %{state | writable: false}}
    end
  end

  # Runtime unavailability is a policy denial after rollback, not damage to
  # SQLite. Every Store transaction uses this same classification, including
  # observation batches and claimant-owned execution transitions.
  defp transaction(db, fun, commit_guard \\ fn -> :ok end) do
    guarded = fn borrowed ->
      with :ok <- NativeTargetHistory.validate_if_current(borrowed) do
        case fun.(borrowed) do
          {:commit, _} = commit ->
            case NativeTargetHistory.validate_if_current(borrowed) do
              :ok ->
                case NativeTargetWriter.check_guard(commit_guard) do
                  :ok -> commit
                  {:error, reason} -> {:rollback, {:policy, reason}}
                end

              {:error, reason} ->
                {:rollback, reason}
            end

          other ->
            other
        end
      else
        {:error, reason} -> {:rollback, reason}
      end
    end

    case WotexHome.Durable.Store.SQL.transaction(db, guarded) do
      {:error, {:policy, reason}}
      when reason in [:corrupt_profile_ledger, :corrupt_qualification_history] ->
        {:error, reason}

      {:error, reason} when reason in @profile_guard_denials ->
        {:error, {:policy, reason}}

      result ->
        result
    end
  end

  defp prepare_profile_change(state, credential, document) do
    case ProfileWriter.prepare(state.db, credential, document) do
      {:ok, :existing, receipt} -> {:ok, {:existing, receipt}}
      {:ok, :new, _principal, input} -> {:ok, {:new, input["action"], input["artifact_digest"]}}
      error -> error
    end
  end

  defp commit_profile_selection(%{profile_reviews: nil} = state, _, _),
    do: {:reply, {:error, :profile_selection_unavailable}, state}

  defp commit_profile_selection(state, credential, document) do
    with {:ok, :new, basis} <- ProfileWriter.selection_basis(state.db, credential, document),
         {:ok, token, held} <- checkout_profile_review(state.profile_reviews, basis, document) do
      try do
        result =
          with true <- Review.valid?(held.review),
               true <- held.review.basis == basis,
               {:ok, artifact} <-
                 read_profile_artifact(state.profile_custody, basis["artifact_digest"]),
               true <- artifact == held.review.artifact,
               {:ok, runtime} <- ProfileBasis.runtime_digest(),
               true <- runtime == held.review.runtime_digest do
            {:ok, runtime}
          else
            false -> {:error, :profile_review_mismatch}
            error -> error
          end

        case result do
          {:ok, runtime} ->
            write_reply(
              state,
              &ProfileTransition.select(
                &1,
                credential,
                document,
                held.review,
                held.deadline,
                runtime
              )
            )

          error ->
            {:reply, error, read_health(state, error)}
        end
      after
        finish_profile_review(state.profile_reviews, token)
      end
    else
      error -> {:reply, error, read_health(state, error)}
    end
  end

  defp checkout_profile_review(owner, basis, document) do
    principal = basis["principal_id"]

    with {:ok, %{review_token: token}} <- ReviewSession.pending(owner, principal, document),
         {:ok, held} <- ReviewSession.checkout(owner, principal, token, document) do
      {:ok, token, held}
    else
      :not_found -> {:error, :profile_review_missing}
      error -> error
    end
  catch
    :exit, _ -> {:error, :profile_review_unavailable}
  end

  defp read_profile_artifact(nil, _), do: {:error, :profile_custody_unavailable}

  defp read_profile_artifact(owner, digest) do
    Custody.read(owner, digest)
  catch
    :exit, _ -> {:error, :profile_custody_unavailable}
  end

  defp finish_profile_review(owner, token) do
    ReviewSession.finish(owner, token)
  catch
    :exit, _ -> :ok
  end

  defp collect_profile_custody(nil, _), do: {:error, :profile_custody_unavailable}

  defp collect_profile_custody(custody, retained) do
    Custody.collect(custody, retained)
  catch
    :exit, _ -> {:error, :profile_custody_unavailable}
  end

  defp profile_lease(nil, _), do: {:error, :profile_custody_unavailable}

  defp profile_lease(custody, digest) do
    Custody.lease(custody, digest)
  catch
    :exit, _ -> {:error, :profile_custody_unavailable}
  end

  defp profile_release(custody, token) do
    Custody.release(custody, token)
  catch
    :exit, _ -> :ok
  end

  defp prune_claim_owners(%{claim_owners: owners} = state) when map_size(owners) == 0,
    do: state

  defp prune_claim_owners(state) do
    case query(
           state.db,
           "SELECT principal_id, authority_epoch, operation_id FROM request_execution WHERE state IN ('claimed', 'dispatching', 'protocol_accepted', 'outcome_unknown')"
         ) do
      {:ok, rows} ->
        in_flight = MapSet.new(Enum.map(rows, &List.to_tuple/1))

        owners =
          Enum.reduce(state.claim_owners, %{}, fn {monitor, {_pid, _token, key} = value}, acc ->
            if MapSet.member?(in_flight, key) do
              Map.put(acc, monitor, value)
            else
              Process.demonitor(monitor, [:flush])
              acc
            end
          end)

        %{state | claim_owners: owners}

      {:error, _reason} ->
        %{state | writable: false}
    end
  end

  defp valid_target_ids?(ids, permissions) do
    is_list(ids) and is_list(permissions) and length(ids) <= 32 and
      ("host:transfer" not in permissions or ids == []) and
      (ids != [] or
         Enum.all?(
           permissions,
           &(&1 in ["read", "enroll:review", "host:maintain", "profile:manage", "host:transfer"])
         )) and
      Enum.all?(ids, &Id.valid?/1) and length(Enum.uniq(ids)) == length(ids)
  end

  defp valid_pair?(observation, capability) do
    Observation.valid?(observation, capability)
  end

  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64

  defp configure(db) do
    with {:ok, [["wal"]]} <- query(db, "PRAGMA journal_mode=WAL"),
         {:ok, []} <- query(db, "PRAGMA synchronous=FULL"),
         {:ok, [[2]]} <- query(db, "PRAGMA synchronous"),
         {:ok, []} <- query(db, "PRAGMA foreign_keys=ON"),
         {:ok, [[1]]} <- query(db, "PRAGMA foreign_keys"),
         {:ok, [[5000]]} <- query(db, "PRAGMA busy_timeout=5000") do
      :ok
    else
      other -> {:error, {:durability_pragma_failed, other}}
    end
  end

  defp initialize_schema(db), do: Schema.initialize(db, &Integrity.validate_schema_version/2)

  @doc false
  @spec validate_snapshot(Exqlite.Sqlite3.db()) :: :ok | {:error, term()}
  def validate_snapshot(db), do: Integrity.validate_snapshot(db)
end
