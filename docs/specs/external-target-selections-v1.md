# Durable external read-target selections

Version: 0.1.4. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.18 H18-03/04/05/07/08, H18-T2/T3/T4/T5/T6/T8/T9/T11/T12.
Implementation: closed encodings, pure preparation and schema 34 durable
selection/replacement/revocation, dependency retirement and quarantine retention
implemented. Schema 35 [native observations/reported previews](external-observations-v1.md)
and target socket/CLI operators are implemented. Host installation and native
client adoption planned. Evidence: [bounded software](../provenance/external-target-selections-2026-10.md);
complete acceptance matrix and physical evidence missing.

## Result and existing boundaries

An authenticated operator selects one exact approved raw v2 closure for one
actual host-held source, creating or replacing a read-only EnvironmentalSensor
Thing in the shared Registry. Catalogue approval and target selection remain
different histories. Selection retains the actual target capture, consumer
policy and declaration; it does not issue grants, accept a report, activate a
routine, qualify hardware or enable physical dispatch. Existing v1 Light/
SmokeDetector histories and namespaces remain unchanged.

Authority.change_external_target/3 and external_target_status/4 forward to the
single Store. Store owns all SQLite, revisions, current pointers and borrowed
writer calls. The explicitly configured external_source_owner is null by default
and otherwise an existing [SourceOwner](external-source-custody-v1.md) process
reference; no request installs one. The owner receives an authenticated principal
ID, not bearer/Store connection. Private typed imports remain actor-owned under
schema 29; [raw catalogue trust](external-trust-v1.md) remains schema 33's exact
manifest and separate external policy generation. [Generic read records](generic-read-semantics-v1.md)
own historical declaration representation, with live public WPF rebuilding before
selection. Canonical external observations remain a separate later transition.

## Closed original request

Every input contains exactly authority_epoch, operation_id, expected_revision,
action, target_id, artifact_digest, expected_trust_revision,
expected_policy_generation, expected_selection_revision, expected_resource_revision,
source_ref, source_owner_epoch, source_selection_sha256, objects and acknowledgement.
Epoch is positive signed-64; all expected revisions/generation nonnegative signed-64.
Operation/target/source references are Home IDs (ASCII 1–128 bytes), artifact and
source selection SHA lower hex64. Action is select or revoke. There are no defaults.

Select requires source_ref, lower hex32 source_owner_epoch, source_selection_sha256,
acknowledgement exactly operator_external_selection and objects exactly
envelope_ref, profile and definitions. These are the inspection owner's exact
actor-owned typed handles/document refs, including positive first-import revision,
absolute URI ≤256, canonical version and semantic digest. Definitions is sorted
by reference ID/version, unique by ID and object digest, at most 32. The actual
reader basis comes from the held source, never a caller-supplied installation.
Revoke requires those five selection-only fields null, including objects and
acknowledgement. Artifact identifies the target's current selected raw closure.

Profiles.ExternalTarget encodes the canonical ordered array
["wotex-home.external-target.v1", [epoch, operation, expected_revision, action,
target, artifact, expected_trust, expected_policy, expected_selection,
expected_resource, source-or-null, owner_epoch-or-null, source_sha-or-null,
objects-or-null, acknowledgement]]. Objects is [envelope_handle, profile_document,
[definition_document, ...]], using the existing inspection handle/reference
array forms. Input ≤32768 bytes; array-only AuthoringWire grammar is inherited:
depth eight, 4096 nodes, arrays ≤256, UTF-8 strings ≤4096 and signed-64 integers.
Malformed/unknown/native/duplicate fields refuse invalid_external_target;
resource excess external_profile_limit. Key is principal/epoch/operation in this
separate namespace. Changed input at that key is external_target_conflict.

## Preparation, source custody and reviewed identity

**TS-01 — Recover before fresh work.** Current profile:manage and enroll:review
are required for new work, status and exact replay. Authenticate before lookup
and validate import/inspection/trust/target histories. Exact replay returns the
original receipt before CAS, maintenance, files, producer, source owner or lease
work. Permission withdrawal denies original reads. Historical receipt is not
current target authority.

