defmodule WotexHome.Durable.Store do
  @moduledoc """
  Single-process SQLite writer for observations, enrollment and held receipts.

  Held requests, queued direct Light power and pre-handoff worker claims share
  one writer. Claims carry no send authority. The host must provide an owned
  database path and supervise this process. Qualified transport handoff and
  readback guards are required before a mutating driver can be connected.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias WotexHome.{Id, Mutation, Policy}
  alias WotexHome.Discovery.EnrollmentReview
  alias WotexHome.Durable.{Backup, HostLock, Receipt, Registry}
  alias WotexHome.Lifx.{ColorPlan, ProductRegistry, ProfileBasis}
  alias WotexHome.Policy.Context
  alias WotexHome.Qualification.{Claims, Decision}
  alias WotexHome.Rules.OverrideLease
  alias WotexHome.Semantics.{Capability, Observation, Thing, Value}

  @schema """
  CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value INTEGER NOT NULL
  );
  INSERT OR IGNORE INTO meta(key, value) VALUES ('revision', 0);
  CREATE TABLE IF NOT EXISTS observation_current (
    thing_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    profile_ref TEXT NOT NULL,
    evidence_ref TEXT NOT NULL,
    source_epoch TEXT NOT NULL,
    source_sequence INTEGER NOT NULL,
    boot_epoch TEXT NOT NULL,
    source_time_utc_ms INTEGER,
    received_time_utc_ms INTEGER NOT NULL,
    received_monotonic_ms INTEGER NOT NULL,
    quality TEXT NOT NULL,
    trust TEXT NOT NULL,
    value_kind TEXT,
    value_a TEXT,
    value_b TEXT,
    revision INTEGER NOT NULL,
    PRIMARY KEY (thing_id, capability_key)
  );
  CREATE TABLE IF NOT EXISTS journal (
    revision INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,
    thing_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    profile_ref TEXT NOT NULL,
    evidence_ref TEXT NOT NULL,
    source_epoch TEXT NOT NULL,
    source_sequence INTEGER NOT NULL,
    boot_epoch TEXT NOT NULL,
    source_time_utc_ms INTEGER,
    received_time_utc_ms INTEGER NOT NULL,
    received_monotonic_ms INTEGER NOT NULL,
    quality TEXT NOT NULL,
    trust TEXT NOT NULL,
    value_kind TEXT,
    value_a TEXT,
    value_b TEXT
  );
  """

  @request_schema """
  INSERT OR IGNORE INTO meta(key, value) VALUES ('authority_epoch', 1);
  CREATE TABLE IF NOT EXISTS request_receipts (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL,
    target_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    value_kind TEXT NOT NULL,
    value_a TEXT NOT NULL,
    value_b TEXT,
    profile_ref TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN ('held', 'rejected')),
    reason TEXT,
    revision INTEGER NOT NULL,
    PRIMARY KEY (principal_id, authority_epoch, operation_id)
  );
  CREATE TABLE IF NOT EXISTS request_outbox (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state = 'held'),
    revision INTEGER NOT NULL,
    PRIMARY KEY (principal_id, authority_epoch, operation_id),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES request_receipts(principal_id, authority_epoch, operation_id)
  );
  CREATE TABLE IF NOT EXISTS request_journal (
    revision INTEGER PRIMARY KEY,
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    disposition TEXT NOT NULL,
    reason TEXT
  );
  """

  @authority_schema """
  CREATE TABLE IF NOT EXISTS enrolled_things (
    thing_id TEXT PRIMARY KEY,
    profile_ref TEXT NOT NULL,
    document TEXT NOT NULL,
    resource_revision INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'revoked'))
  );
  CREATE TABLE IF NOT EXISTS principals (
    principal_id TEXT PRIMARY KEY,
    credential_hash BLOB NOT NULL UNIQUE,
    permissions TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'revoked'))
  );
  CREATE TABLE IF NOT EXISTS principal_targets (
    principal_id TEXT NOT NULL,
    thing_id TEXT NOT NULL,
    PRIMARY KEY (principal_id, thing_id),
    FOREIGN KEY (principal_id) REFERENCES principals(principal_id),
    FOREIGN KEY (thing_id) REFERENCES enrolled_things(thing_id)
  );
  CREATE TABLE IF NOT EXISTS authority_journal (
    revision INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,
    entity_id TEXT NOT NULL
  );
  """

  @source_epoch_schema """
  CREATE TABLE IF NOT EXISTS source_epoch_grants (
    thing_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    old_epoch TEXT NOT NULL,
    new_epoch TEXT NOT NULL,
    current_revision INTEGER NOT NULL,
    grant_revision INTEGER NOT NULL,
    PRIMARY KEY (thing_id, capability_key),
    FOREIGN KEY (thing_id, capability_key)
      REFERENCES observation_current(thing_id, capability_key)
  );
  """

  @receipt_v5_schema """
  CREATE TABLE request_receipts_v5 (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL,
    target_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    value_kind TEXT NOT NULL,
    value_a TEXT NOT NULL,
    value_b TEXT,
    profile_ref TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN
      ('held', 'rejected', 'queued', 'claimed', 'dispatching', 'protocol_accepted',
       'observed', 'contradicted', 'failed', 'outcome_unknown')),
    reason TEXT,
    revision INTEGER NOT NULL,
    PRIMARY KEY (principal_id, authority_epoch, operation_id)
  );
  INSERT INTO request_receipts_v5 SELECT * FROM request_receipts;
  DROP TABLE request_receipts;
  ALTER TABLE request_receipts_v5 RENAME TO request_receipts;
  """

  @execution_schema """
  CREATE TABLE IF NOT EXISTS request_execution (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    effect_domain TEXT NOT NULL,
    profile_ref TEXT NOT NULL,
    profile_evidence_ref TEXT NOT NULL CHECK (length(profile_evidence_ref) > 0),
    resource_revision INTEGER NOT NULL CHECK (resource_revision >= 0),
    rule_generation INTEGER NOT NULL CHECK (rule_generation >= 0),
    baseline_revision INTEGER NOT NULL CHECK (baseline_revision >= 0),
    admission_revision INTEGER NOT NULL CHECK (admission_revision >= 1),
    planned_value BLOB NOT NULL CHECK (length(planned_value) BETWEEN 1 AND 512),
    state TEXT NOT NULL CHECK (state IN
      ('queued', 'claimed', 'dispatching', 'protocol_accepted', 'observed',
       'contradicted', 'failed', 'outcome_unknown')),
    claim_token BLOB,
    claim_boot_epoch TEXT,
    handoff_revision INTEGER,
    attempts INTEGER NOT NULL CHECK (attempts >= 0),
    revision INTEGER NOT NULL,
    PRIMARY KEY (principal_id, authority_epoch, operation_id),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES request_receipts(principal_id, authority_epoch, operation_id),
    CHECK (admission_revision <= revision)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS one_active_effect_claim
    ON request_execution(effect_domain)
    WHERE state IN ('claimed', 'dispatching', 'protocol_accepted');
  """

  @enrollment_binding_schema """
  CREATE TABLE enrollment_bindings (
    thing_id TEXT PRIMARY KEY REFERENCES enrolled_things(thing_id),
    stable_id TEXT NOT NULL UNIQUE,
    identity_digest TEXT NOT NULL UNIQUE CHECK (length(identity_digest) = 64),
    candidate_ref TEXT NOT NULL,
    review_ref TEXT NOT NULL UNIQUE,
    method TEXT NOT NULL CHECK (method IN
      ('legacy_tofu', 'operator_configured', 'physical_button', 'qr_install_code')),
    qualification_ref TEXT NOT NULL,
    operator_id TEXT NOT NULL REFERENCES principals(principal_id),
    profile_ref TEXT NOT NULL,
    revision INTEGER NOT NULL
  );
  """

  @enrollment_review_v7_schema """
  ALTER TABLE enrollment_bindings
    ADD COLUMN digest_version INTEGER NOT NULL DEFAULT 1
    CHECK (digest_version IN (1, 2));
  CREATE TABLE enrollment_review_history (
    revision INTEGER PRIMARY KEY,
    thing_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    stable_id TEXT NOT NULL,
    identity_digest TEXT NOT NULL CHECK (length(identity_digest) = 64),
    digest_version INTEGER NOT NULL CHECK (digest_version IN (1, 2)),
    candidate_ref TEXT NOT NULL,
    review_ref TEXT NOT NULL UNIQUE,
    method TEXT NOT NULL,
    qualification_ref TEXT NOT NULL,
    operator_id TEXT NOT NULL REFERENCES principals(principal_id),
    profile_ref TEXT NOT NULL,
    manufacturer TEXT,
    model TEXT,
    firmware TEXT
  );
  INSERT INTO enrollment_review_history
    SELECT revision, thing_id, stable_id, identity_digest, 1, candidate_ref,
           review_ref, method, qualification_ref, operator_id, profile_ref,
           NULL, NULL, NULL FROM enrollment_bindings;
  """

  @qualification_v8_schema """
  CREATE TABLE profile_qualifications (
    thing_id TEXT PRIMARY KEY REFERENCES enrollment_bindings(thing_id),
    profile_ref TEXT NOT NULL,
    resource_revision INTEGER NOT NULL CHECK (resource_revision >= 0),
    identity_digest TEXT NOT NULL CHECK (length(identity_digest) = 64),
    basis_digest TEXT NOT NULL CHECK (length(basis_digest) = 64),
    registry_digest TEXT NOT NULL CHECK (length(registry_digest) = 64),
    runtime_digest TEXT NOT NULL CHECK (length(runtime_digest) = 64),
    evidence_ref TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('qualified', 'revoked')),
    revision INTEGER NOT NULL
  );
  """

  @rule_generation_v9_schema """
  INSERT OR IGNORE INTO meta(key, value) VALUES ('rule_generation', 0);
  """

  @override_v10_schema """
  CREATE TABLE operator_override_leases (
    target_id TEXT PRIMARY KEY REFERENCES enrolled_things(thing_id),
    operator_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    boot_epoch TEXT NOT NULL,
    start_ms INTEGER NOT NULL CHECK (start_ms >= 0),
    expires_ms INTEGER NOT NULL CHECK (expires_ms > start_ms),
    basis_revision INTEGER NOT NULL CHECK (basis_revision >= 0),
    revision INTEGER NOT NULL CHECK (revision >= 1)
  );
  """

  @select_current """
  SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch,
         source_time_utc_ms, received_time_utc_ms, received_monotonic_ms,
         quality, trust, value_kind, value_a, value_b, revision
  FROM observation_current WHERE thing_id = ? AND capability_key = ?
  """
  @max_i64 9_223_372_036_854_775_807
  @max_receipts 65_536
  @execution_dispositions %{
    "queued" => :queued,
    "claimed" => :claimed,
    "dispatching" => :dispatching,
    "protocol_accepted" => :protocol_accepted,
    "observed" => :observed,
    "contradicted" => :contradicted,
    "failed" => :failed,
    "outcome_unknown" => :outcome_unknown
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    receipt_limit = Keyword.get(opts, :receipt_limit, @max_receipts)
    case_keys = Keyword.get(opts, :qualification_case_keys, %{})
    decision_keys = Keyword.get(opts, :qualification_decision_keys, %{})

    GenServer.start_link(
      __MODULE__,
      {path, receipt_limit, case_keys, decision_keys},
      Keyword.take(opts, [:name])
    )
  end

  @spec record(GenServer.server(), Observation.t(), Capability.t()) ::
          {:ok, non_neg_integer()} | {:duplicate, non_neg_integer()} | {:error, atom()}
  def record(server, observation, capability),
    do: GenServer.call(server, {:record, observation, capability})

  @doc "Atomically record one device reply's declared capability observations."
  @spec record_batch(GenServer.server(), Thing.t(), [Observation.t()]) ::
          {:ok, [non_neg_integer()]}
          | {:duplicate, [non_neg_integer()]}
          | {:error, atom()}
  def record_batch(server, thing, observations),
    do: GenServer.call(server, {:record_batch, thing, observations})

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

  @doc "Trusted local encrypted backup export; key custody and restore authorization stay outside Store."
  @spec export_backup(GenServer.server(), String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def export_backup(server, destination, key),
    do: GenServer.call(server, {:export_backup, destination, key}, 120_000)

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
          {:ok, %{now_ms: non_neg_integer(), leases: [OverrideLease.t()]}} | {:error, atom()}
  def override_snapshot_live(server, credential, target_ids),
    do: GenServer.call(server, {:override_snapshot_live, credential, target_ids})

  @doc "Revoke the caller's current override; historical issue/revocation events remain."
  @spec revoke_override_lease(GenServer.server(), binary(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_override_lease(server, credential, target_id, authority_epoch),
    do: GenServer.call(server, {:revoke_override_lease, credential, target_id, authority_epoch})

  @impl true
  def init({path, receipt_limit, case_keys, decision_keys})
      when is_binary(path) and path != "" and path != ":memory:" and
             is_integer(receipt_limit) and receipt_limit >= 1 and
             receipt_limit <= @max_receipts do
    if valid_qualification_keys?(case_keys) and valid_qualification_keys?(decision_keys) do
      open_store(path, receipt_limit, case_keys, decision_keys)
    else
      {:stop, :invalid_store_options}
    end
  end

  def init({path, _receipt_limit, _case_keys, _decision_keys})
      when not is_binary(path) or path == "" or path == ":memory:",
      do: {:stop, :invalid_store_path}

  def init(_options), do: {:stop, :invalid_store_options}

  defp open_store(path, receipt_limit, case_keys, decision_keys) do
    case HostLock.acquire(path) do
      {:ok, lock} ->
        case Sqlite3.open(path) do
          {:ok, db} ->
            case with :ok <- File.chmod(path, 0o600), do: boot(db) do
              :ok ->
                {:ok,
                 %{
                   db: db,
                   lock: lock,
                   writable: true,
                   receipt_limit: receipt_limit,
                   qualification_case_keys: case_keys,
                   qualification_decision_keys: decision_keys,
                   qualification_claim_root:
                     Path.join(Path.dirname(path), "qualification_claims"),
                   override_boot_epoch:
                     "boot:" <>
                       (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)),
                   override_clock_origin: System.monotonic_time(:millisecond),
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

  defp boot(db) do
    with :ok <- ensure_not_quarantined(db),
         :ok <- configure(db),
         :ok <- initialize_schema(db),
         :ok <- integrity(db),
         :ok <- recover_handed_off(db) do
      :ok
    end
  end

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

  @impl true
  def terminate(_reason, %{db: db, lock: lock}) do
    _ = Sqlite3.close(db)
    HostLock.release(lock)
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | claim_owners: Map.delete(state.claim_owners, monitor)}}
  end

  @impl true
  def handle_call({:record, _observation, _capability}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:record_batch, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:authorize_source_epoch, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call(
        {:record, %Observation{} = observation, %Capability{} = capability},
        _from,
        state
      ) do
    if valid_pair?(observation, capability) do
      case transaction(state.db, fn db -> record_tx(db, observation, capability) end) do
        {:ok, result} -> {:reply, result, state}
        {:error, {:policy, reason}} -> {:reply, {:error, reason}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  def handle_call({:record, _observation, _capability}, _from, state),
    do: {:reply, {:error, :invalid_observation}, state}

  def handle_call({:record_batch, %Thing{} = thing, observations}, _from, state) do
    with {:ok, pairs} <- valid_record_batch(thing, observations) do
      case transaction(state.db, fn db -> record_batch_tx(db, pairs) end) do
        {:ok, result} -> {:reply, result, state}
        {:error, {:policy, reason}} -> {:reply, {:error, reason}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_batch, _thing, _observations}, _from, state),
    do: {:reply, {:error, :invalid_observation_batch}, state}

  def handle_call(
        {:authorize_source_epoch, thing_id, capability_key, old_epoch, new_epoch,
         current_revision},
        _from,
        state
      ) do
    if Enum.all?([thing_id, capability_key, old_epoch, new_epoch], &Id.valid?/1) and
         old_epoch != new_epoch and is_integer(current_revision) and current_revision >= 0 and
         current_revision <= @max_i64 do
      write_reply(state, fn db ->
        authorize_source_epoch_tx(
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

  def handle_call({:current, thing_id, capability_key}, _from, state) do
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

  def handle_call(:revision, _from, state) do
    result =
      case query(state.db, "SELECT value FROM meta WHERE key = 'revision'") do
        {:ok, [[revision]]} -> {:ok, revision}
        _ -> {:error, :store_unavailable}
      end

    {:reply, result, read_health(state, result)}
  end

  def handle_call(:health, _from, state) do
    result = health_result(state)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:authorized_health, credential}, _from, state) do
    result =
      with {:ok, hash} <- Registry.credential_hash(credential),
           {:ok, _principal_id, permissions} <- authenticate(state.db, hash),
           true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])) do
        health_result(state)
      else
        false -> {:error, :permission_denied}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, read_health(state, result)}
  end

  def handle_call({:review_inputs, credential}, _from, state) do
    result = review_inputs_result(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:review_current, credential, watermark}, _from, state) do
    result = review_current_result(state.db, credential, watermark)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:snapshot_page, credential, watermark, after_key, page_size}, _from, state) do
    result = snapshot_page_result(state.db, credential, watermark, after_key, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:catalogue_page, credential, watermark, after_id, page_size}, _from, state) do
    result = catalogue_page_result(state.db, credential, watermark, after_id, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call(
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

  def handle_call({:events_page, credential, after_revision, page_size}, _from, state) do
    result = events_page_result(state.db, credential, after_revision, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:request_events_page, credential, after_revision, page_size}, _from, state) do
    result = request_events_page_result(state.db, credential, after_revision, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:export_backup, destination, key}, _from, state) do
    {:reply, Backup.export(state.db, destination, key), state}
  end

  def handle_call({:enroll_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:commit_enrollment, _, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:rereview_enrollment, _, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:narrow_thing, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:submit_request, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:cancel_request, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:settle_held_power_noop, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:settle_held_color_noop, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:admit_held_power, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:claim_queued_power, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:reject_abandoned_claim, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:fence_rule_generation, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:qualify_lifx_power, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:issue_override_lease, _, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:issue_override_lease_live, _, _, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_override_lease, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:active_override_leases, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:active_override_leases_live, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:override_snapshot_live, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({operation, _, _, _}, _from, %{writable: false} = state)
      when operation in [:provision_principal],
      do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_principal, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_target_grant, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:rotate_principal_credential, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:enroll_thing, %Thing{} = thing}, _from, state) do
    case Registry.encode_thing(thing) do
      {:ok, document} -> write_reply(state, fn db -> enroll_thing_tx(db, thing, document) end)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enroll_thing, _thing}, _from, state),
    do: {:reply, {:error, :invalid_thing}, state}

  def handle_call(
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

  def handle_call({:commit_enrollment, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_enrollment_review}, state}

  def handle_call(
        {:rereview_enrollment, credential, candidates, interview, profiles, %Thing{} = thing,
         selection},
        _from,
        state
      ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, review} <-
           EnrollmentReview.new(candidates, interview, profiles, thing, selection),
         {:ok, _document} <- Registry.encode_thing(thing) do
      write_reply(state, fn db -> rereview_enrollment_tx(db, hash, review, interview, thing) end)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rereview_enrollment, _, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_enrollment_review}, state}

  def handle_call(
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
        qualify_lifx_power_tx(db, hash, verified, basis, state.qualification_claim_root)
      end)
    else
      false -> {:reply, {:error, :qualification_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:issue_override_lease_live, credential, target_id, authority_epoch, basis_revision,
         duration_ms},
        from,
        state
      ) do
    handle_call(
      {:issue_override_lease, credential, target_id, authority_epoch, basis_revision,
       override_now_ms(state), duration_ms},
      from,
      state
    )
  end

  def handle_call(
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
            state.override_boot_epoch
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_override_lease}, state}
    end
  end

  def handle_call({:active_override_leases, credential, target_ids, now_ms}, _from, state) do
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
            state.override_boot_epoch
          )
        end

      {:reply, result, read_health(state, result)}
    else
      {:reply, {:error, :invalid_override_query}, state}
    end
  end

  def handle_call({:active_override_leases_live, credential, target_ids}, from, state) do
    handle_call(
      {:active_override_leases, credential, target_ids, override_now_ms(state)},
      from,
      state
    )
  end

  def handle_call({:override_snapshot_live, credential, target_ids}, from, state) do
    now_ms = override_now_ms(state)

    case handle_call({:active_override_leases, credential, target_ids, now_ms}, from, state) do
      {:reply, {:ok, leases}, next_state} ->
        {:reply, {:ok, %{now_ms: now_ms, leases: leases}}, next_state}

      other ->
        other
    end
  end

  def handle_call({:revoke_override_lease, credential, target_id, authority_epoch}, _from, state) do
    if Id.valid?(target_id) and valid_stored_integer?(authority_epoch) and
         authority_epoch >= 1 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db ->
          revoke_override_lease_tx(
            db,
            hash,
            target_id,
            authority_epoch,
            state.override_boot_epoch
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_override_lease}, state}
    end
  end

  def handle_call({:narrow_thing, %Thing{} = thing, expected_revision}, _from, state) do
    with true <-
           is_integer(expected_revision) and expected_revision >= 0 and
             expected_revision < @max_i64,
         {:ok, document} <- Registry.encode_thing(thing) do
      write_reply(state, fn db -> narrow_thing_tx(db, thing, document, expected_revision) end)
    else
      _ -> {:reply, {:error, :invalid_declaration_change}, state}
    end
  end

  def handle_call({:narrow_thing, _, _}, _from, state),
    do: {:reply, {:error, :invalid_declaration_change}, state}

  def handle_call({:revoke_thing, thing_id}, _from, state) do
    if Id.valid?(thing_id),
      do: write_reply(state, fn db -> revoke_thing_tx(db, thing_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:provision_principal, principal_id, permissions, target_ids}, _from, state) do
    with true <- Id.valid?(principal_id) and valid_target_ids?(target_ids, permissions),
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

  def handle_call({:revoke_principal, principal_id}, _from, state) do
    if Id.valid?(principal_id),
      do: write_reply(state, fn db -> revoke_principal_tx(db, principal_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:revoke_target_grant, principal_id, thing_id}, _from, state) do
    if Id.valid?(principal_id) and Id.valid?(thing_id),
      do: write_reply(state, fn db -> revoke_target_grant_tx(db, principal_id, thing_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:rotate_principal_credential, principal_id}, _from, state) do
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

  def handle_call({:submit_request, credential, %Mutation{} = mutation}, _from, state) do
    with true <- Mutation.valid?(mutation),
         {:ok, hash} <- Registry.credential_hash(credential) do
      write_reply(state, fn db -> submit_request_tx(db, hash, mutation, state.receipt_limit) end)
    else
      _ -> {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:submit_request, _credential, _mutation}, _from, state),
    do: {:reply, {:error, :invalid_request}, state}

  def handle_call({:cancel_request, credential, authority_epoch, operation_id}, _from, state) do
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

  def handle_call({:request_status, credential, authority_epoch, operation_id}, _from, state) do
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

  def handle_call(
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

  def handle_call(
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

  def handle_call(
        {:claim_queued_power, principal_id, authority_epoch, operation_id, boot_epoch, now_ms},
        {caller, _tag},
        state
      ) do
    if Id.valid?(principal_id) and Id.valid?(operation_id) and Id.valid?(boot_epoch) and
         is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_i64 and
         is_integer(now_ms) and now_ms >= 0 and now_ms <= @max_i64 do
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
               state
             )
           end) do
        {:ok, receipt} ->
          monitor = Process.monitor(caller)
          key = {principal_id, authority_epoch, operation_id}
          owners = Map.put(state.claim_owners, monitor, {caller, token, key})
          {:reply, {:ok, receipt, token}, %{state | claim_owners: owners}}

        {:error, {:policy, reason}} ->
          {:reply, {:error, reason}, state}

        {:error, reason}
        when reason in [:corrupt_receipt, :corrupt_enrollment, :corrupt_principal] ->
          {:reply, {:error, reason}, %{state | writable: false}}

        {:error, _reason} ->
          {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:reply, {:error, :invalid_claim_input}, state}
    end
  end

  def handle_call(
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

  def handle_call({:fence_rule_generation, expected_revision, authority_epoch}, _from, state) do
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

  def handle_call(
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
            state
          )
        end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_guard_input}, state}
    end
  end

  def handle_call(
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

  def handle_call(
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

  defp admit_held_power_tx(
         db,
         credential,
         hash,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms,
         qualification_state
       ) do
    with {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
      case receipt.disposition do
        :queued ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        :held ->
          case inspect_held_power_result(
                 db,
                 credential,
                 authority_epoch,
                 operation_id,
                 boot_epoch,
                 now_ms
               ) do
            {:ok, :already_reported, _snapshot} ->
              case close_no_send_if_idle(db, receipt, Enum.at(row, 1)) do
                {:ok, revision} ->
                  {:commit,
                   {:ok,
                    %{
                      receipt
                      | disposition: :rejected,
                        reason: "already_reported_no_send",
                        revision: revision
                    }}}

                {:error, :effect_domain_busy} ->
                  {:rollback, {:policy, :effect_domain_busy}}

                {:error, reason} ->
                  {:rollback, reason}
              end

            {:ok, :requires_effect, snapshot} ->
              [_, target_id, "power", "boolean", value_a, nil, profile_ref | _] = row

              with {:ok, evidence_ref} <-
                     qualified_power_profile(
                       db,
                       target_id,
                       profile_ref,
                       snapshot.resource_revision,
                       qualification_state
                     ),
                   {:ok, revision} <- next_revision(db),
                   :ok <-
                     queue_held_power(
                       db,
                       receipt,
                       target_id,
                       profile_ref,
                       evidence_ref,
                       snapshot.resource_revision,
                       snapshot.observation_revision,
                       value_a,
                       revision
                     ) do
                {:commit, {:ok, %{receipt | disposition: :queued, revision: revision}}}
              else
                {:error, reason}
                when reason in [
                       :profile_unqualified,
                       :runtime_artifact_unavailable,
                       :qualification_artifact_unavailable,
                       :effect_domain_busy
                     ] ->
                  {:rollback, {:policy, reason}}

                {:error, reason} ->
                  {:rollback, reason}
              end

            {:error, reason} ->
              {:rollback, {:policy, reason}}
          end

        _ ->
          {:rollback, {:policy, :request_not_held}}
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:error, reason} when reason in [:unauthorized, :corrupt_principal, :corrupt_receipt] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp qualified_power_profile(db, target_id, profile_ref, resource_revision, qualification_state) do
    with {:ok,
          [
            [
              evidence_ref,
              registry_digest,
              runtime_digest,
              identity_digest,
              basis_digest,
              document
            ]
          ]} <-
           query(
             db,
             "SELECT q.evidence_ref, q.registry_digest, q.runtime_digest, q.identity_digest, q.basis_digest, t.document FROM profile_qualifications q JOIN enrollment_bindings b ON b.thing_id = q.thing_id JOIN enrolled_things t ON t.thing_id = q.thing_id JOIN principals p ON p.principal_id = b.operator_id WHERE q.thing_id = ? AND q.profile_ref = ? AND q.resource_revision = ? AND q.status = 'qualified' AND t.status = 'active' AND t.resource_revision = q.resource_revision AND b.digest_version = 2 AND b.identity_digest = q.identity_digest AND b.profile_ref = q.profile_ref AND p.status = 'active'",
             [target_id, profile_ref, resource_revision]
           ),
         true <- Id.valid?(evidence_ref) and is_binary(identity_digest),
         true <- registry_digest == ProductRegistry.pinned_digest(),
         {:ok, ^runtime_digest} <- ProfileBasis.runtime_digest(),
         {:ok, verified} <-
           Claims.verify(
             qualification_state.qualification_claim_root,
             evidence_ref,
             qualification_state.qualification_case_keys,
             qualification_state.qualification_decision_keys
           ),
         true <-
           verified.thing_id == target_id and verified.profile_ref == profile_ref and
             verified.resource_revision == resource_revision and
             verified.identity_digest == identity_digest and
             verified.basis_digest == basis_digest and
             verified.declaration_digest == qualification_digest(document) and
             verified.registry_digest == registry_digest and
             verified.runtime_digest == runtime_digest do
      {:ok, evidence_ref}
    else
      {:error, :runtime_artifact_unavailable} ->
        {:error, :runtime_artifact_unavailable}

      {:error, :qualification_artifact_unavailable} ->
        {:error, :qualification_artifact_unavailable}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :profile_unqualified}
    end
  end

  defp qualify_lifx_power_tx(db, hash, verified, basis, claim_root) do
    with :ok <- qualification_actor(db, hash, verified.thing_id),
         :ok <- qualification_current_basis(db, verified, basis),
         :ok <- Claims.put(claim_root, verified),
         {:ok, existing} <-
           query(
             db,
             "SELECT evidence_ref, status, revision FROM profile_qualifications WHERE thing_id = ?",
             [verified.thing_id]
           ) do
      case existing do
        [] ->
          insert_power_qualification(db, verified)

        [[evidence_ref, "qualified", revision]]
        when evidence_ref == verified.evidence_ref ->
          {:rollback, {:unchanged, {:ok, revision}}}

        _ ->
          {:rollback, {:policy, :qualification_conflict}}
      end
    else
      {:error, reason}
      when reason in [
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :stale_resource_revision,
             :basis_changed,
             :qualification_conflict
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_enrollment}
    end
  end

  defp qualification_actor(db, hash, thing_id) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "qualify:profile" in permissions,
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, thing_id) do
      :ok
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp qualification_current_basis(db, verified, basis) do
    with {:ok, %Thing{} = thing, resource_revision} <- enrolled_thing(db, verified.thing_id),
         true <- resource_revision == verified.resource_revision,
         true <-
           thing.role == "Light" and thing.profile_ref == verified.profile_ref and
             map_size(thing.capabilities) == 1,
         {:ok, %Capability{} = power} <- Thing.capability(thing, "power"),
         true <-
           power.operations == ["read", "write"] and
             power.evidence_ref == basis.qualification_ref,
         {:ok, document} <- Registry.encode_thing(thing),
         true <-
           qualification_digest(document) == basis.declaration_digest and
             verified.registry_digest == ProductRegistry.pinned_digest(),
         {:ok,
          [
            [
              identity_digest,
              qualification_ref,
              profile_ref,
              digest_version,
              manufacturer,
              model,
              firmware,
              operator_status
            ]
          ]} <-
           query(
             db,
             "SELECT b.identity_digest, b.qualification_ref, b.profile_ref, b.digest_version, h.manufacturer, h.model, h.firmware, p.status FROM enrollment_bindings b JOIN enrollment_review_history h ON h.thing_id = b.thing_id AND h.revision = b.revision JOIN principals p ON p.principal_id = b.operator_id WHERE b.thing_id = ?",
             [verified.thing_id]
           ),
         true <-
           identity_digest == verified.identity_digest and
             qualification_ref == basis.qualification_ref and
             profile_ref == verified.profile_ref and digest_version == 2 and
             operator_status == "active",
         {vendor_id, product_id} <- basis.product,
         {major, minor} <- basis.firmware,
         true <-
           manufacturer == "lifx.vendor.#{vendor_id}" and
             model == "lifx.product.#{product_id}" and
             firmware == "#{major}.#{minor}" do
      :ok
    else
      false -> {:error, :basis_changed}
      {:ok, %Thing{}, _revision} -> {:error, :stale_resource_revision}
      {:ok, []} -> {:error, :basis_changed}
      :error -> {:error, :basis_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp insert_power_qualification(db, verified) do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_qualifications VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'qualified', ?)",
             [
               verified.thing_id,
               verified.profile_ref,
               verified.resource_revision,
               verified.identity_digest,
               verified.basis_digest,
               verified.registry_digest,
               verified.runtime_digest,
               verified.evidence_ref,
               revision
             ]
           ),
         :ok <- authority_event(db, revision, "profile_qualified", verified.thing_id) do
      {:commit, {:ok, revision}}
    else
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_enrollment}
    end
  end

  defp qualification_digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp override_now_ms(state),
    do: max(0, System.monotonic_time(:millisecond) - state.override_clock_origin)

  defp issue_override_lease_tx(
         db,
         hash,
         target_id,
         authority_epoch,
         basis_revision,
         now_ms,
         duration_ms,
         boot_epoch
       ) do
    with {:ok, operator_id} <- override_actor(db, hash, target_id),
         {:ok, thing, ^basis_revision} <- enrolled_thing(db, target_id),
         true <- override_target?(thing),
         {:ok, [[^authority_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, prior} <-
           query(
             db,
             "SELECT target_id FROM operator_override_leases WHERE target_id = ?",
             [target_id]
           ),
         :ok <- override_capacity(db, prior),
         :ok <-
           available_override(
             db,
             target_id,
             operator_id,
             authority_epoch,
             boot_epoch,
             now_ms
           ),
         {:ok, lease} <-
           OverrideLease.new(%{
             "target_id" => target_id,
             "operator_id" => operator_id,
             "authority_epoch" => authority_epoch,
             "start_ms" => now_ms,
             "expires_ms" => now_ms + duration_ms,
             "basis_revision" => basis_revision
           }),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO operator_override_leases VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(target_id) DO UPDATE SET operator_id=excluded.operator_id, authority_epoch=excluded.authority_epoch, boot_epoch=excluded.boot_epoch, start_ms=excluded.start_ms, expires_ms=excluded.expires_ms, basis_revision=excluded.basis_revision, revision=excluded.revision",
             [
               target_id,
               operator_id,
               authority_epoch,
               boot_epoch,
               now_ms,
               now_ms + duration_ms,
               basis_revision,
               revision
             ]
           ),
         :ok <- authority_event(db, revision, "override_lease_issued", target_id) do
      {:commit, {:ok, lease, revision}}
    else
      false ->
        {:rollback, {:policy, :unsupported_override_target}}

      {:ok, %Thing{}, _revision} ->
        {:rollback, {:policy, :stale_resource_revision}}

      {:ok, [[_other_epoch]]} ->
        {:rollback, {:policy, :stale_authority_epoch}}

      {:error, reason}
      when reason in [
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :override_conflict,
             :override_capacity,
             :stale_resource_revision
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_override}
    end
  end

  defp override_capacity(_db, [_]), do: :ok

  defp override_capacity(db, []) do
    case query(db, "SELECT COUNT(*) FROM operator_override_leases") do
      {:ok, [[count]]} when is_integer(count) and count < 4_096 ->
        :ok

      {:ok, [[count]]} when is_integer(count) and count >= 4_096 ->
        {:error, :override_capacity}

      _ ->
        {:error, :corrupt_override}
    end
  end

  defp override_capacity(_db, _), do: {:error, :corrupt_override}

  defp available_override(db, target_id, current_operator, authority_epoch, boot_epoch, now_ms) do
    case active_override_for_target(db, target_id, authority_epoch, boot_epoch, now_ms) do
      {:ok, nil} -> :ok
      {:ok, %OverrideLease{operator_id: ^current_operator}} -> :ok
      {:ok, %OverrideLease{}} -> {:error, :override_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_override_for_target(db, target_id) do
    case query(db, "DELETE FROM operator_override_leases WHERE target_id = ?", [target_id]) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  defp clear_override_for_principal(db, principal_id) do
    case query(db, "DELETE FROM operator_override_leases WHERE operator_id = ?", [principal_id]) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  defp clear_override_for_grant(db, principal_id, target_id) do
    case query(
           db,
           "DELETE FROM operator_override_leases WHERE operator_id = ? AND target_id = ?",
           [principal_id, target_id]
         ) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  defp revoke_override_lease_tx(db, hash, target_id, authority_epoch, boot_epoch) do
    with {:ok, operator_id} <- override_actor(db, hash, target_id),
         {:ok, [[^operator_id, ^authority_epoch, ^boot_epoch]]} <-
           query(
             db,
             "SELECT operator_id, authority_epoch, boot_epoch FROM operator_override_leases WHERE target_id = ?",
             [target_id]
           ),
         {:ok, [[^authority_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "DELETE FROM operator_override_leases WHERE target_id = ?", [target_id]),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "override_lease_revoked", target_id) do
      {:commit, {:ok, revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :override_unavailable}}

      {:ok, [[_operator, _epoch, _boot]]} ->
        {:rollback, {:policy, :override_unavailable}}

      {:ok, [[_other_epoch]]} ->
        {:rollback, {:policy, :stale_authority_epoch}}

      {:error, reason} when reason in [:unauthorized, :permission_denied] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_override}
    end
  end

  defp override_actor(db, hash, target_id) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "control:ordinary" in permissions,
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, target_id) do
      {:ok, principal_id}
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp override_target?(%Thing{role: "Light"} = thing) do
    case Thing.capability(thing, "power") do
      {:ok, %Capability{value_kind: "boolean", risk_class: "ordinary", operations: operations}} ->
        "write" in operations

      _ ->
        false
    end
  end

  defp override_target?(_), do: false

  defp active_override_leases_query(db, hash, target_ids, now_ms, boot_epoch) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, grants} <- allowed_targets(db, principal_id),
         true <- Enum.all?(target_ids, &MapSet.member?(grants, &1)),
         {:ok, [[authority_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'") do
      Enum.reduce_while(target_ids, {:ok, []}, fn target_id, {:ok, leases} ->
        case active_override_for_target(db, target_id, authority_epoch, boot_epoch, now_ms) do
          {:ok, nil} -> {:cont, {:ok, leases}}
          {:ok, lease} -> {:cont, {:ok, [lease | leases]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, leases} -> {:ok, Enum.reverse(leases)}
        error -> error
      end
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_override}
    end
  end

  defp active_override_for_target(db, target_id, authority_epoch, boot_epoch, now_ms) do
    case query(
           db,
           "SELECT l.operator_id, l.authority_epoch, l.boot_epoch, l.start_ms, l.expires_ms, l.basis_revision, p.status, t.status, t.resource_revision, t.document, g.principal_id FROM operator_override_leases l JOIN principals p ON p.principal_id = l.operator_id JOIN enrolled_things t ON t.thing_id = l.target_id LEFT JOIN principal_targets g ON g.principal_id = l.operator_id AND g.thing_id = l.target_id WHERE l.target_id = ?",
           [target_id]
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok,
       [
         [
           operator_id,
           lease_epoch,
           lease_boot,
           start_ms,
           expires_ms,
           basis_revision,
           operator_status,
           target_status,
           resource_revision,
           document,
           grant
         ]
       ]} ->
        with {:ok, lease} <-
               OverrideLease.new(%{
                 "target_id" => target_id,
                 "operator_id" => operator_id,
                 "authority_epoch" => lease_epoch,
                 "start_ms" => start_ms,
                 "expires_ms" => expires_ms,
                 "basis_revision" => basis_revision
               }),
             true <- Id.valid?(lease_boot),
             {:ok, thing} <- Registry.decode_thing(document),
             true <- thing.id == target_id do
          if operator_status == "active" and target_status == "active" and
               grant == operator_id and resource_revision == basis_revision and
               lease_boot == boot_epoch and OverrideLease.active?(lease, authority_epoch, now_ms) and
               override_target?(thing),
             do: {:ok, lease},
             else: {:ok, nil}
        else
          _ -> {:error, :corrupt_override}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :corrupt_override}
    end
  end

  defp effect_domain_idle(db, target_id) do
    case query(
           db,
           "SELECT state FROM request_execution WHERE effect_domain = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted', 'outcome_unknown') LIMIT 1",
           [target_id]
         ) do
      {:ok, []} -> :ok
      {:ok, [_]} -> {:error, :effect_domain_busy}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp close_no_send_if_idle(db, receipt, target_id) do
    with :ok <- effect_domain_idle(db, target_id) do
      reject_held(
        db,
        receipt.principal_id,
        receipt.authority_epoch,
        receipt.operation_id,
        "already_reported_no_send"
      )
    end
  end

  defp queue_held_power(
         db,
         receipt,
         target_id,
         profile_ref,
         evidence_ref,
         resource_revision,
         baseline_revision,
         value_a,
         revision
       ) do
    planned_value = if value_a == "1", do: <<1, 1>>, else: <<1, 0>>

    with true <- value_a in ["0", "1"],
         :ok <- effect_domain_idle(db, target_id),
         {:ok, [[rule_generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'held'",
             [receipt.principal_id, receipt.authority_epoch, receipt.operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO request_execution VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', NULL, NULL, NULL, 0, ?)",
             [
               receipt.principal_id,
               receipt.authority_epoch,
               receipt.operation_id,
               target_id,
               target_id,
               profile_ref,
               evidence_ref,
               resource_revision,
               rule_generation,
               baseline_revision,
               revision,
               planned_value,
               revision
             ]
           ),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'queued', reason = NULL, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'held'",
             [revision, receipt.principal_id, receipt.authority_epoch, receipt.operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             receipt.principal_id,
             receipt.authority_epoch,
             receipt.operation_id,
             "queued",
             nil
           ) do
      :ok
    else
      false -> {:error, :corrupt_receipt}
      {:error, :effect_domain_busy} -> {:error, :effect_domain_busy}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp claim_queued_power_tx(
         db,
         principal_id,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms,
         token,
         qualification_state
       ) do
    with {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :queued} = receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         {:ok, [execution_row]} <-
           query(
             db,
             "SELECT target_id, effect_domain, profile_ref, profile_evidence_ref, resource_revision, rule_generation, baseline_revision, planned_value, state, attempts FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, target_id, profile_ref, evidence_ref, resource_revision, rule_generation,
          baseline_revision, desired} <- validate_claim_rows(receipt_row, execution_row),
         :ok <-
           claim_current_guard(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             target_id,
             profile_ref,
             evidence_ref,
             resource_revision,
             rule_generation,
             baseline_revision,
             desired,
             boot_epoch,
             now_ms,
             qualification_state
           ),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = 'claimed', claim_token = CAST(? AS BLOB), claim_boot_epoch = ?, attempts = 1, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'queued'",
             [token, boot_epoch, revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'claimed', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'queued'",
             [revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             "claimed",
             nil
           ) do
      {:commit, %{receipt | disposition: :claimed, revision: revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:ok, %Receipt{}} ->
        {:rollback, {:policy, :request_not_queued}}

      {:error, reason}
      when reason in [
             :principal_unavailable,
             :target_unavailable,
             :stale_authority_epoch,
             :stale_resource_revision,
             :stale_rule_generation,
             :permission_denied,
             :profile_unqualified,
             :runtime_artifact_unavailable,
             :qualification_artifact_unavailable,
             :observation_unavailable,
             :basis_changed,
             :invariant_unresolved,
             :request_not_queued
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp reject_abandoned_claim_tx(db, principal_id, authority_epoch, operation_id, owner_active?) do
    with {:ok, [receipt_row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :claimed} = receipt} <-
           decode_receipt(principal_id, authority_epoch, operation_id, receipt_row),
         false <- owner_active?,
         {:ok, [["claimed", nil, token_type, 32]]} <-
           query(
             db,
             "SELECT state, handoff_revision, typeof(claim_token), length(claim_token) FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
             [principal_id, authority_epoch, operation_id]
           ),
         true <- token_type == "blob",
         {:ok, revision} <-
           invalidate_execution_row(
             db,
             principal_id,
             authority_epoch,
             operation_id,
             "claimed",
             "worker_abandoned_before_handoff"
           ) do
      {:commit,
       %{
         receipt
         | disposition: :rejected,
           reason: "worker_abandoned_before_handoff",
           revision: revision
       }}
    else
      {:ok, []} -> {:rollback, {:policy, :not_found}}
      {:ok, %Receipt{}} -> {:rollback, {:policy, :request_not_claimed}}
      true -> {:rollback, {:policy, :claim_owner_active}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_receipt}
    end
  end

  defp fence_rule_generation_tx(db, expected_revision, authority_epoch) do
    with {:ok, [[current_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[current_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         :ok <-
           check_rule_fence_basis(
             current_revision,
             expected_revision,
             current_epoch,
             authority_epoch,
             generation
           ),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' ORDER BY principal_id, authority_epoch, operation_id LIMIT 1025"
           ),
         {:ok, pending} <- pending_execution_rows(db, :all),
         true <- length(held) + length(pending) <= 1_024,
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "UPDATE meta SET value = ? WHERE key = 'rule_generation'", [generation + 1]),
         :ok <- authority_event(db, revision, "rule_generation_fenced", "rules:empty"),
         {:ok, _after_held} <- reject_held_batch(db, held, "rule_generation_fenced"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, :all, "rule_generation_fenced") do
      {:commit,
       {:ok,
        %{
          store_revision: final_revision,
          rule_generation: generation + 1,
          affected_requests: length(held) + length(pending)
        }}}
    else
      {:error, reason}
      when reason in [:stale_store_revision, :stale_authority_epoch, :generation_exhausted] ->
        {:rollback, {:policy, reason}}

      false ->
        {:rollback, {:policy, :generation_fence_capacity}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, :corrupt_receipt}
    end
  end

  defp check_rule_fence_basis(
         current_revision,
         expected_revision,
         current_epoch,
         authority_epoch,
         generation
       ) do
    cond do
      current_revision != expected_revision ->
        {:error, :stale_store_revision}

      current_epoch != authority_epoch ->
        {:error, :stale_authority_epoch}

      not is_integer(generation) or generation < 0 or generation >= @max_i64 ->
        {:error, :generation_exhausted}

      true ->
        :ok
    end
  end

  defp validate_claim_rows(
         [expected_revision, target_id, "power", "boolean", value_a, nil, profile_ref | _],
         [
           target_id,
           target_id,
           profile_ref,
           evidence_ref,
           resource_revision,
           rule_generation,
           baseline_revision,
           planned_value,
           "queued",
           0
         ]
       ) do
    desired = value_a == "1"

    if value_a in ["0", "1"] and planned_value == <<1, if(desired, do: 1, else: 0)>> and
         expected_revision == resource_revision and is_integer(resource_revision) and
         is_integer(rule_generation) and rule_generation >= 0 and
         is_integer(baseline_revision) and Id.valid?(evidence_ref) do
      {:ok, target_id, profile_ref, evidence_ref, resource_revision, rule_generation,
       baseline_revision, desired}
    else
      {:error, :corrupt_receipt}
    end
  end

  defp validate_claim_rows(_receipt_row, _execution_row), do: {:error, :corrupt_receipt}

  defp claim_current_guard(
         db,
         principal_id,
         authority_epoch,
         operation_id,
         target_id,
         profile_ref,
         evidence_ref,
         resource_revision,
         rule_generation,
         baseline_revision,
         desired,
         boot_epoch,
         now_ms,
         qualification_state
       ) do
    with {:ok, permissions} <- active_principal_permissions(db, principal_id),
         {:ok, targets} <- allowed_targets(db, principal_id),
         {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         :ok <- check_claim_generation(db, rule_generation),
         {:ok, thing, ^resource_revision} <- enrolled_thing(db, target_id),
         true <- thing.role == "Light" and thing.profile_ref == profile_ref,
         {:ok, ^evidence_ref} <-
           qualified_power_profile(
             db,
             target_id,
             profile_ref,
             resource_revision,
             qualification_state
           ),
         mutation = %Mutation{
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           expected_revision: resource_revision,
           target_id: target_id,
           capability_key: "power",
           value: %{"type" => "boolean", "value" => desired}
         },
         :ok <-
           Policy.check(mutation, thing, %Context{
             principal_id: principal_id,
             permissions: permissions,
             allowed_targets: targets,
             authority_epoch: store_epoch,
             resource_revision: resource_revision,
             enrollment_valid: true,
             profile_valid: true,
             invariants: :allow
           }),
         {:ok, capability} <- Thing.capability(thing, "power"),
         {:ok, observation, ^baseline_revision} <- current_report(db, target_id, "power"),
         true <- Observation.valid?(observation, capability),
         {:ok, %Value{kind: :boolean, data: reported}} <-
           fresh_reported_value(observation, capability, boot_epoch, now_ms),
         true <- reported != desired do
      :ok
    else
      false -> {:error, :basis_changed}
      {:ok, %Thing{}, _revision} -> {:error, :stale_resource_revision}
      {:ok, %Observation{}, _revision} -> {:error, :basis_changed}
      {:ok, _other_evidence} -> {:error, :profile_unqualified}
      :error -> {:error, :corrupt_receipt}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp active_principal_permissions(db, principal_id) do
    case query(db, "SELECT permissions, status FROM principals WHERE principal_id = ?", [
           principal_id
         ]) do
      {:ok, [[document, "active"]]} -> Registry.decode_permissions(document)
      {:ok, _} -> {:error, :principal_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_claim_generation(db, rule_generation) do
    case query(db, "SELECT value FROM meta WHERE key = 'rule_generation'") do
      {:ok, [[^rule_generation]]} -> :ok
      {:ok, [[_other]]} -> {:error, :stale_rule_generation}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp settle_held_color_noop_tx(
         db,
         credential,
         hash,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms
       ) do
    with {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
      cond do
        receipt.disposition == :rejected and receipt.reason == "already_reported_no_send" ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        receipt.disposition != :held ->
          {:rollback, {:policy, :request_not_held}}

        true ->
          case inspect_held_color_result(
                 db,
                 credential,
                 authority_epoch,
                 operation_id,
                 boot_epoch,
                 now_ms
               ) do
            {:ok, plan, _snapshot} ->
              if ColorPlan.no_effect?(plan) do
                case close_no_send_if_idle(db, receipt, Enum.at(row, 1)) do
                  {:ok, revision} ->
                    {:commit,
                     {:ok,
                      %{
                        receipt
                        | disposition: :rejected,
                          reason: "already_reported_no_send",
                          revision: revision
                      }}}

                  {:error, :effect_domain_busy} ->
                    {:rollback, {:policy, :effect_domain_busy}}

                  {:error, reason} ->
                    {:rollback, reason}
                end
              else
                {:rollback, {:policy, :effect_required}}
              end

            {:error, reason} ->
              {:rollback, {:policy, reason}}
          end
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:error, reason} when reason in [:corrupt_principal, :corrupt_receipt] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp settle_held_power_noop_tx(
         db,
         credential,
         hash,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms
       ) do
    with {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
      cond do
        receipt.disposition == :rejected and receipt.reason == "already_reported_no_send" ->
          {:rollback, {:unchanged, {:ok, receipt}}}

        receipt.disposition != :held ->
          {:rollback, {:policy, :request_not_held}}

        true ->
          case inspect_held_power_result(
                 db,
                 credential,
                 authority_epoch,
                 operation_id,
                 boot_epoch,
                 now_ms
               ) do
            {:ok, :already_reported, _snapshot} ->
              case close_no_send_if_idle(db, receipt, Enum.at(row, 1)) do
                {:ok, revision} ->
                  {:commit,
                   {:ok,
                    %{
                      receipt
                      | disposition: :rejected,
                        reason: "already_reported_no_send",
                        revision: revision
                    }}}

                {:error, :effect_domain_busy} ->
                  {:rollback, {:policy, :effect_domain_busy}}

                {:error, reason} ->
                  {:rollback, reason}
              end

            {:ok, :requires_effect, _snapshot} ->
              {:rollback, {:policy, :effect_required}}

            {:error, reason} ->
              {:rollback, {:policy, reason}}
          end
      end
    else
      {:ok, []} ->
        {:rollback, {:policy, :not_found}}

      {:error, reason} when reason in [:corrupt_principal, :corrupt_receipt] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp inspect_held_color_result(
         db,
         credential,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms
       ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :held}} <-
           decode_receipt(principal_id, authority_epoch, operation_id, row),
         :ok <- held_outbox(db, principal_id, authority_epoch, operation_id),
         [expected_revision, target_id, key, kind, a, b, profile_ref | _] = row,
         true <- key in ~w(brightness colour_hsv colour_temperature),
         {:ok, value} <- decode_value(kind, a, b),
         {:ok, value_map} <- color_value_map(value),
         {:ok, thing, resource_revision} <- enrolled_thing(db, target_id),
         true <- thing.role == "Light" and thing.profile_ref == profile_ref,
         {:ok, allowed_targets} <- allowed_targets(db, principal_id),
         {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         mutation = %Mutation{
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           expected_revision: expected_revision,
           target_id: target_id,
           capability_key: key,
           value: value_map
         },
         :ok <-
           Policy.check(mutation, thing, %Context{
             principal_id: principal_id,
             permissions: permissions,
             allowed_targets: allowed_targets,
             authority_epoch: store_epoch,
             resource_revision: resource_revision,
             enrollment_valid: true,
             profile_valid: true,
             invariants: :allow
           }),
         {:ok, reports, revisions} <- color_reports(db, target_id),
         {:ok, plan} <- ColorPlan.new(thing, mutation, reports, boot_epoch, now_ms) do
      {:ok, plan,
       %{
         store_revision: store_revision,
         resource_revision: resource_revision,
         observation_revisions: revisions,
         boot_epoch: boot_epoch,
         checked_monotonic_ms: now_ms
       }}
    else
      {:ok, []} -> {:error, :not_found}
      {:ok, %Receipt{}} -> {:error, :request_not_held}
      false -> {:error, :guard_unresolved}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :guard_unresolved}
    end
  end

  defp color_value_map(%Value{kind: :fraction, data: ppm}),
    do: {:ok, %{"type" => "fraction", "ppm" => ppm}}

  defp color_value_map(%Value{kind: :hsv, data: {hue, saturation}}),
    do: {:ok, %{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation}}

  defp color_value_map(%Value{kind: :kelvin, data: kelvin}),
    do: {:ok, %{"type" => "kelvin", "kelvin" => kelvin}}

  defp color_value_map(_value), do: {:error, :unsupported_capability}

  defp color_reports(db, target_id) do
    Enum.reduce_while(~w(brightness colour_hsv colour_temperature), {:ok, %{}, %{}}, fn key,
                                                                                        {:ok,
                                                                                         reports,
                                                                                         revisions} ->
      case current_report(db, target_id, key) do
        {:ok, report, revision} ->
          {:cont, {:ok, Map.put(reports, key, report), Map.put(revisions, key, revision)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp inspect_held_power_result(
         db,
         credential,
         authority_epoch,
         operation_id,
         boot_epoch,
         now_ms
       ) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, [row]} <- select_request(db, principal_id, authority_epoch, operation_id),
         {:ok, %Receipt{disposition: :held}} <-
           decode_receipt(principal_id, authority_epoch, operation_id, row),
         :ok <- held_outbox(db, principal_id, authority_epoch, operation_id),
         [expected_revision, target_id, capability_key, kind, a, b, profile_ref | _] = row,
         true <- capability_key == "power" and kind == "boolean" and is_nil(b),
         {:ok, %Value{kind: :boolean, data: desired}} <- decode_value(kind, a, b),
         {:ok, thing, resource_revision} <- enrolled_thing(db, target_id),
         true <- thing.role == "Light" and thing.profile_ref == profile_ref,
         {:ok, allowed_targets} <- allowed_targets(db, principal_id),
         {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         mutation = %Mutation{
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           expected_revision: expected_revision,
           target_id: target_id,
           capability_key: capability_key,
           value: %{"type" => "boolean", "value" => desired}
         },
         :ok <-
           Policy.check(mutation, thing, %Context{
             principal_id: principal_id,
             permissions: permissions,
             allowed_targets: allowed_targets,
             authority_epoch: store_epoch,
             resource_revision: resource_revision,
             enrollment_valid: true,
             profile_valid: true,
             invariants: :allow
           }),
         {:ok, capability} <- Thing.capability(thing, "power"),
         {:ok, observation, observation_revision} <- current_report(db, target_id, "power"),
         true <- Observation.valid?(observation, capability),
         {:ok, %Value{kind: :boolean, data: reported}} <-
           fresh_reported_value(observation, capability, boot_epoch, now_ms) do
      decision = if desired == reported, do: :already_reported, else: :requires_effect

      {:ok, decision,
       %{
         store_revision: store_revision,
         resource_revision: resource_revision,
         observation_revision: observation_revision,
         boot_epoch: boot_epoch,
         checked_monotonic_ms: now_ms
       }}
    else
      {:ok, []} -> {:error, :not_found}
      {:ok, %Receipt{}} -> {:error, :request_not_held}
      :error -> {:error, :unsupported_capability}
      false -> {:error, :guard_unresolved}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :guard_unresolved}
    end
  end

  defp current_report(db, target_id, capability_key) do
    case query(db, @select_current, [target_id, capability_key]) do
      {:ok, [row]} -> decode_current(target_id, capability_key, row)
      {:ok, []} -> {:error, :observation_unavailable}
      {:ok, _} -> {:error, :corrupt_value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fresh_reported_value(observation, capability, boot_epoch, now_ms) do
    case Observation.current_value(observation, capability, boot_epoch, now_ms) do
      {:ok, value} -> {:ok, value}
      :unknown -> {:error, :observation_unavailable}
    end
  end

  defp held_outbox(db, principal_id, authority_epoch, operation_id) do
    case query(
           db,
           "SELECT state FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
           [principal_id, authority_epoch, operation_id]
         ) do
      {:ok, [["held"]]} -> :ok
      {:ok, _} -> {:error, :corrupt_receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_inputs_result(db, credential) do
    with {:ok, principal_id} <- review_principal(db, credential),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, rows} <- catalogue_rows(db, principal_id, "", 33),
         true <- rows != [] and length(rows) <= 32,
         {:ok, things} <- review_things(rows) do
      {:ok, things, revision}
    else
      false ->
        {:error, :review_scope_unavailable}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp review_current_result(db, credential, watermark) do
    with true <- is_integer(watermark) and watermark >= 0 and watermark <= @max_i64,
         {:ok, _principal_id} <- review_principal(db, credential),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision) do
      :ok
    else
      false ->
        {:error, :invalid_review_watermark}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :resnapshot_required
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp review_principal(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "rule:review" in permissions do
      {:ok, principal_id}
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_things(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn
      [thing_id, profile_ref, document, revision], {:ok, things} ->
        case Registry.decode_thing(document) do
          {:ok, %Thing{id: ^thing_id, profile_ref: ^profile_ref} = thing}
          when is_integer(revision) and revision >= 0 ->
            {:cont, {:ok, Map.put(things, thing_id, thing)}}

          _ ->
            {:halt, {:error, :corrupt_enrollment}}
        end
    end)
  end

  defp snapshot_page_result(db, credential, watermark, after_key, page_size) do
    with :ok <- valid_snapshot_request(watermark, after_key, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- snapshot_rows(db, principal_id, after_key, page_size + 1),
         {:ok, items} <- snapshot_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size

      next_after =
        if more? do
          last = List.last(items)
          %{"thing_id" => last["thing_id"], "capability_key" => last["capability_key"]}
        end

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason} when reason in [:invalid_snapshot_request, :resnapshot_required] ->
        {:error, reason}

      {:error, reason} when reason in [:invalid_credential, :unauthorized, :permission_denied] ->
        {:error, reason}

      {:error, reason} when reason in [:corrupt_principal, :corrupt_value] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp catalogue_page_result(db, credential, watermark, after_id, page_size) do
    with :ok <- valid_catalogue_request(watermark, after_id, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- catalogue_rows(db, principal_id, after_id || "", page_size + 1),
         {:ok, items} <- catalogue_items(Enum.take(rows, page_size)) do
      next_after = if length(rows) > page_size, do: List.last(items)["id"]

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason}
      when reason in [
             :invalid_catalogue_request,
             :resnapshot_required,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp history_page_result(
         db,
         credential,
         thing_id,
         capability_key,
         watermark,
         after_revision,
         page_size
       ) do
    with :ok <-
           valid_history_request(thing_id, capability_key, watermark, after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, thing_id),
         {:ok, thing, _resource_revision} <- enrolled_thing(db, thing_id),
         {:ok, _capability} <- Thing.capability(thing, capability_key),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <-
           history_rows(db, thing_id, capability_key, after_revision, revision, page_size + 1),
         {:ok, items} <- history_items(Enum.take(rows, page_size), thing_id, capability_key) do
      next_after = if length(rows) > page_size, do: List.last(items)["revision"]

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      :error ->
        {:error, :unknown_capability}

      {:error, reason}
      when reason in [
             :invalid_history_request,
             :resnapshot_required,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :corrupt_enrollment,
             :corrupt_principal,
             :corrupt_value
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp events_page_result(db, credential, after_revision, page_size) do
    with :ok <- valid_events_request(after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[watermark]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- event_cursor_not_ahead(after_revision, watermark),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- event_rows(db, principal_id, after_revision, watermark, page_size + 1),
         {:ok, items} <- event_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size
      next_after = if more?, do: List.last(items)["revision"], else: watermark

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: watermark,
         items: items,
         next_after: next_after,
         has_more: more?
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason}
      when reason in [
             :invalid_events_request,
             :invalid_event_cursor,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_value
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp request_events_page_result(db, credential, after_revision, page_size) do
    with :ok <- valid_events_request(after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [[watermark]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- event_cursor_not_ahead(after_revision, watermark),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <-
           query(
             db,
             "SELECT authority_epoch, operation_id, disposition, reason, revision FROM request_journal WHERE principal_id = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?",
             [principal_id, after_revision, watermark, page_size + 1]
           ),
         {:ok, items} <- request_event_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size
      next_after = if more?, do: List.last(items)["revision"], else: watermark

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: watermark,
         items: items,
         next_after: next_after,
         has_more: more?
       }}
    else
      {:error, reason}
      when reason in [
             :invalid_events_request,
             :invalid_event_cursor,
             :invalid_credential,
             :unauthorized,
             :corrupt_principal,
             :corrupt_receipt
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp request_event_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [epoch, operation_id, disposition, reason, revision], {:ok, items}
      when is_integer(epoch) and epoch >= 0 and is_binary(operation_id) and
             is_integer(revision) and revision >= 0 ->
        if Id.valid?(operation_id) and
             ((disposition == "held" and is_nil(reason)) or
                (disposition == "rejected" and is_binary(reason) and byte_size(reason) <= 128)) do
          item = %{
            "authority_epoch" => epoch,
            "operation_id" => operation_id,
            "disposition" => disposition,
            "reason" => reason,
            "revision" => revision
          }

          {:cont, {:ok, [item | items]}}
        else
          {:halt, {:error, :corrupt_receipt}}
        end

      _, _ ->
        {:halt, {:error, :corrupt_receipt}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_events_request(after_revision, page_size) do
    if is_integer(after_revision) and after_revision >= 0 and after_revision <= @max_i64 and
         is_integer(page_size) and page_size >= 1 and page_size <= 100,
       do: :ok,
       else: {:error, :invalid_events_request}
  end

  defp event_cursor_not_ahead(after_revision, watermark) when after_revision <= watermark,
    do: :ok

  defp event_cursor_not_ahead(_after_revision, _watermark),
    do: {:error, :invalid_event_cursor}

  defp event_rows(db, principal_id, after_revision, watermark, limit) do
    query(
      db,
      "SELECT j.thing_id, j.capability_key, j.profile_ref, j.evidence_ref, j.source_epoch, j.source_sequence, j.boot_epoch, j.source_time_utc_ms, j.received_time_utc_ms, j.received_monotonic_ms, j.quality, j.trust, j.value_kind, j.value_a, j.value_b, j.revision FROM journal j JOIN principal_targets g ON g.thing_id = j.thing_id JOIN enrolled_things t ON t.thing_id = j.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND j.event_type = 'observation' AND j.revision > ? AND j.revision <= ? ORDER BY j.revision LIMIT ?",
      [principal_id, after_revision, watermark, limit]
    )
  end

  defp event_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, capability_key | rest], {:ok, items} ->
        case decode_current(thing_id, capability_key, rest) do
          {:ok, observation, revision} ->
            [profile_ref, evidence_ref | _] = rest
            item = observation_item(observation, revision, profile_ref, evidence_ref)
            {:cont, {:ok, [item | items]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_history_request(thing_id, capability_key, watermark, after_revision, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    if Id.valid?(thing_id) and Id.valid?(capability_key) and valid_watermark and
         is_integer(after_revision) and after_revision >= 0 and after_revision <= @max_i64 and
         is_integer(page_size) and page_size >= 1 and page_size <= 100,
       do: :ok,
       else: {:error, :invalid_history_request}
  end

  defp history_rows(db, thing_id, capability_key, after_revision, watermark, limit) do
    query(
      db,
      "SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch, source_time_utc_ms, received_time_utc_ms, received_monotonic_ms, quality, trust, value_kind, value_a, value_b, revision FROM journal WHERE thing_id = ? AND capability_key = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?",
      [thing_id, capability_key, after_revision, watermark, limit]
    )
  end

  defp history_items(rows, thing_id, capability_key) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, items} ->
      case decode_current(thing_id, capability_key, row) do
        {:ok, observation, revision} ->
          [profile_ref, evidence_ref | _] = row

          item =
            observation_item(observation, revision, profile_ref, evidence_ref)

          {:cont, {:ok, [item | items]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_catalogue_request(watermark, after_id, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    if valid_watermark and (is_nil(after_id) or Id.valid?(after_id)) and
         (is_nil(after_id) or not is_nil(watermark)) and is_integer(page_size) and
         page_size >= 1 and page_size <= 10,
       do: :ok,
       else: {:error, :invalid_catalogue_request}
  end

  defp catalogue_rows(db, principal_id, after_id, limit) do
    query(
      db,
      "SELECT t.thing_id, t.profile_ref, t.document, t.resource_revision FROM enrolled_things t JOIN principal_targets g ON g.thing_id = t.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND t.thing_id > ? ORDER BY t.thing_id LIMIT ?",
      [principal_id, after_id, limit]
    )
  end

  defp catalogue_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, profile_ref, document, resource_revision], {:ok, items} ->
        with {:ok, %Thing{id: ^thing_id, profile_ref: ^profile_ref}} <-
               Registry.decode_thing(document),
             true <- is_integer(resource_revision) and resource_revision >= 0,
             {:ok, declaration} <- JSON.decode(document) do
          item = Map.put(declaration, "resource_revision", resource_revision)
          {:cont, {:ok, [item | items]}}
        else
          _ -> {:halt, {:error, :corrupt_enrollment}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_snapshot_request(watermark, after_key, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    valid_after =
      is_nil(after_key) or
        (is_map(after_key) and map_size(after_key) == 2 and
           Id.valid?(after_key["thing_id"]) and Id.valid?(after_key["capability_key"]))

    if valid_watermark and valid_after and is_integer(page_size) and page_size >= 1 and
         page_size <= 100 and (is_nil(after_key) or not is_nil(watermark)),
       do: :ok,
       else: {:error, :invalid_snapshot_request}
  end

  defp snapshot_watermark(nil, _revision), do: :ok
  defp snapshot_watermark(revision, revision), do: :ok
  defp snapshot_watermark(_watermark, _revision), do: {:error, :resnapshot_required}

  defp snapshot_rows(db, principal_id, after_key, limit) do
    {thing_id, capability_key} =
      case after_key do
        nil ->
          {"", ""}

        %{"thing_id" => thing_id, "capability_key" => capability_key} ->
          {thing_id, capability_key}
      end

    query(
      db,
      "SELECT c.thing_id, c.capability_key, c.profile_ref, c.evidence_ref, c.source_epoch, c.source_sequence, c.boot_epoch, c.source_time_utc_ms, c.received_time_utc_ms, c.received_monotonic_ms, c.quality, c.trust, c.value_kind, c.value_a, c.value_b, c.revision FROM observation_current c JOIN principal_targets g ON g.thing_id = c.thing_id JOIN enrolled_things t ON t.thing_id = c.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND (c.thing_id > ? OR (c.thing_id = ? AND c.capability_key > ?)) ORDER BY c.thing_id, c.capability_key LIMIT ?",
      [principal_id, thing_id, thing_id, capability_key, limit]
    )
  end

  defp snapshot_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, capability_key | rest], {:ok, items} ->
        case decode_current(thing_id, capability_key, rest) do
          {:ok, observation, revision} ->
            [profile_ref, evidence_ref | _] = rest
            item = observation_item(observation, revision, profile_ref, evidence_ref)

            {:cont, {:ok, [item | items]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp observation_item(observation, revision, profile_ref, evidence_ref) do
    %{
      "thing_id" => observation.thing_id,
      "capability_key" => observation.capability_key,
      "profile_ref" => profile_ref,
      "evidence_ref" => evidence_ref,
      "value" => snapshot_value(observation.value),
      "quality" => observation.quality,
      "trust" => observation.trust,
      "source_epoch" => observation.source_epoch,
      "source_sequence" => observation.source_sequence,
      "boot_epoch" => observation.boot_epoch,
      "source_time_utc_ms" => observation.source_time_utc_ms,
      "received_time_utc_ms" => observation.received_time_utc_ms,
      "received_monotonic_ms" => observation.received_monotonic_ms,
      "revision" => revision
    }
  end

  defp snapshot_value(nil), do: nil

  defp snapshot_value(%Value{kind: :boolean, data: value}),
    do: %{"type" => "boolean", "value" => value}

  defp snapshot_value(%Value{kind: :fraction, data: ppm}),
    do: %{"type" => "fraction", "ppm" => ppm}

  defp snapshot_value(%Value{kind: :kelvin, data: kelvin}),
    do: %{"type" => "kelvin", "kelvin" => kelvin}

  defp snapshot_value(%Value{kind: :hsv, data: {hue, saturation}}),
    do: %{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation}

  defp snapshot_value(%Value{kind: :xy, data: {x, y}}),
    do: %{"type" => "xy", "x_ppm" => x, "y_ppm" => y}

  defp snapshot_value(%Value{kind: :smoke_state, data: state}),
    do: %{"type" => "smoke_state", "state" => state}

  defp health_result(state) do
    with {:ok, [[revision]]} <- query(state.db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[epoch]]} <-
           query(state.db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[rule_generation]]} <-
           query(state.db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         {:ok, [[held_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM request_outbox WHERE state = 'held'"),
         {:ok, [[queued_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM request_execution WHERE state = 'queued'"),
         {:ok, [[claimed_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM request_execution WHERE state = 'claimed'"),
         {:ok, [[unknown_count]]} <-
           query(
             state.db,
             "SELECT COUNT(*) FROM request_execution WHERE state = 'outcome_unknown'"
           ),
         {:ok, [[receipt_count]]} <- query(state.db, "SELECT COUNT(*) FROM request_receipts"),
         {:ok, [[thing_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM enrolled_things WHERE status = 'active'"),
         {:ok, [[principal_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM principals WHERE status = 'active'"),
         true <-
           is_integer(revision) and revision >= 0 and is_integer(epoch) and epoch >= 1 and
             is_integer(rule_generation) and rule_generation >= 0 and
             Enum.all?(
               [
                 held_count,
                 queued_count,
                 claimed_count,
                 unknown_count,
                 receipt_count,
                 thing_count,
                 principal_count
               ],
               &is_integer/1
             ) do
      {:ok,
       %{
         store_revision: revision,
         authority_epoch: epoch,
         rule_generation: rule_generation,
         held_requests: held_count,
         queued_requests: queued_count,
         claimed_requests: claimed_count,
         unknown_outcomes: unknown_count,
         retained_receipts: receipt_count,
         receipt_capacity: state.receipt_limit,
         active_things: thing_count,
         active_principals: principal_count,
         writable: state.writable,
         dispatch_enabled: false
       }}
    else
      _ -> {:error, :store_unavailable}
    end
  end

  defp read_health(state, {:error, :store_unavailable}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_value}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_receipt}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_enrollment}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_principal}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_override}), do: %{state | writable: false}
  defp read_health(state, _result), do: state

  defp write_reply(state, fun) do
    case transaction(state.db, fun) do
      {:ok, result} ->
        {:reply, result, prune_claim_owners(state)}

      {:error, {:policy, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, :corrupt_enrollment} ->
        {:reply, {:error, :corrupt_enrollment}, %{state | writable: false}}

      {:error, :corrupt_principal} ->
        {:reply, {:error, :corrupt_principal}, %{state | writable: false}}

      {:error, :corrupt_receipt} ->
        {:reply, {:error, :corrupt_receipt}, %{state | writable: false}}

      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, %{state | writable: false}}
    end
  end

  defp prune_claim_owners(%{claim_owners: owners} = state) when map_size(owners) == 0,
    do: state

  defp prune_claim_owners(state) do
    case query(
           state.db,
           "SELECT principal_id, authority_epoch, operation_id FROM request_execution WHERE state = 'claimed'"
         ) do
      {:ok, rows} ->
        claimed = MapSet.new(Enum.map(rows, &List.to_tuple/1))

        owners =
          Enum.reduce(state.claim_owners, %{}, fn {monitor, {_pid, _token, key} = value}, acc ->
            if MapSet.member?(claimed, key) do
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

  defp enroll_thing_tx(db, thing, document) do
    case query(
           db,
           "SELECT document, resource_revision, status FROM enrolled_things WHERE thing_id = ?",
           [thing.id]
         ) do
      {:ok, []} ->
        with {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "INSERT INTO enrolled_things VALUES (?, ?, ?, 0, 'active')", [
                 thing.id,
                 thing.profile_ref,
                 document
               ]),
             :ok <- authority_event(db, revision, "thing_enrolled", thing.id) do
          {:commit, {:ok, revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, [[_document, _resource_revision, _status]]} ->
        {:rollback, {:policy, :enrollment_conflict}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp commit_enrollment_tx(db, hash, review, interview, thing, document) do
    with {:ok, operator_id, permissions} <- authenticate(db, hash),
         true <- operator_id == review.operator_id,
         true <- "enroll:review" in permissions,
         {:ok, []} <-
           query(
             db,
             "SELECT thing_id FROM enrollment_bindings WHERE stable_id = ? OR identity_digest = ? LIMIT 1",
             [review.stable_id, review.identity_digest]
           ),
         {:ok, []} <-
           query(
             db,
             "SELECT thing_id FROM enrollment_review_history WHERE review_ref = ? LIMIT 1",
             [review.review_ref]
           ),
         {:ok, []} <-
           query(db, "SELECT thing_id FROM enrolled_things WHERE thing_id = ?", [thing.id]),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "INSERT INTO enrolled_things VALUES (?, ?, ?, 0, 'active')", [
             thing.id,
             thing.profile_ref,
             document
           ]),
         {:ok, []} <-
           query(db, "INSERT INTO enrollment_bindings VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 2)", [
             thing.id,
             review.stable_id,
             review.identity_digest,
             review.candidate_ref,
             review.review_ref,
             review.method,
             review.qualification_ref,
             operator_id,
             review.profile_ref,
             revision
           ]),
         :ok <- insert_enrollment_review_history(db, revision, review, interview, operator_id),
         :ok <- authority_event(db, revision, "thing_enrolled_reviewed", thing.id) do
      {:commit, {:ok, revision}}
    else
      false ->
        {:rollback, {:policy, :permission_denied}}

      {:ok, _} ->
        {:rollback, {:policy, :enrollment_conflict}}

      {:error, reason} when reason in [:unauthorized, :corrupt_principal] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp rereview_enrollment_tx(db, hash, review, interview, thing) do
    with {:ok, operator_id, permissions} <- authenticate(db, hash),
         :ok <- review_permission(operator_id, permissions, review.operator_id),
         {:ok, ^thing, _resource_revision} <- enrolled_thing(db, thing.id),
         {:ok, [[stable_id, method, qualification_ref, ^operator_id, profile_ref]]} <-
           query(
             db,
             "SELECT stable_id, method, qualification_ref, operator_id, profile_ref FROM enrollment_bindings WHERE thing_id = ?",
             [thing.id]
           ),
         :ok <-
           review_binding_matches(
             {stable_id, method, qualification_ref, profile_ref},
             review
           ),
         {:ok, []} <-
           query(db, "SELECT thing_id FROM enrollment_review_history WHERE review_ref = ?", [
             review.review_ref
           ]),
         :ok <- review_capacity(db, thing.id),
         {:ok, held} <- held_for_thing(db, thing.id),
         {:ok, revision} <- next_revision(db),
         :ok <- insert_enrollment_review_history(db, revision, review, interview, operator_id),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrollment_bindings SET identity_digest = ?, digest_version = 2, candidate_ref = ?, review_ref = ?, revision = ? WHERE thing_id = ?",
             [review.identity_digest, review.candidate_ref, review.review_ref, revision, thing.id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing.id]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id = ?", [thing.id]),
         {:ok, []} <-
           query(db, "UPDATE profile_qualifications SET status = 'revoked' WHERE thing_id = ?", [
             thing.id
           ]),
         :ok <- authority_event(db, revision, "thing_enrollment_rereviewed", thing.id),
         {:ok, _held_revision} <- reject_held_batch(db, held, "identity_rechecked"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, {:thing, thing.id}, "identity_rechecked") do
      {:commit, {:ok, final_revision}}
    else
      {:ok, []} ->
        {:rollback, {:policy, :review_binding_unavailable}}

      {:ok, _rows} ->
        {:rollback, {:policy, :review_conflict}}

      {:error, reason}
      when reason in [
             :unauthorized,
             :target_unavailable,
             :permission_denied,
             :review_binding_mismatch,
             :review_capacity
           ] ->
        {:rollback, {:policy, reason}}

      {:error, reason} ->
        {:rollback, reason}

      _ ->
        {:rollback, {:policy, :review_binding_mismatch}}
    end
  end

  defp review_permission(operator_id, permissions, selected_operator) do
    if operator_id == selected_operator and "enroll:review" in permissions,
      do: :ok,
      else: {:error, :permission_denied}
  end

  defp review_binding_matches({stable_id, method, qualification_ref, profile_ref}, review) do
    if {stable_id, method, qualification_ref, profile_ref} ==
         {review.stable_id, review.method, review.qualification_ref, review.profile_ref},
       do: :ok,
       else: {:error, :review_binding_mismatch}
  end

  defp review_capacity(db, thing_id) do
    case query(db, "SELECT COUNT(*) FROM enrollment_review_history WHERE thing_id = ?", [thing_id]) do
      {:ok, [[count]]} when is_integer(count) and count < 32 -> :ok
      {:ok, [[_count]]} -> {:error, :review_capacity}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_enrollment}
    end
  end

  defp insert_enrollment_review_history(db, revision, review, interview, operator_id) do
    case query(
           db,
           "INSERT INTO enrollment_review_history VALUES (?, ?, ?, ?, 2, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
           [
             revision,
             review.thing_id,
             review.stable_id,
             review.identity_digest,
             review.candidate_ref,
             review.review_ref,
             review.method,
             review.qualification_ref,
             operator_id,
             review.profile_ref,
             interview.manufacturer,
             interview.model,
             interview.firmware
           ]
         ) do
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp narrow_thing_tx(db, thing, document, expected_revision) do
    with {:ok, current, ^expected_revision} <- enrolled_thing(db, thing.id),
         true <- narrower_declaration?(current, thing),
         false <- current == thing,
         {:ok, held} <- held_for_thing(db, thing.id),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_target(db, thing.id),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing.id]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id = ?", [thing.id]),
         {:ok, []} <-
           query(db, "UPDATE profile_qualifications SET status = 'revoked' WHERE thing_id = ?", [
             thing.id
           ]),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrolled_things SET document = ?, resource_revision = ? WHERE thing_id = ? AND resource_revision = ? AND status = 'active'",
             [document, expected_revision + 1, thing.id, expected_revision]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "thing_narrowed", thing.id),
         {:ok, _held_revision} <- reject_held_batch(db, held, "declaration_changed"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, {:thing, thing.id}, "declaration_changed") do
      {:commit, {:ok, final_revision}}
    else
      {:ok, _current, _revision} -> {:rollback, {:policy, :stale_resource_revision}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      false -> {:rollback, {:policy, :declaration_widening}}
      true -> {:rollback, {:policy, :unchanged_declaration}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_enrollment}
    end
  end

  defp narrower_declaration?(current, next) do
    current.id == next.id and current.role == next.role and
      current.profile_ref == next.profile_ref and
      MapSet.new(Map.keys(current.capabilities)) == MapSet.new(Map.keys(next.capabilities)) and
      Enum.all?(current.capabilities, fn {key, old} ->
        new = Map.fetch!(next.capabilities, key)

        old.thing_id == new.thing_id and old.role == new.role and old.key == new.key and
          old.value_kind == new.value_kind and old.unit == new.unit and
          old.risk_class == new.risk_class and old.profile_ref == new.profile_ref and
          old.extensions == new.extensions and new.freshness_ms <= old.freshness_ms and
          Enum.all?(new.operations, &(&1 in old.operations)) and
          narrower_constraints?(old.constraints, new.constraints)
      end)
  end

  defp narrower_constraints?(
         %{"min" => old_min, "max" => old_max},
         %{"min" => new_min, "max" => new_max}
       ),
       do: new_min >= old_min and new_max <= old_max

  defp narrower_constraints?(old, new), do: old == new

  defp held_for_thing(db, thing_id) do
    query(
      db,
      "SELECT o.principal_id, o.authority_epoch, o.operation_id FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE o.state = 'held' AND r.disposition = 'held' AND r.target_id = ? ORDER BY o.principal_id, o.authority_epoch, o.operation_id",
      [thing_id]
    )
  end

  defp revoke_thing_tx(db, thing_id) do
    case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [thing_id]) do
      {:ok, [["active"]]} ->
        with {:ok, held} <- held_for_thing(db, thing_id),
             {:ok, revision} <- next_revision(db),
             :ok <- clear_override_for_target(db, thing_id),
             {:ok, []} <-
               query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing_id]),
             {:ok, []} <-
               query(
                 db,
                 "UPDATE profile_qualifications SET status = 'revoked' WHERE thing_id = ?",
                 [
                   thing_id
                 ]
               ),
             {:ok, []} <-
               query(db, "UPDATE enrolled_things SET status = 'revoked' WHERE thing_id = ?", [
                 thing_id
               ]),
             :ok <- authority_event(db, revision, "thing_revoked", thing_id),
             {:ok, _held_revision} <- reject_held_batch(db, held, "target_revoked"),
             {:ok, final_revision} <-
               invalidate_execution_for(db, {:thing, thing_id}, "target_revoked") do
          {:commit, {:ok, final_revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :target_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp provision_principal_tx(db, principal_id, hash, permissions_json, target_ids, credential) do
    with {:ok, []} <-
           query(db, "SELECT principal_id FROM principals WHERE principal_id = ?", [principal_id]),
         :ok <- active_targets(db, target_ids),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "INSERT INTO principals VALUES (?, ?, ?, 'active')", [
             principal_id,
             hash,
             permissions_json
           ]),
         :ok <- insert_targets(db, principal_id, target_ids),
         :ok <- authority_event(db, revision, "principal_provisioned", principal_id) do
      {:commit, {:ok, credential, revision}}
    else
      {:ok, _existing} -> {:rollback, {:policy, :principal_exists}}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp revoke_principal_tx(db, principal_id) do
    case query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]) do
      {:ok, [["active"]]} ->
        with {:ok, held} <-
               query(
                 db,
                 "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
                 [principal_id]
               ),
             {:ok, revision} <- next_revision(db),
             :ok <- clear_override_for_principal(db, principal_id),
             {:ok, []} <-
               query(db, "UPDATE principals SET status = 'revoked' WHERE principal_id = ?", [
                 principal_id
               ]),
             :ok <- authority_event(db, revision, "principal_revoked", principal_id),
             {:ok, _held_revision} <- reject_held_batch(db, held, "principal_revoked"),
             {:ok, final_revision} <-
               invalidate_execution_for(db, {:principal, principal_id}, "principal_revoked") do
          {:commit, {:ok, final_revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :principal_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp revoke_target_grant_tx(db, principal_id, thing_id) do
    with {:ok, [["active"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]),
         {:ok, [[^thing_id]]} <-
           query(
             db,
             "SELECT thing_id FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, held} <-
           query(
             db,
             "SELECT o.principal_id, o.authority_epoch, o.operation_id FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE o.state = 'held' AND r.disposition = 'held' AND o.principal_id = ? AND r.target_id = ? ORDER BY o.authority_epoch, o.operation_id",
             [principal_id, thing_id]
           ),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_grant(db, principal_id, thing_id),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           authority_event(db, revision, "target_grant_revoked", "#{principal_id}/#{thing_id}"),
         {:ok, _held_revision} <- reject_held_batch(db, held, "target_grant_revoked"),
         {:ok, final_revision} <-
           invalidate_execution_for(
             db,
             {:target_grant, principal_id, thing_id},
             "target_grant_revoked"
           ) do
      {:commit, {:ok, final_revision}}
    else
      {:ok, _} -> {:rollback, {:policy, :target_grant_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
    end
  end

  defp rotate_principal_credential_tx(db, principal_id, hash, credential) do
    with {:ok, [["active"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
             [principal_id]
           ),
         {:ok, revision} <- next_revision(db),
         :ok <- clear_override_for_principal(db, principal_id),
         {:ok, []} <-
           query(
             db,
             "UPDATE principals SET credential_hash = ? WHERE principal_id = ? AND status = 'active'",
             [hash, principal_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "principal_credential_rotated", principal_id),
         {:ok, _held_revision} <- reject_held_batch(db, held, "credential_rotated"),
         {:ok, final_revision} <-
           invalidate_execution_for(db, {:principal, principal_id}, "credential_rotated") do
      {:commit, {:ok, credential, final_revision}}
    else
      {:ok, _} -> {:rollback, {:policy, :principal_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
    end
  end

  defp active_targets(db, target_ids) do
    Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
      case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [target_id]) do
        {:ok, [["active"]]} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, {:policy, :target_unavailable}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_targets(db, principal_id, target_ids) do
    Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
      case query(db, "INSERT INTO principal_targets VALUES (?, ?)", [principal_id, target_id]) do
        {:ok, []} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authenticate(db, hash) do
    case query(
           db,
           "SELECT principal_id, permissions, status FROM principals WHERE credential_hash = ?",
           [hash]
         ) do
      {:ok, [[principal_id, permissions_json, "active"]]} ->
        with {:ok, permissions} <- Registry.decode_permissions(permissions_json) do
          {:ok, principal_id, permissions}
        end

      {:ok, _} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enrolled_thing(db, target_id) do
    case query(
           db,
           "SELECT profile_ref, document, resource_revision, status FROM enrolled_things WHERE thing_id = ?",
           [target_id]
         ) do
      {:ok, [[profile_ref, document, resource_revision, "active"]]} ->
        with {:ok, %Thing{id: ^target_id, profile_ref: ^profile_ref} = thing} <-
               Registry.decode_thing(document),
             true <- is_integer(resource_revision) and resource_revision >= 0 do
          {:ok, thing, resource_revision}
        else
          _ -> {:error, :corrupt_enrollment}
        end

      {:ok, _} ->
        {:error, :target_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed_targets(db, principal_id) do
    case query(db, "SELECT thing_id FROM principal_targets WHERE principal_id = ?", [principal_id]) do
      {:ok, rows} -> {:ok, MapSet.new(Enum.map(rows, fn [target_id] -> target_id end))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_target_ids?(ids, permissions) do
    is_list(ids) and is_list(permissions) and length(ids) <= 32 and
      (ids != [] or Enum.all?(permissions, &(&1 in ["read", "enroll:review"]))) and
      Enum.all?(ids, &Id.valid?/1) and length(Enum.uniq(ids)) == length(ids)
  end

  defp next_revision(db) do
    case query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      {:ok, [[revision]]} when is_integer(revision) and revision < @max_i64 ->
        {:ok, revision + 1}

      {:ok, _} ->
        {:error, :revision_exhausted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_source_epoch_tx(
         db,
         thing_id,
         capability_key,
         old_epoch,
         new_epoch,
         current_revision
       ) do
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, thing_id),
         {:ok, _capability} <- Thing.capability(thing, capability_key),
         {:ok, rows} <- query(db, @select_current, [thing_id, capability_key]),
         :ok <- current_epoch_matches(rows, old_epoch, current_revision),
         {:ok, existing} <-
           query(
             db,
             "SELECT old_epoch, new_epoch, current_revision, grant_revision FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ?",
             [thing_id, capability_key]
           ) do
      case existing do
        [[^old_epoch, ^new_epoch, ^current_revision, revision]] ->
          {:rollback, {:unchanged, {:ok, revision}}}

        _ ->
          with {:ok, revision} <- next_revision(db),
               {:ok, []} <-
                 query(
                   db,
                   "INSERT INTO source_epoch_grants VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id, capability_key) DO UPDATE SET old_epoch=excluded.old_epoch, new_epoch=excluded.new_epoch, current_revision=excluded.current_revision, grant_revision=excluded.grant_revision",
                   [thing_id, capability_key, old_epoch, new_epoch, current_revision, revision]
                 ),
               :ok <-
                 authority_event(
                   db,
                   revision,
                   "source_epoch_granted",
                   "#{thing_id}/#{capability_key}"
                 ) do
            {:commit, {:ok, revision}}
          else
            {:error, reason} -> {:rollback, reason}
          end
      end
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:error, {:policy, _} = policy} -> {:rollback, policy}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp current_epoch_matches([], _old_epoch, _revision),
    do: {:error, {:policy, :no_current_observation}}

  defp current_epoch_matches([row], old_epoch, revision) do
    if Enum.at(row, 2) == old_epoch and List.last(row) == revision,
      do: :ok,
      else: {:error, {:policy, :stale_source_epoch}}
  end

  defp authority_event(db, revision, event_type, entity_id) do
    with {:ok, []} <-
           query(db, "INSERT INTO authority_journal VALUES (?, ?, ?)", [
             revision,
             event_type,
             entity_id
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_request_tx(db, hash, mutation, receipt_limit) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, rows} <-
           select_request(db, principal_id, mutation.authority_epoch, mutation.operation_id) do
      case rows do
        [] ->
          with :ok <- receipt_capacity(db, receipt_limit),
               {:ok, thing, resource_revision} <- enrolled_thing(db, mutation.target_id),
               {:ok, allowed_targets} <- allowed_targets(db, principal_id),
               {:ok, [[store_epoch]]} <-
                 query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'") do
            context = %Context{
              principal_id: principal_id,
              permissions: permissions,
              allowed_targets: allowed_targets,
              authority_epoch: store_epoch,
              resource_revision: resource_revision,
              enrollment_valid: true,
              profile_valid: true,
              invariants: :allow
            }

            write_request(db, principal_id, mutation, thing, context)
          else
            {:error, :corrupt_enrollment} -> {:rollback, :corrupt_enrollment}
            {:error, reason} -> {:rollback, {:policy, reason}}
          end

        [row] ->
          prior_request(row, principal_id, mutation)
      end
    else
      {:error, reason} when reason in [:corrupt_principal, :corrupt_enrollment] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp receipt_capacity(db, limit) do
    case query(db, "SELECT COUNT(*) FROM request_receipts") do
      {:ok, [[count]]} when is_integer(count) and count < limit -> :ok
      {:ok, [[count]]} when is_integer(count) -> {:error, :receipt_capacity}
      {:ok, _} -> {:error, :corrupt_receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_request_tx(db, hash, authority_epoch, operation_id) do
    with {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, rows} <- select_request(db, principal_id, authority_epoch, operation_id) do
      case rows do
        [] ->
          {:rollback, {:unchanged, :not_found}}

        [row] ->
          with {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
            case receipt.disposition do
              :held -> cancel_held_tx(db, receipt)
              :queued -> cancel_queued_tx(db, receipt)
              :rejected -> {:rollback, {:unchanged, {:ok, receipt}}}
              _ -> {:rollback, {:policy, :request_not_held}}
            end
          else
            {:error, reason} -> {:rollback, reason}
          end
      end
    else
      {:error, reason} when reason in [:corrupt_principal, :corrupt_receipt] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp cancel_held_tx(db, receipt) do
    case reject_held(
           db,
           receipt.principal_id,
           receipt.authority_epoch,
           receipt.operation_id,
           "cancelled"
         ) do
      {:ok, revision} ->
        {:commit,
         {:ok, %{receipt | disposition: :rejected, reason: "cancelled", revision: revision}}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp cancel_queued_tx(db, receipt) do
    case invalidate_execution_row(
           db,
           receipt.principal_id,
           receipt.authority_epoch,
           receipt.operation_id,
           "queued",
           "cancelled_before_claim"
         ) do
      {:ok, revision} ->
        {:commit,
         {:ok,
          %{
            receipt
            | disposition: :rejected,
              reason: "cancelled_before_claim",
              revision: revision
          }}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp reject_held_batch(db, held, reason) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      Enum.reduce_while(held, {:ok, revision}, fn
        [principal_id, authority_epoch, operation_id], {:ok, _revision} ->
          case reject_held(db, principal_id, authority_epoch, operation_id, reason) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, error} -> {:halt, {:error, error}}
          end

        _, _ ->
          {:halt, {:error, :corrupt_receipt}}
      end)
    end
  end

  defp invalidate_execution_for(db, scope, reason) do
    with {:ok, rows} <- pending_execution_rows(db, scope),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      Enum.reduce_while(rows, {:ok, revision}, fn
        [principal_id, epoch, operation_id, state], {:ok, _last} ->
          case invalidate_execution_row(db, principal_id, epoch, operation_id, state, reason) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, error} -> {:halt, {:error, error}}
          end

        _, _ ->
          {:halt, {:error, :corrupt_receipt}}
      end)
    end
  end

  defp pending_execution_rows(db, {:thing, thing_id}) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE target_id = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY principal_id, authority_epoch, operation_id",
      [thing_id]
    )
  end

  defp pending_execution_rows(db, :all) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY principal_id, authority_epoch, operation_id LIMIT 1025"
    )
  end

  defp pending_execution_rows(db, {:principal, principal_id}) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE principal_id = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY authority_epoch, operation_id",
      [principal_id]
    )
  end

  defp pending_execution_rows(db, {:target_grant, principal_id, thing_id}) do
    query(
      db,
      "SELECT principal_id, authority_epoch, operation_id, state FROM request_execution WHERE principal_id = ? AND target_id = ? AND state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted') ORDER BY authority_epoch, operation_id",
      [principal_id, thing_id]
    )
  end

  defp invalidate_execution_row(db, principal_id, epoch, operation_id, state, reason)
       when state in ["queued", "claimed"] do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_execution WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = ?",
             [principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'rejected', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = ?",
             [reason, revision, principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- request_event(db, revision, principal_id, epoch, operation_id, "rejected", reason) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp invalidate_execution_row(db, principal_id, epoch, operation_id, state, reason)
       when state in ["dispatching", "protocol_accepted"] do
    reason = reason <> "_after_handoff"

    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_execution SET state = 'outcome_unknown', revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = ?",
             [revision, principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'outcome_unknown', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = ?",
             [reason, revision, principal_id, epoch, operation_id, state]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           request_event(
             db,
             revision,
             principal_id,
             epoch,
             operation_id,
             "outcome_unknown",
             reason
           ) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp invalidate_execution_row(_db, _principal_id, _epoch, _operation_id, _state, _reason),
    do: {:error, :corrupt_receipt}

  defp request_event(db, revision, principal_id, epoch, operation_id, state, reason) do
    with {:ok, []} <-
           query(db, "INSERT INTO request_journal VALUES (?, ?, ?, ?, ?, ?)", [
             revision,
             principal_id,
             epoch,
             operation_id,
             state,
             reason
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]) do
      :ok
    else
      {:error, error} -> {:error, error}
    end
  end

  defp reject_held(db, principal_id, authority_epoch, operation_id, reason) do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'held'",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'rejected', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'held'",
             [reason, revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(db, "INSERT INTO request_journal VALUES (?, ?, ?, ?, 'rejected', ?)", [
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             reason
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp select_request(db, principal_id, authority_epoch, operation_id) do
    query(
      db,
      "SELECT expected_revision, target_id, capability_key, value_kind, value_a, value_b, profile_ref, disposition, reason, revision FROM request_receipts WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
      [principal_id, authority_epoch, operation_id]
    )
  end

  defp prior_request(row, principal_id, mutation) do
    {:ok, value} = Value.new(mutation.value)
    {kind, a, b} = encode_value(value)
    [expected_revision, target_id, capability_key, old_kind, old_a, old_b | _] = row

    if {expected_revision, target_id, capability_key, old_kind, old_a, old_b} ==
         {mutation.expected_revision, mutation.target_id, mutation.capability_key, kind, a, b} do
      case decode_receipt(principal_id, mutation.authority_epoch, mutation.operation_id, row) do
        {:ok, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
        {:error, reason} -> {:rollback, reason}
      end
    else
      {:rollback, {:policy, :operation_id_conflict}}
    end
  end

  defp write_request(db, principal_id, mutation, thing, context) do
    with {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, {disposition, reason}} <-
           request_decision(db, principal_id, store_epoch, mutation, thing, context) do
      {:ok, value} = Value.new(mutation.value)
      {kind, a, b} = encode_value(value)
      new_revision = revision + 1

      params = [
        principal_id,
        mutation.authority_epoch,
        mutation.operation_id,
        mutation.expected_revision,
        mutation.target_id,
        mutation.capability_key,
        kind,
        a,
        b,
        thing.profile_ref,
        disposition,
        reason,
        new_revision
      ]

      with {:ok, []} <-
             query(
               db,
               "INSERT INTO request_receipts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               params
             ),
           {:ok, []} <-
             query(db, "INSERT INTO request_journal VALUES (?, ?, ?, ?, ?, ?)", [
               new_revision,
               principal_id,
               mutation.authority_epoch,
               mutation.operation_id,
               disposition,
               reason
             ]),
           :ok <- maybe_hold_request(db, principal_id, mutation, disposition, new_revision),
           {:ok, []} <-
             query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [new_revision]) do
        receipt = %Receipt{
          principal_id: principal_id,
          authority_epoch: mutation.authority_epoch,
          operation_id: mutation.operation_id,
          disposition: if(disposition == "held", do: :held, else: :rejected),
          reason: reason,
          revision: new_revision
        }

        {:commit, {:ok, receipt}}
      else
        {:error, error} -> {:rollback, error}
      end
    else
      {:error, error} -> {:rollback, error}
    end
  end

  defp request_decision(_db, _principal_id, store_epoch, mutation, _thing, _context)
       when store_epoch != mutation.authority_epoch,
       do: {:ok, {"rejected", "stale_authority_epoch"}}

  defp request_decision(db, principal_id, _store_epoch, mutation, thing, context) do
    case Policy.check(mutation, thing, context) do
      :ok -> held_capacity(db, principal_id)
      {:error, reason} -> {:ok, {"rejected", Atom.to_string(reason)}}
    end
  end

  defp held_capacity(db, principal_id) do
    with {:ok, [[principal_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_outbox WHERE principal_id = ?", [principal_id]),
         {:ok, [[global_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox") do
      if principal_count < 32 and global_count < 1_024,
        do: {:ok, {"held", nil}},
        else: {:ok, {"rejected", "pending_capacity"}}
    end
  end

  defp maybe_hold_request(_db, _principal_id, _mutation, "rejected", _revision), do: :ok

  defp maybe_hold_request(db, principal_id, mutation, "held", revision) do
    case query(db, "INSERT INTO request_outbox VALUES (?, ?, ?, 'held', ?)", [
           principal_id,
           mutation.authority_epoch,
           mutation.operation_id,
           revision
         ]) do
      {:ok, []} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp decode_receipt(principal_id, authority_epoch, operation_id, row) do
    [_expected, _target, _capability, _kind, _a, _b, _profile, disposition, reason, revision] =
      row

    case {disposition, reason, revision} do
      {"held", nil, revision} when is_integer(revision) and revision >= 0 ->
        {:ok,
         %Receipt{
           principal_id: principal_id,
           authority_epoch: authority_epoch,
           operation_id: operation_id,
           disposition: :held,
           reason: reason,
           revision: revision
         }}

      {"rejected", reason, revision}
      when is_binary(reason) and is_integer(revision) and revision >= 0 ->
        {:ok,
         %Receipt{
           principal_id: principal_id,
           authority_epoch: authority_epoch,
           operation_id: operation_id,
           disposition: :rejected,
           reason: reason,
           revision: revision
         }}

      {state, reason, revision}
      when is_binary(state) and (is_nil(reason) or is_binary(reason)) and
             is_integer(revision) and revision >= 0 ->
        case Map.fetch(@execution_dispositions, state) do
          {:ok, value} ->
            {:ok,
             %Receipt{
               principal_id: principal_id,
               authority_epoch: authority_epoch,
               operation_id: operation_id,
               disposition: value,
               reason: reason,
               revision: revision
             }}

          :error ->
            {:error, :corrupt_receipt}
        end

      _ ->
        {:error, :corrupt_receipt}
    end
  end

  defp valid_pair?(observation, capability) do
    Observation.valid?(observation, capability)
  end

  defp record_tx(db, observation, capability) do
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, observation.thing_id),
         {:ok, declared} <- Thing.capability(thing, observation.capability_key),
         true <- declared == capability,
         {:ok, rows} <-
           query(db, @select_current, [observation.thing_id, observation.capability_key]),
         :ok <- check_previous(db, rows, observation, capability),
         {:commit, result} <- insert_record(db, observation, capability),
         :ok <- maybe_consume_source_epoch_grant(db, rows, observation) do
      {:commit, result}
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      false -> {:rollback, {:policy, :capability_mismatch}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:duplicate, revision} -> {:rollback, {:duplicate, revision}}
      {:reject, reason} -> {:rollback, {:policy, reason}}
      {:rollback, reason} -> {:rollback, reason}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp valid_record_batch(thing, observations)
       when is_list(observations) and length(observations) in 1..32 do
    with {:ok, _document} <- Registry.encode_thing(thing),
         true <-
           Enum.all?(observations, fn
             %Observation{thing_id: id} -> id == thing.id
             _ -> false
           end),
         true <-
           observations
           |> Enum.map(& &1.capability_key)
           |> then(&(length(&1) == length(Enum.uniq(&1)))),
         true <- one_report_event?(observations) do
      Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, pairs} ->
        case Thing.capability(thing, observation.capability_key) do
          {:ok, capability} ->
            if Observation.valid?(observation, capability) do
              {:cont, {:ok, [{observation, capability} | pairs]}}
            else
              {:halt, {:error, :invalid_observation_batch}}
            end

          :error ->
            {:halt, {:error, :invalid_observation_batch}}
        end
      end)
      |> case do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        error -> error
      end
    else
      _ -> {:error, :invalid_observation_batch}
    end
  end

  defp valid_record_batch(_thing, _observations), do: {:error, :invalid_observation_batch}

  defp one_report_event?([first | rest]) do
    identity = report_event_identity(first)
    Enum.all?(rest, &(report_event_identity(&1) == identity))
  end

  defp report_event_identity(observation) do
    {observation.source_epoch, observation.source_sequence, observation.boot_epoch,
     observation.source_time_utc_ms, observation.received_time_utc_ms,
     observation.received_monotonic_ms, observation.quality, observation.trust}
  end

  defp record_batch_tx(db, pairs) do
    Enum.reduce_while(pairs, {[], 0, 0}, fn {observation, capability},
                                            {revisions, new_count, duplicate_count} ->
      case record_tx(db, observation, capability) do
        {:commit, {:ok, revision}} ->
          {:cont, {[revision | revisions], new_count + 1, duplicate_count}}

        {:rollback, {:duplicate, revision}} ->
          {:cont, {[revision | revisions], new_count, duplicate_count + 1}}

        {:rollback, reason} ->
          {:halt, {:rollback, reason}}
      end
    end)
    |> case do
      {revisions, new_count, 0} when new_count > 0 ->
        {:commit, {:ok, Enum.reverse(revisions)}}

      {revisions, 0, duplicate_count} when duplicate_count > 0 ->
        {:rollback, {:unchanged, {:duplicate, Enum.reverse(revisions)}}}

      {_revisions, _new_count, _duplicate_count} ->
        {:rollback, {:policy, :partial_batch_replay}}

      {:rollback, reason} ->
        {:rollback, reason}
    end
  end

  defp check_previous(_db, [], _observation, _capability), do: :ok

  defp check_previous(db, [row], observation, capability) do
    [profile_ref, evidence_ref, source_epoch, source_sequence | _rest] = row

    cond do
      profile_ref != capability.profile_ref or evidence_ref != capability.evidence_ref ->
        {:reject, :profile_changed}

      source_epoch != observation.source_epoch ->
        source_epoch_granted?(db, row, observation)

      source_sequence > observation.source_sequence ->
        {:reject, :stale_sequence}

      source_sequence == observation.source_sequence ->
        if same_source_event?(row, observation),
          do: {:duplicate, List.last(row)},
          else: {:reject, :sequence_conflict}

      true ->
        :ok
    end
  end

  defp source_epoch_granted?(db, row, observation) do
    source_epoch = Enum.at(row, 2)
    current_revision = List.last(row)

    case query(
           db,
           "SELECT grant_revision FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ? AND old_epoch = ? AND new_epoch = ? AND current_revision = ?",
           [
             observation.thing_id,
             observation.capability_key,
             source_epoch,
             observation.source_epoch,
             current_revision
           ]
         ) do
      {:ok, [[grant_revision]]} when is_integer(grant_revision) -> :ok
      {:ok, _} -> {:reject, :source_epoch_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_consume_source_epoch_grant(_db, [], _observation), do: :ok

  defp maybe_consume_source_epoch_grant(db, [row], observation) do
    if Enum.at(row, 2) == observation.source_epoch do
      :ok
    else
      with {:ok, []} <-
             query(
               db,
               "DELETE FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ? AND old_epoch = ? AND new_epoch = ? AND current_revision = ?",
               [
                 observation.thing_id,
                 observation.capability_key,
                 Enum.at(row, 2),
                 observation.source_epoch,
                 List.last(row)
               ]
             ),
           {:ok, [[1]]} <- query(db, "SELECT changes()") do
        :ok
      else
        _ -> {:error, :corrupt_source_epoch_grant}
      end
    end
  end

  defp same_source_event?(row, observation) do
    [_, _, _, _, _, source_time, _, _, quality, trust, kind, a, b, _] = row
    {new_kind, new_a, new_b} = encode_value(observation.value)

    source_time == observation.source_time_utc_ms and quality == observation.quality and
      trust == observation.trust and {kind, a, b} == {new_kind, new_a, new_b}
  end

  defp insert_record(db, observation, capability) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         new_revision = revision + 1,
         {kind, a, b} = encode_value(observation.value),
         params = fields(observation, capability, kind, a, b),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO journal VALUES (?, 'observation', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
             [new_revision | params]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO observation_current VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id, capability_key) DO UPDATE SET profile_ref=excluded.profile_ref, evidence_ref=excluded.evidence_ref, source_epoch=excluded.source_epoch, source_sequence=excluded.source_sequence, boot_epoch=excluded.boot_epoch, source_time_utc_ms=excluded.source_time_utc_ms, received_time_utc_ms=excluded.received_time_utc_ms, received_monotonic_ms=excluded.received_monotonic_ms, quality=excluded.quality, trust=excluded.trust, value_kind=excluded.value_kind, value_a=excluded.value_a, value_b=excluded.value_b, revision=excluded.revision",
             params ++ [new_revision]
           ),
         {:ok, []} <-
           query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [new_revision]) do
      {:commit, {:ok, new_revision}}
    else
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :unexpected_store_result}
    end
  end

  defp fields(observation, capability, kind, a, b) do
    [
      observation.thing_id,
      observation.capability_key,
      capability.profile_ref,
      capability.evidence_ref,
      observation.source_epoch,
      observation.source_sequence,
      observation.boot_epoch,
      observation.source_time_utc_ms,
      observation.received_time_utc_ms,
      observation.received_monotonic_ms,
      observation.quality,
      observation.trust,
      kind,
      a,
      b
    ]
  end

  defp encode_value(nil), do: {nil, nil, nil}

  defp encode_value(%Value{kind: :boolean, data: value}),
    do: {"boolean", if(value, do: "1", else: "0"), nil}

  defp encode_value(%Value{kind: :fraction, data: value}),
    do: {"fraction", Integer.to_string(value), nil}

  defp encode_value(%Value{kind: :kelvin, data: value}),
    do: {"kelvin", Integer.to_string(value), nil}

  defp encode_value(%Value{kind: :hsv, data: {hue, saturation}}),
    do: {"hsv", Integer.to_string(hue), Integer.to_string(saturation)}

  defp encode_value(%Value{kind: :xy, data: {x, y}}),
    do: {"xy", Integer.to_string(x), Integer.to_string(y)}

  defp encode_value(%Value{kind: :smoke_state, data: value}), do: {"smoke_state", value, nil}

  defp decode_current(thing_id, capability_key, row) do
    [
      profile_ref,
      evidence_ref,
      source_epoch,
      source_sequence,
      boot_epoch,
      source_time,
      received_time,
      received_mono,
      quality,
      trust,
      kind,
      a,
      b,
      revision
    ] = row

    with {:ok, value} <- decode_value(kind, a, b),
         true <-
           valid_persisted_observation?(
             thing_id,
             capability_key,
             source_epoch,
             source_sequence,
             boot_epoch,
             source_time,
             received_time,
             received_mono,
             quality,
             trust,
             value,
             revision
           ) do
      observation = %Observation{
        thing_id: thing_id,
        capability_key: capability_key,
        value: value,
        quality: quality,
        trust: trust,
        source_epoch: source_epoch,
        source_sequence: source_sequence,
        boot_epoch: boot_epoch,
        source_time_utc_ms: source_time,
        received_time_utc_ms: received_time,
        received_monotonic_ms: received_mono
      }

      # Profile/evidence identity is checked before each write and remains in
      # the row. The read API currently returns only the observation/revision.
      _ = {profile_ref, evidence_ref}
      {:ok, observation, revision}
    else
      _ -> {:error, :corrupt_value}
    end
  end

  defp valid_persisted_observation?(
         thing_id,
         capability_key,
         source_epoch,
         source_sequence,
         boot_epoch,
         source_time,
         received_time,
         received_mono,
         quality,
         trust,
         value,
         revision
       ) do
    Id.valid?(thing_id) and Id.valid?(capability_key) and Id.valid?(source_epoch) and
      Id.valid?(boot_epoch) and valid_stored_integer?(source_sequence) and
      (is_nil(source_time) or valid_stored_integer?(source_time)) and
      valid_stored_integer?(received_time) and valid_stored_integer?(received_mono) and
      valid_stored_integer?(revision) and quality in ["reported", "unknown"] and
      trust in [
        "unauthenticated_local",
        "authenticated_device",
        "bridge_attested",
        "synthetic_lab"
      ] and
      ((quality == "unknown" and is_nil(value)) or
         (quality == "reported" and match?(%Value{}, value) and Value.valid?(value)))
  end

  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64

  defp decode_value(nil, nil, nil), do: {:ok, nil}
  defp decode_value("boolean", "1", nil), do: {:ok, %Value{kind: :boolean, data: true}}
  defp decode_value("boolean", "0", nil), do: {:ok, %Value{kind: :boolean, data: false}}

  defp decode_value("smoke_state", value, nil) when value in ["clear", "alarm"],
    do: {:ok, %Value{kind: :smoke_state, data: value}}

  defp decode_value(kind, a, nil) when kind in ["fraction", "kelvin"] do
    case Integer.parse(a) do
      {value, ""} ->
        {:ok, %Value{kind: if(kind == "fraction", do: :fraction, else: :kelvin), data: value}}

      _ ->
        {:error, :corrupt_value}
    end
  end

  defp decode_value(kind, a, b) when kind in ["hsv", "xy"] do
    with {first, ""} <- Integer.parse(a),
         {second, ""} <- Integer.parse(b) do
      {:ok, %Value{kind: if(kind == "hsv", do: :hsv, else: :xy), data: {first, second}}}
    else
      _ -> {:error, :corrupt_value}
    end
  end

  defp decode_value(_kind, _a, _b), do: {:error, :corrupt_value}

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

  defp initialize_schema(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[0]]} ->
        with :ok <- Sqlite3.execute(db, @schema),
             :ok <- Sqlite3.execute(db, @request_schema),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4"),
             :ok <- migrate_execution_schema(db),
             :ok <- migrate_binding_schema(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[1]]} ->
        with :ok <- validate_observation_schema(db),
             :ok <- Sqlite3.execute(db, @request_schema),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4"),
             :ok <- migrate_execution_schema(db),
             :ok <- migrate_binding_schema(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[2]]} ->
        with :ok <- validate_request_schema(db),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4"),
             :ok <- migrate_execution_schema(db),
             :ok <- migrate_binding_schema(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[3]]} ->
        with :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4"),
             :ok <- migrate_execution_schema(db),
             :ok <- migrate_binding_schema(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[4]]} ->
        with :ok <- validate_schema_v4(db),
             :ok <- migrate_execution_schema(db),
             :ok <- migrate_binding_schema(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[5]]} ->
        with :ok <- validate_schema_v5(db),
             :ok <- migrate_binding_schema(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[6]]} ->
        with :ok <- validate_schema_v6(db),
             :ok <- migrate_review_schema(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[7]]} ->
        with :ok <- validate_schema_v7(db),
             :ok <- migrate_qualification_schema(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[8]]} ->
        with :ok <- validate_schema_v8(db),
             :ok <- migrate_rule_generation_schema(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[9]]} ->
        with :ok <- validate_schema_v9(db),
             :ok <- migrate_override_schema(db) do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[10]]} ->
        validate_schema(db)

      {:ok, [[_other]]} ->
        {:error, :unsupported_schema_version}

      other ->
        {:error, {:schema_failed, other}}
    end
  end

  defp migrate_execution_schema(db) do
    with :ok <- Sqlite3.execute(db, "PRAGMA foreign_keys=OFF"),
         {:ok, [[0]]} <- query(db, "PRAGMA foreign_keys"),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @receipt_v5_schema),
             :ok <- Sqlite3.execute(db, @execution_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=5"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          :ok
        else
          other -> {:error, {:migration_failed, other}}
        end

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      enabled = Sqlite3.execute(db, "PRAGMA foreign_keys=ON")

      with :ok <- result,
           :ok <- enabled,
           {:ok, [[1]]} <- query(db, "PRAGMA foreign_keys") do
        :ok
      else
        other -> {:error, {:migration_failed, other}}
      end
    else
      other -> {:error, {:migration_failed, other}}
    end
  end

  defp migrate_binding_schema(db) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @enrollment_binding_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=6"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          :ok
        else
          other -> {:error, {:migration_failed, other}}
        end

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      other -> {:error, {:migration_failed, other}}
    end
  end

  defp migrate_review_schema(db) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @enrollment_review_v7_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=7"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          :ok
        else
          other -> {:error, {:migration_failed, other}}
        end

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      other -> {:error, {:migration_failed, other}}
    end
  end

  defp migrate_qualification_schema(db) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @qualification_v8_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=8"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          :ok
        else
          other -> {:error, {:migration_failed, other}}
        end

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      other -> {:error, {:migration_failed, other}}
    end
  end

  defp migrate_rule_generation_schema(db) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @rule_generation_v9_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=9"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          :ok
        else
          other -> {:error, {:migration_failed, other}}
        end

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      other -> {:error, {:migration_failed, other}}
    end
  end

  defp migrate_override_schema(db) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @override_v10_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=10"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          :ok
        else
          other -> {:error, {:migration_failed, other}}
        end

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      other -> {:error, {:migration_failed, other}}
    end
  end

  @doc "Read-only Store consistency check for an already version-matched SQLite snapshot."
  @spec validate_snapshot(Sqlite3.db()) :: :ok | {:error, atom() | tuple()}
  def validate_snapshot(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[4]]} -> validate_schema_v4(db)
      {:ok, [[5]]} -> validate_schema_v5(db)
      {:ok, [[6]]} -> validate_schema_v6(db)
      {:ok, [[7]]} -> validate_schema_v7(db)
      {:ok, [[8]]} -> validate_schema_v8(db)
      {:ok, [[9]]} -> validate_schema_v9(db)
      {:ok, [[10]]} -> validate_schema(db)
      _ -> {:error, :unsupported_schema_version}
    end
  end

  defp validate_schema(db) do
    with :ok <- validate_schema_v9(db),
         :ok <- validate_override_leases(db) do
      :ok
    end
  end

  defp validate_schema_v9(db) do
    with :ok <- validate_schema_v8(db),
         :ok <- validate_rule_generation(db) do
      :ok
    end
  end

  defp validate_schema_v8(db) do
    with :ok <- validate_schema_v7(db),
         :ok <- validate_profile_qualifications(db),
         :ok <- validate_unresolved_effect_domains(db) do
      :ok
    end
  end

  defp validate_override_leases(db) do
    with {:ok, [[store_revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, rows} <-
           query(
             db,
             "SELECT l.target_id, l.operator_id, l.authority_epoch, l.boot_epoch, l.start_ms, l.expires_ms, l.basis_revision, l.revision, a.revision, t.resource_revision, p.principal_id FROM operator_override_leases l LEFT JOIN authority_journal a ON a.revision = l.revision AND a.event_type = 'override_lease_issued' AND a.entity_id = l.target_id LEFT JOIN enrolled_things t ON t.thing_id = l.target_id LEFT JOIN principals p ON p.principal_id = l.operator_id ORDER BY l.target_id LIMIT 4097"
           ),
         true <- length(rows) <= 4_096,
         true <-
           Enum.all?(rows, fn
             [
               target_id,
               operator_id,
               epoch,
               boot_epoch,
               start_ms,
               expires_ms,
               basis_revision,
               revision,
               journal_revision,
               resource_revision,
               principal_id
             ] ->
               principal_id == operator_id and Id.valid?(boot_epoch) and
                 valid_stored_integer?(revision) and revision >= 1 and
                 revision <= store_revision and journal_revision == revision and
                 valid_stored_integer?(resource_revision) and
                 basis_revision <= resource_revision and
                 match?(
                   {:ok, _},
                   OverrideLease.new(%{
                     "target_id" => target_id,
                     "operator_id" => operator_id,
                     "authority_epoch" => epoch,
                     "start_ms" => start_ms,
                     "expires_ms" => expires_ms,
                     "basis_revision" => basis_revision
                   })
                 )

             _ ->
               false
           end),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_rule_generation(db) do
    with {:ok, [[generation]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'rule_generation'"),
         {:ok, [[fence_count]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE event_type = 'rule_generation_fenced'"
           ),
         {:ok, [[stale_execution]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_execution WHERE rule_generation > ? OR (state IN ('queued', 'claimed') AND rule_generation != ?)",
             [generation, generation]
           ),
         true <-
           is_integer(generation) and generation >= 0 and generation <= @max_i64 and
             generation == fence_count and stale_execution == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_unresolved_effect_domains(db) do
    case query(
           db,
           "SELECT COUNT(*) FROM (SELECT effect_domain FROM request_execution WHERE state IN ('queued', 'claimed', 'dispatching', 'protocol_accepted', 'outcome_unknown') GROUP BY effect_domain HAVING COUNT(*) > 1)"
         ) do
      {:ok, [[0]]} -> :ok
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v7(db) do
    with :ok <- validate_schema_v5(db),
         :ok <- validate_enrollment_reviews(db) do
      :ok
    end
  end

  defp validate_profile_qualifications(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[invalid]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_qualifications q LEFT JOIN enrollment_bindings b ON b.thing_id = q.thing_id LEFT JOIN enrolled_things t ON t.thing_id = q.thing_id LEFT JOIN authority_journal a ON a.revision = q.revision AND a.event_type = 'profile_qualified' AND a.entity_id = q.thing_id WHERE b.thing_id IS NULL OR t.thing_id IS NULL OR a.revision IS NULL OR q.profile_ref != t.profile_ref OR q.resource_revision > t.resource_revision OR q.revision < 1 OR q.revision > ? OR length(q.identity_digest) != 64 OR q.identity_digest GLOB '*[^0-9a-f]*' OR length(q.basis_digest) != 64 OR q.basis_digest GLOB '*[^0-9a-f]*' OR length(q.registry_digest) != 64 OR q.registry_digest GLOB '*[^0-9a-f]*' OR length(q.runtime_digest) != 64 OR q.runtime_digest GLOB '*[^0-9a-f]*' OR length(q.evidence_ref) NOT BETWEEN 1 AND 128",
             [revision]
           ),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <- invalid == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v6(db) do
    with :ok <- validate_schema_v5(db),
         :ok <- validate_enrollment_bindings(db) do
      :ok
    end
  end

  defp validate_enrollment_reviews(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[invalid_bindings]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_bindings b LEFT JOIN enrolled_things t ON t.thing_id = b.thing_id LEFT JOIN principals p ON p.principal_id = b.operator_id LEFT JOIN enrollment_review_history h ON h.revision = b.revision AND h.thing_id = b.thing_id LEFT JOIN authority_journal a ON a.revision = b.revision AND a.entity_id = b.thing_id WHERE t.thing_id IS NULL OR p.principal_id IS NULL OR h.revision IS NULL OR a.revision IS NULL OR a.event_type NOT IN ('thing_enrolled_reviewed', 'thing_enrollment_rereviewed') OR b.profile_ref != t.profile_ref OR b.stable_id != h.stable_id OR b.identity_digest != h.identity_digest OR b.digest_version != h.digest_version OR b.candidate_ref != h.candidate_ref OR b.review_ref != h.review_ref OR b.method != h.method OR b.qualification_ref != h.qualification_ref OR b.operator_id != h.operator_id OR b.profile_ref != h.profile_ref OR b.revision < 1 OR b.revision > ?",
             [revision]
           ),
         {:ok, [[invalid_history]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_review_history h LEFT JOIN enrollment_bindings b ON b.thing_id = h.thing_id LEFT JOIN authority_journal a ON a.revision = h.revision AND a.entity_id = h.thing_id WHERE b.thing_id IS NULL OR a.revision IS NULL OR b.stable_id != h.stable_id OR b.profile_ref != h.profile_ref OR b.qualification_ref != h.qualification_ref OR b.operator_id != h.operator_id OR a.event_type NOT IN ('thing_enrolled_reviewed', 'thing_enrollment_rereviewed') OR h.revision < 1 OR h.revision > ? OR length(h.identity_digest) != 64 OR h.identity_digest GLOB '*[^0-9a-f]*' OR (h.digest_version = 2 AND (h.manufacturer IS NULL OR h.model IS NULL OR h.firmware IS NULL)) OR (h.digest_version = 1 AND (h.manufacturer IS NOT NULL OR h.model IS NOT NULL OR h.firmware IS NOT NULL))",
             [revision]
           ),
         {:ok, [[missing_initial]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_bindings b WHERE NOT EXISTS (SELECT 1 FROM enrollment_review_history h JOIN authority_journal a ON a.revision = h.revision AND a.entity_id = h.thing_id AND a.event_type = 'thing_enrolled_reviewed' WHERE h.thing_id = b.thing_id)"
           ),
         {:ok, [[overfull_history]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM (SELECT thing_id FROM enrollment_review_history GROUP BY thing_id HAVING COUNT(*) > 32)"
           ),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <-
           invalid_bindings == 0 and invalid_history == 0 and missing_initial == 0 and
             overfull_history == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v5(db) do
    with :ok <- validate_schema_v4(db),
         :ok <- validate_execution_schema(db) do
      :ok
    end
  end

  defp validate_enrollment_bindings(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[invalid]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM enrollment_bindings b LEFT JOIN enrolled_things t ON t.thing_id = b.thing_id LEFT JOIN principals p ON p.principal_id = b.operator_id LEFT JOIN authority_journal a ON a.revision = b.revision AND a.event_type = 'thing_enrolled_reviewed' AND a.entity_id = b.thing_id WHERE t.thing_id IS NULL OR p.principal_id IS NULL OR a.revision IS NULL OR b.profile_ref != t.profile_ref OR b.revision < 1 OR b.revision > ? OR length(b.stable_id) NOT BETWEEN 1 AND 128 OR length(b.candidate_ref) NOT BETWEEN 1 AND 128 OR length(b.review_ref) NOT BETWEEN 1 AND 128 OR length(b.qualification_ref) NOT BETWEEN 1 AND 128 OR length(b.identity_digest) != 64 OR b.identity_digest GLOB '*[^0-9a-f]*'",
             [revision]
           ),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <- invalid == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_schema_v4(db) do
    with :ok <- validate_observation_schema_tables(db),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[observation_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM journal"),
         {:ok, [[request_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_journal"),
         {:ok, [[authority_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM authority_journal"),
         {:ok, [[latest_receipt]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_receipts"),
         {:ok, [[latest_current]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current"),
         {:ok, [[_held_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox"),
         {:ok, [[orphan_held]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_receipts r WHERE r.disposition = 'held' AND NOT EXISTS (SELECT 1 FROM request_outbox o WHERE o.principal_id = r.principal_id AND o.authority_epoch = r.authority_epoch AND o.operation_id = r.operation_id AND o.state = 'held')"
           ),
         {:ok, [[orphan_outbox]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE r.disposition != 'held'"
           ),
         {:ok, [[_enrolled_count]]} <- query(db, "SELECT COUNT(*) FROM enrolled_things"),
         {:ok, [[_principal_count]]} <- query(db, "SELECT COUNT(*) FROM principals"),
         {:ok, [[_source_epoch_grant_count]]} <-
           query(db, "SELECT COUNT(*) FROM source_epoch_grants"),
         {:ok, [[invalid_source_epoch_grants]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM source_epoch_grants g LEFT JOIN enrolled_things t ON t.thing_id = g.thing_id WHERE g.old_epoch = g.new_epoch OR g.current_revision < 0 OR g.grant_revision <= g.current_revision OR g.grant_revision > ? OR t.status IS NULL OR t.status != 'active'",
             [revision]
           ),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <-
           is_integer(epoch) and epoch >= 1 and is_integer(revision) and
             revision == Enum.max([observation_revision, request_revision, authority_revision]) and
             latest_receipt <= revision and latest_current <= revision and orphan_held == 0 and
             orphan_outbox == 0 and invalid_source_epoch_grants == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_execution_schema(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[orphan_receipts]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_receipts r WHERE r.disposition NOT IN ('held', 'rejected') AND NOT EXISTS (SELECT 1 FROM request_execution e WHERE e.principal_id = r.principal_id AND e.authority_epoch = r.authority_epoch AND e.operation_id = r.operation_id)"
           ),
         {:ok, [[invalid_execution]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_execution e LEFT JOIN request_receipts r ON r.principal_id = e.principal_id AND r.authority_epoch = e.authority_epoch AND r.operation_id = e.operation_id LEFT JOIN request_outbox o ON o.principal_id = e.principal_id AND o.authority_epoch = e.authority_epoch AND o.operation_id = e.operation_id WHERE r.disposition IS NULL OR r.disposition != e.state OR r.target_id != e.target_id OR r.profile_ref != e.profile_ref OR e.effect_domain != e.target_id OR e.revision != r.revision OR e.revision > ? OR e.baseline_revision > e.revision OR o.state IS NOT NULL OR (e.state = 'queued' AND (e.claim_token IS NOT NULL OR e.claim_boot_epoch IS NOT NULL OR e.handoff_revision IS NOT NULL)) OR (e.state = 'claimed' AND (typeof(e.claim_token) != 'blob' OR length(e.claim_token) != 32 OR e.claim_boot_epoch IS NULL OR e.claim_boot_epoch = '' OR e.handoff_revision IS NOT NULL OR e.attempts < 1)) OR (e.state IN ('dispatching', 'protocol_accepted', 'observed', 'contradicted', 'failed', 'outcome_unknown') AND (typeof(e.claim_token) != 'blob' OR length(e.claim_token) != 32 OR e.claim_boot_epoch IS NULL OR e.claim_boot_epoch = '' OR e.handoff_revision IS NULL OR e.handoff_revision < 1 OR e.handoff_revision > e.revision OR e.attempts < 1))",
             [revision]
           ),
         true <- orphan_receipts == 0 and invalid_execution == 0 do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_request_schema(db) do
    with :ok <- validate_observation_schema_tables(db),
         {:ok, [[_receipt_count]]} <- query(db, "SELECT COUNT(*) FROM request_receipts"),
         {:ok, [[_outbox_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox"),
         {:ok, [[_request_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_journal") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_observation_schema(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[latest_event]]} <- query(db, "SELECT COALESCE(MAX(revision), 0) FROM journal"),
         {:ok, [[latest_current]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current"),
         true <- is_integer(revision) and revision == latest_event and latest_current <= revision do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_observation_schema_tables(db) do
    case query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current") do
      {:ok, [[_latest_current]]} -> :ok
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp integrity(db) do
    case query(db, "PRAGMA quick_check") do
      {:ok, [["ok"]]} -> :ok
      other -> {:error, {:integrity_failed, other}}
    end
  end

  defp transaction(db, fun) do
    case Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      :ok ->
        case fun.(db) do
          {:commit, result} ->
            case Sqlite3.execute(db, "COMMIT") do
              :ok ->
                {:ok, result}

              {:error, reason} ->
                _ = Sqlite3.execute(db, "ROLLBACK")
                {:error, reason}
            end

          {:rollback, {:duplicate, _} = duplicate} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:ok, duplicate}

          {:rollback, {:unchanged, result}} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:ok, result}

          {:rollback, reason} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(db, sql, params \\ []) do
    case Sqlite3.prepare(db, sql) do
      {:ok, statement} ->
        try do
          with :ok <- Sqlite3.bind(statement, params),
               {:ok, rows} <- Sqlite3.fetch_all(db, statement) do
            {:ok, rows}
          end
        after
          _ = Sqlite3.release(db, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
