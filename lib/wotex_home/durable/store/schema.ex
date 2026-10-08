defmodule WotexHome.Durable.Store.Schema do
  @moduledoc """
  Stateless schema bootstrap and migration sequencing for the single Store.

  This module never opens, closes or retains a database. The Store owner calls
  it synchronously with its live SQLite handle and supplies the semantic
  validator for each historical version. DDL ownership is therefore separate
  from application transactions without creating another writer or lifecycle.
  """

  alias Exqlite.Sqlite3

  import WotexHome.Durable.Store.SQL, only: [query: 2]

  @current_version 27

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

  @override_operations_v11_schema """
  CREATE TABLE operator_override_operations (
    operator_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    operation_id TEXT NOT NULL,
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    basis_revision INTEGER NOT NULL CHECK (basis_revision >= 0),
    duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 1 AND 86400000),
    start_ms INTEGER NOT NULL CHECK (start_ms >= 0),
    expires_ms INTEGER NOT NULL CHECK (expires_ms > start_ms),
    issue_revision INTEGER NOT NULL UNIQUE CHECK (issue_revision >= 1),
    revoke_revision INTEGER UNIQUE CHECK (revoke_revision > issue_revision),
    PRIMARY KEY (operator_id, authority_epoch, operation_id),
    CHECK (expires_ms - start_ms = duration_ms)
  );
  """

  @candidate_v12_schema """
  CREATE TABLE rule_candidate_reviews (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
    rules_document TEXT NOT NULL CHECK (length(CAST(rules_document AS BLOB)) <= 65536),
    artifact_document TEXT NOT NULL CHECK (length(CAST(artifact_document AS BLOB)) <= 4194304),
    artifact_digest TEXT NOT NULL CHECK (length(artifact_digest) = 64),
    revision INTEGER NOT NULL UNIQUE CHECK (revision = expected_revision + 1),
    PRIMARY KEY (principal_id, authority_epoch, operation_id)
  );
  """

  @handoff_clock_v13_schema """
  ALTER TABLE request_execution ADD COLUMN handoff_store_boot_epoch TEXT
    CHECK (handoff_store_boot_epoch IS NULL OR
      (typeof(handoff_store_boot_epoch) = 'text' AND
       length(CAST(handoff_store_boot_epoch AS BLOB)) BETWEEN 1 AND 128));
  ALTER TABLE request_execution ADD COLUMN handoff_store_monotonic_ms INTEGER
    CHECK (handoff_store_monotonic_ms IS NULL OR
      (typeof(handoff_store_monotonic_ms) = 'integer' AND handoff_store_monotonic_ms >= 0));
  CREATE INDEX power_handoff_time ON request_execution
    (handoff_revision, handoff_store_boot_epoch, effect_domain, handoff_store_monotonic_ms);
  """

  @causal_roots_v14_schema """
  CREATE INDEX request_journal_cause ON request_journal
    (principal_id, authority_epoch, operation_id, disposition, revision);
  CREATE TABLE request_causal_roots (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('explicit_request', 'legacy_request')),
    created_revision INTEGER,
    reserved_effects INTEGER NOT NULL CHECK
      (typeof(reserved_effects) = 'integer' AND reserved_effects IN (0, 1)),
    reservation_revision INTEGER,
    PRIMARY KEY (principal_id, authority_epoch, operation_id),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES request_receipts(principal_id, authority_epoch, operation_id),
    CHECK ((origin = 'explicit_request' AND typeof(created_revision) = 'integer'
            AND created_revision >= 1) OR
           (origin = 'legacy_request' AND created_revision IS NULL)),
    CHECK ((reserved_effects = 0 AND reservation_revision IS NULL) OR
           (reserved_effects = 1 AND
             ((typeof(reservation_revision) = 'integer' AND reservation_revision >= 1) OR
              (origin = 'legacy_request' AND reservation_revision IS NULL))))
  );
  INSERT INTO request_causal_roots
    SELECT r.principal_id, r.authority_epoch, r.operation_id, 'legacy_request', NULL,
      CASE WHEN EXISTS (SELECT 1 FROM request_execution e
        WHERE e.principal_id=r.principal_id AND e.authority_epoch=r.authority_epoch
          AND e.operation_id=r.operation_id)
        OR EXISTS (SELECT 1 FROM request_journal j
          WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
            AND j.operation_id=r.operation_id AND j.disposition='queued')
        THEN 1 ELSE 0 END,
      (SELECT CASE WHEN COUNT(*)=1 THEN MIN(j.revision) ELSE NULL END FROM request_journal j
        WHERE j.principal_id=r.principal_id AND j.authority_epoch=r.authority_epoch
          AND j.operation_id=r.operation_id AND j.disposition='queued')
    FROM request_receipts r;
  """

  @observation_clock_v15_schema """
  ALTER TABLE journal ADD COLUMN received_store_boot_epoch TEXT
    CHECK (received_store_boot_epoch IS NULL OR typeof(received_store_boot_epoch) = 'text');
  ALTER TABLE journal ADD COLUMN received_store_monotonic_ms INTEGER
    CHECK ((received_store_boot_epoch IS NULL AND received_store_monotonic_ms IS NULL) OR
      (received_store_boot_epoch IS NOT NULL AND typeof(received_store_monotonic_ms) = 'integer'
        AND received_store_monotonic_ms >= 0));
  ALTER TABLE observation_current ADD COLUMN received_store_boot_epoch TEXT
    CHECK (received_store_boot_epoch IS NULL OR typeof(received_store_boot_epoch) = 'text');
  ALTER TABLE observation_current ADD COLUMN received_store_monotonic_ms INTEGER
    CHECK ((received_store_boot_epoch IS NULL AND received_store_monotonic_ms IS NULL) OR
      (received_store_boot_epoch IS NOT NULL AND typeof(received_store_monotonic_ms) = 'integer'
        AND received_store_monotonic_ms >= 0));
  CREATE INDEX observation_receipt_time ON journal (received_store_boot_epoch, revision);
  """

  @invariant_v16_schema """
  CREATE TABLE invariant_policy_operations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    previous_revision INTEGER NOT NULL CHECK (previous_revision >= 0),
    source_document TEXT NOT NULL CHECK (length(source_document) BETWEEN 1 AND 65536),
    artifact_document TEXT NOT NULL CHECK (length(artifact_document) BETWEEN 1 AND 4194304),
    artifact_digest TEXT NOT NULL CHECK (length(artifact_digest) = 64),
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    UNIQUE (principal_id, authority_epoch, operation_id)
  );
  CREATE INDEX invariant_policy_target ON invariant_policy_operations(target_id, revision);
  """

  @rule_v17_schema """
  INSERT INTO meta(key, value) VALUES ('active_rule_admission', 0);
  CREATE TABLE rule_admissions (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
    source_document TEXT NOT NULL,
    artifact_document TEXT NOT NULL,
    artifact_digest TEXT NOT NULL,
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    UNIQUE (principal_id, authority_epoch, operation_id)
  );
  CREATE TABLE rule_activations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
    admission_revision INTEGER NOT NULL CHECK (admission_revision >= 0),
    previous_generation INTEGER NOT NULL CHECK (previous_generation >= 0),
    generation INTEGER NOT NULL CHECK (generation >= 1),
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    final_revision INTEGER NOT NULL CHECK (final_revision >= revision),
    affected_requests INTEGER NOT NULL CHECK (affected_requests BETWEEN 0 AND 1024),
    unknown_outcomes INTEGER NOT NULL CHECK (unknown_outcomes BETWEEN 0 AND affected_requests),
    UNIQUE (principal_id, authority_epoch, operation_id),
    UNIQUE (generation)
  );
  CREATE TABLE request_rule_origins (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    admission_revision INTEGER NOT NULL REFERENCES rule_admissions(revision),
    rule_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 1),
    receipt_revision INTEGER NOT NULL UNIQUE REFERENCES request_journal(revision),
    PRIMARY KEY (principal_id, authority_epoch, operation_id),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES request_receipts(principal_id, authority_epoch, operation_id)
  );
  ALTER TABLE request_causal_roots ADD COLUMN rule_admission_revision INTEGER
    REFERENCES rule_admissions(revision) CHECK (rule_admission_revision IS NULL OR rule_admission_revision > 0);
  ALTER TABLE request_causal_roots ADD COLUMN rule_generation INTEGER
    CHECK ((rule_admission_revision IS NULL AND rule_generation IS NULL) OR
      (rule_admission_revision IS NOT NULL AND typeof(rule_generation)='integer' AND rule_generation > 0));
  """

  @maintenance_v18_schema """
  INSERT INTO meta(key, value) VALUES ('maintenance_revision', 0);
  CREATE TABLE host_maintenance_operations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
    operation_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('begin', 'end')),
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
    begin_revision INTEGER NOT NULL CHECK (begin_revision >= 0),
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    fence_revision INTEGER NOT NULL CHECK (fence_revision >= 0),
    rule_generation INTEGER NOT NULL CHECK (rule_generation >= 0),
    affected_requests INTEGER NOT NULL CHECK (affected_requests BETWEEN 0 AND 1024),
    unknown_outcomes INTEGER NOT NULL CHECK (unknown_outcomes BETWEEN 0 AND affected_requests),
    UNIQUE (principal_id, authority_epoch, operation_id)
  );
  """

  @profile_v19_schema """
  INSERT INTO meta(key, value) VALUES ('profile_policy_generation', 0);
  CREATE TABLE portable_profiles (
    artifact_digest TEXT PRIMARY KEY CHECK (length(artifact_digest)=64),
    id TEXT NOT NULL,
    version TEXT NOT NULL,
    metadata_document TEXT NOT NULL CHECK (length(metadata_document) BETWEEN 1 AND 32768),
    projection_document TEXT NOT NULL CHECK (length(projection_document) BETWEEN 1 AND 4096),
    projection_digest TEXT NOT NULL CHECK (length(projection_digest)=64),
    binding TEXT NOT NULL CHECK (binding='lifx-direct-power-v1'),
    registry_digest TEXT NOT NULL CHECK (length(registry_digest)=64),
    first_approval_revision INTEGER NOT NULL REFERENCES profile_operations(final_revision)
      DEFERRABLE INITIALLY DEFERRED,
    UNIQUE (id, version)
  );
  CREATE TABLE profile_operations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('approve','revoke','select','revoke_selection')),
    input_document TEXT NOT NULL CHECK (length(input_document) BETWEEN 1 AND 4096),
    input_digest TEXT NOT NULL CHECK (length(input_digest)=64),
    expected_revision INTEGER NOT NULL CHECK (expected_revision>=0),
    artifact_digest TEXT NOT NULL REFERENCES portable_profiles(artifact_digest),
    final_revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    changed_targets INTEGER NOT NULL CHECK (changed_targets BETWEEN 0 AND 64),
    invalidated_requests INTEGER NOT NULL CHECK (invalidated_requests BETWEEN 0 AND 1024),
    unknown_outcomes INTEGER NOT NULL CHECK (unknown_outcomes BETWEEN 0 AND invalidated_requests),
    previous_trust_revision INTEGER NOT NULL CHECK (previous_trust_revision>=0),
    trust_generation INTEGER NOT NULL CHECK (trust_generation>=1),
    policy_generation INTEGER NOT NULL CHECK (policy_generation>=1),
    PRIMARY KEY (principal_id, authority_epoch, operation_id)
  );
  CREATE INDEX profile_trust_history ON profile_operations(artifact_digest, final_revision);
  CREATE TABLE profile_selection_history (
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    generation INTEGER NOT NULL CHECK (generation>=1),
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    previous_selection_revision INTEGER NOT NULL CHECK (previous_selection_revision>=0),
    previous_resource_revision INTEGER NOT NULL CHECK (previous_resource_revision>=0),
    previous_binding_revision INTEGER NOT NULL CHECK (previous_binding_revision>=0),
    artifact_digest TEXT NOT NULL REFERENCES portable_profiles(artifact_digest),
    projection_digest TEXT NOT NULL CHECK (length(projection_digest)=64),
    trust_revision INTEGER NOT NULL REFERENCES profile_operations(final_revision),
    state TEXT NOT NULL CHECK (state IN ('selected','revoked')),
    resource_revision INTEGER NOT NULL CHECK (resource_revision>=1),
    binding_revision INTEGER NOT NULL REFERENCES enrollment_review_history(revision),
    runtime_digest TEXT NOT NULL CHECK (length(runtime_digest)=64),
    review_document TEXT NOT NULL CHECK (length(review_document)<=65536),
    thing_document TEXT NOT NULL CHECK (length(thing_document) BETWEEN 1 AND 65536),
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    UNIQUE (target_id, generation),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES profile_operations(principal_id, authority_epoch, operation_id)
      DEFERRABLE INITIALLY DEFERRED
  );
  CREATE TABLE profile_current (
    target_id TEXT PRIMARY KEY REFERENCES enrolled_things(thing_id),
    generation INTEGER NOT NULL CHECK (generation>=1),
    selection_revision INTEGER NOT NULL UNIQUE REFERENCES profile_selection_history(revision),
    state TEXT NOT NULL CHECK (state IN ('selected','revoked'))
  );
  CREATE TABLE profile_observation_pins (
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    owner_revision INTEGER PRIMARY KEY REFERENCES journal(revision),
    artifact_digest TEXT NOT NULL REFERENCES portable_profiles(artifact_digest),
    projection_digest TEXT NOT NULL CHECK (length(projection_digest)=64),
    selection_revision INTEGER NOT NULL REFERENCES profile_selection_history(revision),
    selection_generation INTEGER NOT NULL CHECK (selection_generation>=1),
    trust_revision INTEGER NOT NULL REFERENCES profile_operations(final_revision),
    resource_revision INTEGER NOT NULL CHECK (resource_revision>=0)
  );
  CREATE TABLE profile_request_pins (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    owner_revision INTEGER NOT NULL UNIQUE REFERENCES request_journal(revision),
    artifact_digest TEXT NOT NULL REFERENCES portable_profiles(artifact_digest),
    projection_digest TEXT NOT NULL CHECK (length(projection_digest)=64),
    selection_revision INTEGER NOT NULL REFERENCES profile_selection_history(revision),
    selection_generation INTEGER NOT NULL CHECK (selection_generation>=1),
    trust_revision INTEGER NOT NULL REFERENCES profile_operations(final_revision),
    resource_revision INTEGER NOT NULL CHECK (resource_revision>=0),
    PRIMARY KEY (principal_id, authority_epoch, operation_id),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES request_receipts(principal_id, authority_epoch, operation_id)
  );
  CREATE TABLE profile_rule_pins (
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    owner_revision INTEGER NOT NULL REFERENCES rule_admissions(revision),
    artifact_digest TEXT NOT NULL REFERENCES portable_profiles(artifact_digest),
    projection_digest TEXT NOT NULL CHECK (length(projection_digest)=64),
    selection_revision INTEGER NOT NULL REFERENCES profile_selection_history(revision),
    selection_generation INTEGER NOT NULL CHECK (selection_generation>=1),
    trust_revision INTEGER NOT NULL REFERENCES profile_operations(final_revision),
    resource_revision INTEGER NOT NULL CHECK (resource_revision>=0),
    PRIMARY KEY (owner_revision, target_id)
  );
  CREATE TABLE profile_qualification_pins (
    target_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    owner_revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    artifact_digest TEXT NOT NULL REFERENCES portable_profiles(artifact_digest),
    projection_digest TEXT NOT NULL CHECK (length(projection_digest)=64),
    selection_revision INTEGER NOT NULL REFERENCES profile_selection_history(revision),
    selection_generation INTEGER NOT NULL CHECK (selection_generation>=1),
    trust_revision INTEGER NOT NULL REFERENCES profile_operations(final_revision),
    resource_revision INTEGER NOT NULL CHECK (resource_revision>=0)
  );
  """

  @qualification_history_v20_schema """
  INSERT INTO meta (key,value) SELECT 'qualification_history_migration_revision',value FROM meta WHERE key='revision';
  CREATE TABLE profile_qualification_history (
    thing_id TEXT NOT NULL REFERENCES enrolled_things(thing_id),
    profile_ref TEXT NOT NULL,
    resource_revision INTEGER NOT NULL CHECK (resource_revision>=0),
    identity_digest TEXT NOT NULL CHECK (length(identity_digest)=64),
    basis_digest TEXT NOT NULL CHECK (length(basis_digest)=64),
    registry_digest TEXT NOT NULL CHECK (length(registry_digest)=64),
    runtime_digest TEXT NOT NULL CHECK (length(runtime_digest)=64),
    evidence_ref TEXT NOT NULL UNIQUE,
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision) DEFERRABLE INITIALLY DEFERRED,
    provenance TEXT NOT NULL CHECK (provenance IN ('legacy_migrated','guarded_current')),
    declaration_document TEXT,
    principal_id TEXT REFERENCES principals(principal_id),
    authority_epoch INTEGER,
    binding_revision INTEGER REFERENCES enrollment_review_history(revision),
    CHECK ((provenance='legacy_migrated' AND declaration_document IS NULL AND principal_id IS NULL AND authority_epoch IS NULL AND binding_revision IS NULL) OR
      (provenance='guarded_current' AND declaration_document IS NOT NULL AND principal_id IS NOT NULL AND authority_epoch>=1 AND binding_revision>=1 AND binding_revision<revision))
  );
  INSERT INTO profile_qualification_history
    (thing_id,profile_ref,resource_revision,identity_digest,basis_digest,registry_digest,runtime_digest,evidence_ref,revision,provenance)
    SELECT thing_id,profile_ref,resource_revision,identity_digest,basis_digest,registry_digest,runtime_digest,evidence_ref,revision,'legacy_migrated' FROM profile_qualifications;
  """

  @controller_v21_schema """
  CREATE TABLE controller_identity (
    singleton INTEGER PRIMARY KEY CHECK (singleton=1),
    deployment_id TEXT NOT NULL CHECK (length(deployment_id)=64),
    origin_document TEXT NOT NULL CHECK (length(CAST(origin_document AS BLOB)) BETWEEN 1 AND 4096),
    owner_id TEXT NOT NULL CHECK (length(owner_id)=64),
    state TEXT NOT NULL CHECK (state IN ('active','retired')),
    head_revision INTEGER NOT NULL CHECK (head_revision>=0)
  );
  CREATE TABLE controller_retirements (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    input_document TEXT NOT NULL CHECK (length(CAST(input_document AS BLOB)) BETWEEN 1 AND 4096),
    receipt_document TEXT NOT NULL CHECK (length(CAST(receipt_document AS BLOB)) BETWEEN 1 AND 4096),
    revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    PRIMARY KEY (principal_id,authority_epoch,operation_id)
  );
  """

  @controller_v22_schema """
  CREATE TABLE controller_acceptances (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    source_epoch INTEGER NOT NULL CHECK (source_epoch>=1),
    operation_id TEXT NOT NULL,
    input_document TEXT NOT NULL CHECK (length(CAST(input_document AS BLOB)) BETWEEN 1 AND 4096),
    receipt_document TEXT NOT NULL CHECK (length(CAST(receipt_document AS BLOB)) BETWEEN 1 AND 4096),
    review_document TEXT NOT NULL CHECK (length(CAST(review_document AS BLOB)) BETWEEN 1 AND 4096),
    isolation_package TEXT NOT NULL CHECK (length(CAST(isolation_package AS BLOB)) BETWEEN 1 AND 8192),
    isolation_document TEXT NOT NULL CHECK (length(CAST(isolation_document AS BLOB)) BETWEEN 1 AND 8192),
    issuer_policy_document TEXT NOT NULL CHECK (length(CAST(issuer_policy_document AS BLOB)) BETWEEN 1 AND 4096),
    domain_document TEXT NOT NULL CHECK (length(CAST(domain_document AS BLOB)) BETWEEN 1 AND 4194304),
    revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    PRIMARY KEY (principal_id,source_epoch,operation_id)
  );
  ALTER TABLE host_maintenance_operations RENAME TO host_maintenance_previous;
  CREATE TABLE host_maintenance_operations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('begin','end','transfer')),
    expected_revision INTEGER NOT NULL CHECK (expected_revision>=0),
    begin_revision INTEGER NOT NULL CHECK (begin_revision>=0),
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    fence_revision INTEGER NOT NULL CHECK (fence_revision>=0),
    rule_generation INTEGER NOT NULL CHECK (rule_generation>=0),
    affected_requests INTEGER NOT NULL CHECK (affected_requests BETWEEN 0 AND 1024),
    unknown_outcomes INTEGER NOT NULL CHECK (unknown_outcomes BETWEEN 0 AND affected_requests),
    UNIQUE (principal_id,authority_epoch,operation_id)
  );
  INSERT INTO host_maintenance_operations SELECT * FROM host_maintenance_previous;
  DROP TABLE host_maintenance_previous;
  PRAGMA user_version=22;
  """

  @native_target_v23_schema """
  CREATE TABLE native_target_operations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('grant','revoke')),
    input_document TEXT NOT NULL CHECK (length(CAST(input_document AS BLOB)) BETWEEN 1 AND 4096),
    receipt_document TEXT NOT NULL CHECK (length(CAST(receipt_document AS BLOB)) BETWEEN 1 AND 4096),
    revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    PRIMARY KEY (principal_id,authority_epoch,operation_id)
  );
  PRAGMA user_version=23;
  """

  @schedule_v24_schema """
  CREATE TABLE schedule_admissions (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('review','admit')),
    expected_revision INTEGER NOT NULL CHECK (expected_revision>=0),
    input_document TEXT NOT NULL CHECK (length(CAST(input_document AS BLOB)) BETWEEN 1 AND 8192),
    artifact_document TEXT NOT NULL CHECK (length(CAST(artifact_document AS BLOB)) BETWEEN 1 AND 262144),
    artifact_digest TEXT NOT NULL CHECK (length(artifact_digest)=64),
    revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    PRIMARY KEY (principal_id,authority_epoch,operation_id)
  );
  PRAGMA user_version=24;
  """

  @schedule_v25_schema """
  CREATE TABLE schedule_lifecycle_operations (
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('activate','suspend','withdraw')),
    expected_revision INTEGER NOT NULL CHECK (expected_revision>=0),
    input_document TEXT NOT NULL CHECK (length(CAST(input_document AS BLOB)) BETWEEN 1 AND 8192),
    admission_revision INTEGER NOT NULL CHECK (admission_revision>=0),
    previous_generation INTEGER NOT NULL CHECK (previous_generation>=0),
    generation INTEGER NOT NULL CHECK (generation=previous_generation+1),
    barrier_revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    affected_requests INTEGER NOT NULL CHECK (affected_requests BETWEEN 0 AND 1024),
    unknown_outcomes INTEGER NOT NULL CHECK (unknown_outcomes BETWEEN 0 AND affected_requests),
    reason TEXT,
    clock_document TEXT CHECK (length(CAST(clock_document AS BLOB)) BETWEEN 1 AND 4096),
    initial_watermark INTEGER NOT NULL CHECK (initial_watermark>=-1),
    PRIMARY KEY (principal_id,authority_epoch,operation_id),
    CHECK ((kind='activate' AND admission_revision>0 AND reason IS NULL AND clock_document IS NOT NULL AND initial_watermark>=0) OR
           (kind='suspend' AND admission_revision=0 AND reason IS NULL AND clock_document IS NULL AND initial_watermark=-1) OR
           (kind='withdraw' AND admission_revision>0 AND reason IS NOT NULL AND clock_document IS NULL AND initial_watermark=-1))
  );
  PRAGMA user_version=25;
  """

  @schedule_v26_schema """
  CREATE TABLE schedule_considerations (
    activation_revision INTEGER NOT NULL REFERENCES schedule_lifecycle_operations(revision),
    previous_watermark INTEGER NOT NULL CHECK (previous_watermark>=0),
    watermark INTEGER NOT NULL CHECK (watermark>previous_watermark),
    clock_document TEXT NOT NULL CHECK (length(CAST(clock_document AS BLOB)) BETWEEN 1 AND 4096),
    decision TEXT NOT NULL CHECK (decision IN ('idle','eligible','uncertain','expired')),
    occurrence_document TEXT CHECK (length(CAST(occurrence_document AS BLOB)) BETWEEN 1 AND 4096),
    occurrence_id TEXT UNIQUE,
    causal_id TEXT UNIQUE,
    missed_lower INTEGER,
    missed_upper INTEGER,
    reason TEXT NOT NULL,
    revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
    CHECK ((occurrence_document IS NULL AND occurrence_id IS NULL AND causal_id IS NULL AND decision='idle') OR
           (occurrence_document IS NOT NULL AND occurrence_id IS NOT NULL AND causal_id IS NOT NULL AND decision!='idle')),
    CHECK ((missed_lower IS NULL AND missed_upper IS NULL) OR
           (missed_lower IS NOT NULL AND missed_upper IS NOT NULL AND missed_lower=previous_watermark AND missed_upper>missed_lower AND missed_upper<=watermark))
  );
  CREATE TABLE schedule_watermarks (
    activation_revision INTEGER PRIMARY KEY REFERENCES schedule_lifecycle_operations(revision),
    considered_through INTEGER NOT NULL CHECK (considered_through>=0),
    head_revision INTEGER NOT NULL UNIQUE REFERENCES schedule_considerations(revision)
  );
  PRAGMA user_version=26;
  """

  @schedule_v27_schema """
  CREATE TABLE request_causal_roots_temporal (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('explicit_request','legacy_request','schedule_occurrence')),
    created_revision INTEGER,
    reserved_effects INTEGER NOT NULL CHECK (typeof(reserved_effects)='integer' AND reserved_effects IN (0,1)),
    reservation_revision INTEGER,
    rule_admission_revision INTEGER REFERENCES rule_admissions(revision) CHECK (rule_admission_revision IS NULL OR rule_admission_revision>0),
    rule_generation INTEGER CHECK ((rule_admission_revision IS NULL AND rule_generation IS NULL) OR
      (rule_admission_revision IS NOT NULL AND typeof(rule_generation)='integer' AND rule_generation>0)),
    PRIMARY KEY (principal_id,authority_epoch,operation_id),
    FOREIGN KEY (principal_id,authority_epoch,operation_id) REFERENCES request_receipts(principal_id,authority_epoch,operation_id),
    CHECK ((origin IN ('explicit_request','schedule_occurrence') AND typeof(created_revision)='integer' AND created_revision>=1) OR
           (origin='legacy_request' AND created_revision IS NULL)),
    CHECK ((reserved_effects=0 AND reservation_revision IS NULL) OR
           (reserved_effects=1 AND ((typeof(reservation_revision)='integer' AND reservation_revision>=1) OR
             (origin='legacy_request' AND reservation_revision IS NULL))))
  );
  INSERT INTO request_causal_roots_temporal SELECT * FROM request_causal_roots;
  DROP TABLE request_causal_roots;
  ALTER TABLE request_causal_roots_temporal RENAME TO request_causal_roots;
  CREATE TABLE schedule_effect_operations (
    consideration_revision INTEGER PRIMARY KEY REFERENCES schedule_considerations(revision),
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    authority_epoch INTEGER NOT NULL CHECK (authority_epoch>=1),
    operation_id TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('held','blocked')),
    reason TEXT,
    request_revision INTEGER UNIQUE REFERENCES request_journal(revision),
    runtime_digest TEXT NOT NULL CHECK (length(runtime_digest)=64),
    revision INTEGER NOT NULL UNIQUE REFERENCES authority_journal(revision),
    UNIQUE (principal_id,authority_epoch,operation_id),
    CHECK ((decision='held' AND reason IS NULL AND request_revision IS NOT NULL) OR (decision='blocked' AND reason IS NOT NULL))
  );
  PRAGMA user_version=27;
  """

  @type validator :: (1..27, Sqlite3.db() -> :ok | {:error, term()})

  @doc "Initializes or migrates a Store and validates the final schema."
  @spec initialize(Sqlite3.db(), validator()) :: :ok | {:error, term()}
  def initialize(db, validator) when is_function(validator, 2) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[version]]} when version in 0..@current_version ->
        with {:ok, prepared_version} <- prepare(db, version, validator),
             :ok <- migrate_from(db, prepared_version) do
          validator.(@current_version, db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[_other]]} ->
        {:error, :unsupported_schema_version}

      other ->
        {:error, {:schema_failed, other}}
    end
  end

  defp prepare(db, 0, _validator) do
    with :ok <- Sqlite3.execute(db, @schema),
         :ok <- Sqlite3.execute(db, @request_schema),
         :ok <- Sqlite3.execute(db, @authority_schema),
         :ok <- Sqlite3.execute(db, @source_epoch_schema),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
      {:ok, 4}
    end
  end

  defp prepare(db, 1, validator) do
    with :ok <- validator.(1, db),
         :ok <- Sqlite3.execute(db, @request_schema),
         :ok <- Sqlite3.execute(db, @authority_schema),
         :ok <- Sqlite3.execute(db, @source_epoch_schema),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
      {:ok, 4}
    end
  end

  defp prepare(db, 2, validator) do
    with :ok <- validator.(2, db),
         :ok <- Sqlite3.execute(db, @authority_schema),
         :ok <- Sqlite3.execute(db, @source_epoch_schema),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
      {:ok, 4}
    end
  end

  defp prepare(db, 3, _validator) do
    with :ok <- Sqlite3.execute(db, @source_epoch_schema),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
      {:ok, 4}
    end
  end

  defp prepare(_db, @current_version, _validator), do: {:ok, @current_version}

  defp prepare(db, version, validator) when version in 4..26 do
    case validator.(version, db) do
      :ok -> {:ok, version}
      error -> error
    end
  end

  defp migrate_from(db, version) do
    with :ok <- maybe_migrate(db, version, 5, &migrate_execution/1),
         :ok <-
           maybe_migrate(db, version, 6, &migrate_standard(&1, @enrollment_binding_schema, 6)),
         :ok <-
           maybe_migrate(db, version, 7, &migrate_standard(&1, @enrollment_review_v7_schema, 7)),
         :ok <- maybe_migrate(db, version, 8, &migrate_standard(&1, @qualification_v8_schema, 8)),
         :ok <-
           maybe_migrate(db, version, 9, &migrate_standard(&1, @rule_generation_v9_schema, 9)),
         :ok <- maybe_migrate(db, version, 10, &migrate_standard(&1, @override_v10_schema, 10)),
         :ok <-
           maybe_migrate(
             db,
             version,
             11,
             &migrate_standard(&1, @override_operations_v11_schema, 11)
           ),
         :ok <- maybe_migrate(db, version, 12, &migrate_standard(&1, @candidate_v12_schema, 12)),
         :ok <-
           maybe_migrate(db, version, 13, &migrate_standard(&1, @handoff_clock_v13_schema, 13)),
         :ok <-
           maybe_migrate(db, version, 14, &migrate_standard(&1, @causal_roots_v14_schema, 14)),
         :ok <-
           maybe_migrate(
             db,
             version,
             15,
             &migrate_standard(&1, @observation_clock_v15_schema, 15)
           ),
         :ok <- maybe_migrate(db, version, 16, &migrate_standard(&1, @invariant_v16_schema, 16)),
         :ok <- maybe_migrate(db, version, 17, &migrate_standard(&1, @rule_v17_schema, 17)),
         :ok <- maybe_migrate(db, version, 18, &migrate_standard(&1, @maintenance_v18_schema, 18)),
         :ok <- maybe_migrate(db, version, 19, &migrate_standard(&1, @profile_v19_schema, 19)),
         :ok <-
           maybe_migrate(
             db,
             version,
             20,
             &migrate_standard(&1, @qualification_history_v20_schema, 20)
           ),
         :ok <- maybe_migrate(db, version, 21, &migrate_controller/1),
         :ok <- maybe_migrate(db, version, 22, &migrate_acceptance/1),
         :ok <- maybe_migrate(db, version, 23, &migrate_native_targets/1),
         :ok <- maybe_migrate(db, version, 24, &migrate_schedules/1),
         :ok <- maybe_migrate(db, version, 25, &migrate_schedule_lifecycle/1),
         :ok <- maybe_migrate(db, version, 26, &migrate_schedule_occurrences/1),
         :ok <- maybe_migrate(db, version, 27, &migrate_schedule_effects/1) do
      :ok
    end
  end

  defp maybe_migrate(_db, version, target, _migration) when version >= target, do: :ok
  defp maybe_migrate(db, _version, _target, migration), do: migration.(db)

  defp migrate_acceptance(db) do
    with {:ok, %{state: "active"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db) do
      migrate_standard(db, @controller_v22_schema, 22)
    else
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  @doc false
  def install_transfer_schema_tx(db) do
    with {:ok, [[version]]} when version in [21, 22, 23, 24, 25, 26, 27] <-
           query(db, "PRAGMA user_version"),
         {:ok, [[1, "integer"]]} <-
           query(db, "SELECT value,typeof(value) FROM meta WHERE key='restore_quarantine'"),
         :ok <- WotexHome.Durable.Store.Integrity.validate_snapshot(db),
         {:ok, %{state: "retired"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db) do
      with :ok <- if(version == 21, do: Sqlite3.execute(db, @controller_v22_schema), else: :ok),
           :ok <- if(version < 23, do: Sqlite3.execute(db, @native_target_v23_schema), else: :ok),
           :ok <- if(version < 24, do: Sqlite3.execute(db, @schedule_v24_schema), else: :ok),
           :ok <- if(version < 25, do: Sqlite3.execute(db, @schedule_v25_schema), else: :ok),
           :ok <- if(version < 26, do: Sqlite3.execute(db, @schedule_v26_schema), else: :ok),
           do: if(version < 27, do: Sqlite3.execute(db, @schedule_v27_schema), else: :ok)
    else
      _ -> {:error, :invalid_transfer_snapshot}
    end
  end

  defp migrate_native_targets(db) do
    with {:ok, %{state: "active"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @native_target_v23_schema),
             :ok <- WotexHome.Durable.Store.Integrity.validate_schema_version(23, db),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT"),
             do: :ok

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  defp migrate_schedules(db) do
    with {:ok, %{state: "active"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @schedule_v24_schema),
             :ok <- WotexHome.Durable.Store.Integrity.validate_schema_version(24, db),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT"),
             do: :ok

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  defp migrate_schedule_lifecycle(db) do
    with {:ok, %{state: "active"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @schedule_v25_schema),
             :ok <- WotexHome.Durable.Store.Integrity.validate_schema_version(25, db),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT"),
             do: :ok

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  defp migrate_schedule_occurrences(db) do
    with {:ok, %{state: "active"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @schedule_v26_schema),
             :ok <- WotexHome.Durable.Store.Integrity.validate_schema_version(26, db),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT"),
             do: :ok

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  defp migrate_schedule_effects(db) do
    with {:ok, %{state: "active"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @schedule_v27_schema),
             :ok <- WotexHome.Durable.Store.Integrity.validate_schema_version(27, db),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT"),
             do: :ok

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    else
      {:ok, %{state: "retired"}} -> {:error, :source_retired}
      error -> error
    end
  end

  defp migrate_controller(db) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, @controller_v21_schema),
             :ok <- WotexHome.Durable.Store.ControllerWriter.bootstrap(db),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=21"),
             {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
             :ok <- Sqlite3.execute(db, "COMMIT"),
             do: :ok

      if result != :ok, do: Sqlite3.execute(db, "ROLLBACK")
      result
    end
  end

  defp migrate_execution(db) do
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

  defp migrate_standard(db, ddl, target_version) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with :ok <- Sqlite3.execute(db, ddl),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=#{target_version}"),
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
end