**TS-02 — Guard the new operation.** Require current authority epoch, global CAS,
active maintenance (another host:maintain actor may own it), exact external policy
generation and previous target selection/resource revisions. Absent target has
both zero. First action is select. An existing target must be generic and
already owned by this external lifecycle; its selected/revoked state must match
the shared enrollment state. Reject collision with legacy or fixture-
only/unbound enrollment. A revoked identity remains a tombstone; selection can
replace its declaration only for the same reviewed physical stable_id. A revoke
of absent/already revoked target is not_found/external_target_already_revoked.
Every integer/capacity limit must have room before fresh publication or mutation.

Select requires the exact current approved trust revision and active approving
principal with profile:manage. It must bind the same artifact manifest retained
by catalogue trust, including permanently bound labels/raw frames. Revoke is
metadata-only and may use the latest retained trust revision even when revoked
or author unavailable; it does not read source/capture/files or producer. Wrong
trust/policy/selection/resource respectively refuse external_trust_changed,
external_policy_changed, external_selection_changed and resnapshot_required.

For select, source owner epoch and SHA must match the current safe source catalogue.
Hold under this actor and exact original input SHA; checkout preserves the original
deadline and caller PID. Missing owner/source, changed owner/selection and retired
lease retain the source-custody typed refusals. The operator references only a
host-published source. No URI, endpoint, driver, capture body or consumer policy
is accepted in the request. Store checks actor-owned handle kinds/first revisions
at or before CAS, reads verified immutable frames with sequential private leases,
and releases byte leases on every path.

Profiles.ExternalTargetPreparation.build/4 takes the typed selection input,
complete actor-selected read records, checked held ExternalSourceSelection and
the retained approved artifact document. Rebuild the source selection. Assemble
a pure inspection input from epoch/operation/CAS, supplied objects and this actual
target reader basis. Use the existing checked inspection/approval preparation,
compare complete raw manifest and digest to the approved immutable artifact,
then compile ExternalEnvelope with exactly those verified raw documents and the
held target reader/capture. Never reuse the catalogue inspection projection as
the target projection. The catalogue and target captures may differ.

Each included channel must have exactly one host source channel/consumer/policy
row. Source channel IDs must equal included channel IDs; no additional
source-policy channel or omitted included channel is accepted;
optional excluded channels remain explicitly excluded and create no capability.
Create each read declaration with target_id added to that explicit policy;
encode its retained record with the verified raw artifact digest. Build the
shared Thing with role EnvironmentalSensor, profile_ref external:artifact and
capabilities sorted by key; enforce its existing total 65536-byte ceiling.
No vendor/model/sensor branch or copied WPF parser/unit algebra is permitted.

The safe prepared result contains target inspection, exact thing_document and
source basis. The borrowed native source carries private stable_id for collision/
succession review; never print it or expose it in a socket response. Stable ID
must not belong to another retained external binding or legacy enrollment binding,
including revoked identities. Same target must keep its original stable ID;
changing model/capture/consumer/risk/units requires new exact preparation. Source
fields and method/trust remain host assertions, not physical qualification.

**TS-03 — Commit and invalidate atomically.** One Store transaction rechecks
actor, original, epoch/CAS, maintenance, previous counters, trust/author/policy,
owned import refs, exact source owner incarnation/SHA and checkout guard. Require
the same native source and now < expires_at; the guard PID is internal Authority
data and cannot be supplied in JSON. Retain immutable input/outcome/receipt;
append external_target_selected/revoked with entity_id target_id, append target
history and update current pointer, shared enrolled Thing and source binding.
Initial enrollment has resource revision zero; each replacement/revoke advances
resource by one. Selection generation starts one and advances once per transition;
binding revision is the select's journal revision and is retained on revoke.
No transient token/PID/monotonic deadline enters durable history.

The operation journal event precedes its invalidation events. Its revision is
the receipt and selection revision and equals the input CAS plus one; later
invalidation events can advance the global revision further in that same
transaction. Dependency retirement uses its own target journal event after the
owning withdrawal event, with cause_revision pointing to that withdrawal.

Every replacement/revoke withdraws all current target grants (including read)
without widening another target's grant. Regrant requires the existing explicit
grant-and-rotate lifecycle after the new declaration is reviewed. Initial selection
creates no grant. Invalidate current reports, source-epoch grants, overrides,
dependent qualification and unsent work in the same transaction. Use owning
request invalidation so queued/claimed work is rejected and handed-off work remains
outcome_unknown; never resend it. Generic read targets acquire no legacy fact,
write or routine scope. SQL failure rolls back every row, counter and pointer.

Finish the source checkout after any definite attempt/refusal, dropping its private
snapshot. A finished/expired original cannot renew source evidence. After lost
reply, query durable original status or exact retry before proposing a new ID.
If no durable original exists and the source original has retired, the operator
must explicitly review a fresh original; no automatic recapture/replay is allowed.

## Encodings, schema and retained history

Outcome is exactly format wotex-home.external-target-result@1, action, target_id,
artifact_document, inspection_document, thing_document and source_document.
Select has all four documents. Source document is the ordered array
["wotex-home.retained-source@1", owner_epoch, source_selection_sha256,
input_chunks, reader_chunks, policy_chunks]. Each chunk array uses the fixed
UTF-8 split below. Inputs retain the exact producer canonical JSON of source,
reader.inputs and channels. Reader and policy documents retain the exact
canonical JSON of reader.inputs and channels separately. Source document is
at most 600000 bytes. These byte witnesses permit producer-independent
recomputation of source-selection, reader-basis and policy digests with their
owning prefixes; parsed reader/policy must equal the corresponding inputs.
It is private durable
custody (database 0600, encrypted inclusive backup), not an API result. Revoke
retains the preceding exact documents for identity/history without reinterpretation.

Outcome wire is an ordered array in this field order. Documents are exact UTF-8
byte-preserving string chunk arrays with nonempty chunks ≤4096 bytes, cut only
between UTF-8 codepoints, preserving original bytes. Chunk arrays ≤256; whole
outcome ≤1048576 bytes, depth eight and 4096 nodes. Decode concatenates without
reserializing. Reject alternate empty/redundant chunk boundaries by requiring the
fixed maximal safe 4096-byte split. Artifact/inspection/Thing decode through their
owning closed historical codecs; source document validates exact six-field source,
owner epoch, reader/input shape and bounded JSON containers (262144 bytes each,
4096 nodes, collections 256, strings 4096) without doing producer unit/schema
algebra. Reader and policy witnesses retain depth eight. Only the complete-input
witness permits depth nine for the [source selection's one wrapper level](external-source-selection-v1.md);
its parsed reader/policy must equal the separately bounded witnesses. No wire
array, reader, decoded value or report depth limit increases; prior witness bytes
and hashes remain unchanged. Live preparation must revalidate producer mechanics.

Receipt is exactly authority_epoch, operation_id, revision, input_sha256, action,
target_id, artifact_digest, previous_selection_revision, selection_generation,
resource_revision, binding_revision, trust_revision, policy_generation,
source_selection_sha256, outcome_sha256 and withdrawn_grants. SHA fields are
lower hex64; generations/revisions follow the transition above; withdrawn_grants
is nonnegative ≤4096. Source SHA is the retained selection's even on revoke.
Receipt is a canonical array of these sixteen fields ≤4096 bytes.

Schema 34 is implemented with schema 33 as its checked predecessor.
Add profile_external_target_operations with the existing seven-column original
shape principal_id, authority_epoch, operation_id, input_document, outcome_document,
receipt_document, revision. PK is original scope, revision unique journal FK.
Add profile_external_target_history exactly target_id, revision, generation,
action, cause_revision and outcome_document; PK target/revision, generation unique
per target, journal/cause journal FKs. Action is select, revoke or dependency_revoked.
Add profile_external_target_current exactly target_id, selection_revision,
generation, state, resource_revision and binding_revision; target references the
shared enrolled_things and target/revision references history. State selected/revoked.
Add profile_external_source_bindings exactly target_id, stable_id, source_ref,
owner_epoch, source_selection_sha256, source_generation and binding_revision;
target PK/FK, stable_id unique permanently, binding revision journal FK.
All new tables start empty; no old trust, inspection or fixture enrollment is
promoted to current generic selection. No new policy meta counter is needed.

Retain ≤256 target identities and ≤1024 target originals with 4 MiB aggregate
input and outcome bytes, refusing external_target_capacity before work and at
commit. History permits ≤2048 transitions and 8 MiB outcome bytes: every selected
original reserves one exact-outcome dependency retirement, so trust/principal
withdrawal cannot be refused merely because ordinary admission capacity is full.
Each selected history can produce at most one dependency retirement. Historical
validation checks actor/epoch/input/receipt hashes,
exact approved raw manifest, actor-owned imports, target inspection/declaration/
consumer/source correspondence, sequential target generations/resources/bindings,
current pointers, stable-ID uniqueness, journal/cause links, counter/CAS arithmetic
and orphans without producer or filesystem. Corruption is corrupt_external_targets
and fences writes. Producer-independent history is not fresh target authority.

## Dependency withdrawal, current use and recovery

**TS-04 — Retire dependent authority.** External trust revoke and withdrawal of
the latest trust/selection author must irreversibly retire selected dependents
in that owning transaction. Add dependency_revoked history/current/resource
transitions referencing the actual trust/principal withdrawal journal cause;
do not create a fictitious user original. Preserve exact prior outcome documents,
withdraw grants and invalidate reports/qualification/work as above. Later permission
reinstatement or artifact reapproval cannot revive these selections or freshness.
Existing twelve-field trust receipts remain unchanged; dependent effects are
retained in target history and current status, not appended to an old receipt.

Current generic use must match retained Thing/resource, selected pointer, current
selection/trust author permissions, exact trust revision/separate policy generation,
private immutable byte availability and current configured source-owner incarnation/
SHA. Source replacement or owner loss immediately blocks use through this guard;
monotonic source generation and new owner epoch prevent old projection revival.
Explicit reselection after restart is required. Legacy compiled-profile fallback
is never allowed for an external digest. Generic report/fact/control consumers
remain unavailable until their separately specified admission is implemented.

Schema migration, inclusive/database-only backup, quarantine and normalized transfer
use each schema's actual tables. Older normalized histories declare empty new
tables; retained originals/source/private frames are preserved without live owner
or producer. Restore starts quarantined, grants/observations/leases/qualification
are not manufactured or resumed. Missing bytes/producer/source block dependent
live use, but actor-scoped original lookup and metadata-only revoke remain possible.
Historical source assertions do not prove the physical unit is still present.

## Acceptance

Freeze independent single/multi-channel select/revoke inputs, chunks, outcome,
receipt, schema and history examples before code. No fixture establishes physical
device support; qualified transport/read and canonical observation gates stay open.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| TS-T1 | 01–03 | Two independent quantities and actual multi-channel source: approve, hold, select, restart original, replace/revoke. Raw/source/declaration identity drift or automatic grant/control fails. | Software |
| TS-T2 | 01/02 | Wrong actor/CAS/epoch/trust/policy/previous revisions, unowned/wrong-kind/missing bytes, source epoch/SHA/expiry/caller, legacy/unbound/duplicate stable ID and unsupported consumers. Any partial target or renewed source fails. | Software |
| TS-T3 | 03/04 | Actual SQL faults, lost reply, replacement/grant withdrawal, trust revoke and author withdrawal/reinstatement, source/publisher loss. Partial invalidation, replayed effect or revived selection/freshness fails. | Software |
| TS-T4 | 01/03/04 | Deep input/outcome/source/declaration/current/history/journal corruption, count/byte limits and schema 33 migration. Writable corruption, missing tombstone or promoted old authority fails. | Software |
| TS-T5 | 01/04 | Exact encrypted inclusive/database-only quarantine and normalized source transfer; absent source/producer metadata status/revoke. New live lease/grant/report/qualification fails. | Software |
