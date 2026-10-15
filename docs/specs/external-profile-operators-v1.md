# External profile, target and reported-value operators

Version: 0.1.6. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-07/08, H18-T6/T8/T11/T12; WOH.08 H08-03.
Implementation: inspection/trust/target and reported-value read socket/CLI adapters implemented. Evidence:
[executed real-socket and original recovery cases](../provenance/external-profile-operators-2026-10.md).
Target real-socket, CLI and original-recovery evidence is recorded in the same
software record. Reported-value socket/CLI parity, grant denial and restart evidence is recorded
in the same software record.
[Native catalogue/original reads](native-external-profile-reads-v1.md) now have
[executed framed and actual Store evidence](../provenance/native-external-profile-reads-2026-10.md).
[Complete native originals](native-external-profile-originals-v1.md) now have
[executed byte/hash and owning parity evidence](../provenance/native-external-profile-originals-2026-10.md).
Native v2 pending/confirmations/presentation and installed host adoption remain open.

## Result and ownership

An authenticated local operator can inspect an already imported v2 closure,
explicitly approve or revoke its exact digest, recover the original decision,
and read the current external catalogue through the private socket and CLI.
These adapters forward the unchanged typed input to Authority and the single
Store. They cannot supply a host reader, capture, installed registration,
capability declaration or physical qualification. Inspection is inert; digest
approval does not select a target or authorize an observation or control.

The [inspection contract](external-inspections-v1.md) owns actor-owned handles,
current host reader correspondence and schema 32 originals. The
[trust contract](external-trust-v1.md) owns explicit acknowledgement, maintenance,
CAS, separate v2 policy generations and schema 33 originals. New inspection
requires current profile:manage and no active maintenance; new trust requires
current profile:manage and active maintenance, which a separate host:maintain
actor may establish. Exact replay precedes those new-work guards. Current
permission is still required for replay and status. Neither adapter invents a
missing import, reader or producer. Byte upload, source/candidate/review operator
flows and the native v2 panel retain their separate owning delivery obligations.

The [target contract](external-target-selections-v1.md) owns the exact fifteen-field
select/revoke original, current profile:manage plus enroll:review, active maintenance,
CAS/trust/policy/selection/resource counters and checked host-held source. Its schema
34 transition is implemented. The target adapter forwards that original unchanged;
it neither publishes nor installs a source owner. Target status recovers one
actor-scoped original and does not assert that its selection is current. Missing
source/producer may refuse a fresh select while original recovery or metadata-only
revoke remains available. Selection creates no grant or canonical observation.

The [observation contract](external-observations-v1.md) owns native report
admission, schema 35 originals and current reported previews. The read adapters
require current read permission and a whole-Thing grant; profile:manage does not
substitute for either. Original lookup uses report-owner epoch/report ID, distinct
from the authority epoch/operation ID used by profile mutations. Missing originals
return not_found only after read authentication; an existing original also requires
the grant for its retained target. Current previews apply the Store's live source,
producer, selection, receipt clock, boot, quality and freshness checks on every
read. Status is immutable history and cannot renew a report or claim it is current.
There is no operator report-body, receive-time, source publication or admission
route. A new report enters only through the trusted native receipt owner.

## Closed socket requests and responses

Each request includes exactly api_version = 1, operation and credential, plus
the fields below. Credential is the existing canonical unpadded URL-safe base64
encoding of the 32-byte bearer, inside the private frame. Unknown fields and
versions refuse unsupported_operation_or_fields. Duplicate JSON names, depth
over 16 and bodies over 65536 bytes refuse through the existing Frame decoder
before Authority. Responses remain bounded to 1048576 bytes. Private directory
0700, socket 0600, checked same-user peer and bearer authorization remain required.

| Operation | Additional fields | Successful response member |
| --- | --- | --- |
| external_profile_inspect | inspection: complete native four-field inspection original input | external_inspection_receipt |
| external_inspection_status | authority_epoch, operation_id | external_inspection_receipt |
| external_trust_change | change: complete native nine-field trust original input | external_trust_receipt |
| external_trust_status | authority_epoch, operation_id | external_trust_receipt |
| external_profiles | none | external_profile_catalogue |
| external_target_change | change: complete native fifteen-field target original | external_target_receipt |
| external_target_status | authority_epoch, operation_id | external_target_receipt |
| external_report_current | target_id, capability_key | external_report_preview |
| external_report_status | report_owner_epoch, report_id | external_observation_receipt |

Nested originals use the exact closed grammars in their owning contracts;
the wrapper adds no defaults or identity. Epoch for status is positive signed-64;
operation is a Home ID of at most 128 bytes. Report-owner epoch is exactly 32
lowercase hexadecimal characters; report ID, target ID and capability key are
Home IDs of 1..128 bytes. No coercion, defaults or additional fields are accepted.
Report status constructs exactly the owning two-field native original. Each
successful response is exactly
api_version = 1, outcome = ok and its named member. Values match Authority's
native receipt, catalogue or thirteen-field reported preview with JSON string
keys. A fresh preview includes the exact ExternalValue document; every other
disposition has value = null. No credentials,
source bytes, selectors or capture fields are included. A missing original is
exactly api_version = 1, outcome = not_found. Refusal is exactly api_version = 1,
outcome = error, reason equal to the owning error atom as a string. Current
catalogue entries are sorted by id/version and remain distinct from historical
approve receipts, including revoked and author_unavailable states.

## CLI and original recovery

CLI retains --socket ABSOLUTE_PATH and --credential-file ABSOLUTE_PATH. Its
existing descriptor/owner/mode checks read the credential from a 0600 regular
file; no bearer appears in process arguments or diagnostics.

| Command | Input / result |
| --- | --- |
| external-profile-inspect ORIGINAL_FILE | Strict JSON native inspection original, forwarded as inspection |
| external-inspection-status EPOCH OPERATION_ID | Scoped original inspection receipt |
| external-trust-change ORIGINAL_FILE | Strict JSON native trust original, forwarded as change |
| external-trust-status EPOCH OPERATION_ID | Scoped original trust receipt |
| external-profiles | Current external catalogue |
| external-target-change ORIGINAL_FILE | Strict native target select/revoke original, forwarded as change |
| external-target-status EPOCH OPERATION_ID | Actor-scoped original target receipt |
| external-report-current THING_ID CAPABILITY_KEY | Current grant-protected reported preview |
| external-report-status OWNER_EPOCH REPORT_ID | Immutable observation receipt through current read permission/grant |

Original files are absolute paths at most 1024 bytes, private 0600 regular files
read through the existing checked descriptor, at most 32768 bytes. Decode uses
the strict Frame request-body parser, including duplicate/depth rejection, then
the owning canonical input encoder. No canonicalization changes the logical
input; retain the same file and credential for recovery. Invalid files refuse
invalid_external_inspection_file, invalid_external_trust_file or
invalid_external_target_file before opening
the socket. Numeric status epoch parsing rejects zero, overflow and trailing
characters; malformed operation IDs refuse usage. Report status rejects an
uppercase, short, long or nonhex owner epoch and invalid report ID before opening
the socket. Current-report arguments use the same Home ID bounds. Both report
commands require exactly two arguments and read no original or report file.

**EO-01 — One shared authority.** Route and CLI round trips produce the same
typed receipt/catalogue as direct Authority calls, including refusals. There is
no separate authorization, producer path or approval store in the adapters.

**EO-02 — Preserve uncertainty.** Inspect, trust-change and target-change are durable
mutations. Ordinary socket dispatch retains its five-second deadline; no new
producer work is started after an exhausted dispatch budget. Worker failure,
deadline, caller loss or a lost response can coexist with a committed Store
call. Exchange returns outcome_unknown for these mutation failures, kills its
route worker and never claims rollback. CLI treats timeout, unavailable socket,
invalid/oversized response or outcome_unknown as uncertainty, exits 3 and names
the matching status command with the original epoch/operation ID and same
credential. It directs the operator to retain the exact original file; it never
creates or sends a new ID. Status/catalogue/reported-preview failure is a read error, not mutation
uncertainty. A successful status read does not renew reader evidence or approval.
Target uncertainty names external-target-status with the same original epoch/ID;
it does not acquire or renew another source checkout, even if no durable original
is found. A new original after source retirement requires explicit review under
the target contract.

CLI prints the bounded JSON response and exits 0 for ok, 4 for not_found and 1
for refused/read failures. Syntax usage exits 2. Original receipts remain Store
history across restart, byte/producer loss and revocation according to the owning
contracts. This adapter adds no persistent client custody or automatic retry.

**EO-03 — Read without creating authority.** Current and original report reads
forward only their closed identifiers and existing bearer. Success, missing,
unknown and stale results equal Authority, including reason and null-value rules.
They allocate no original, source/report checkout or new revision. Timeout,
worker loss, unavailable Store, malformed/oversized response and lost reply remain
ordinary read failures: CLI exits 1, Exchange returns request_timeout or
operation_unavailable as applicable, and no mutation recovery instruction or
outcome_unknown is invented. A repeated read may advance age/decrease remaining
freshness but cannot change the original receipt instant. Private report/source
bodies and transport identities are never returned. Store restart preserves
original history while the current preview reports its actual boot/source guard.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| EO-T1 | 01 | Both independent fixture quantities: framed/real private socket inspect, approve, revoke, catalogue and original status equal direct Authority. Changed receipt, actor scope or implicit selection fails. | Software |
| EO-T2 | 01 | Extra/duplicate/deep fields, wrong version, invalid file modes, malformed originals/epochs, wrong credential/actor and missing reader. Any new durable row or producer-selected host basis fails. | Software |
| EO-T3 | 02 | Expired dispatch, actual worker/caller loss and discarded committed replies: mutation returns uncertainty, CLI exits 3, status/exact retry returns the same original without a new revision. A success claim or new original ID fails. | Software |
| EO-T4 | 01/02 | Revoked current catalogue versus historical approve receipt, maintenance transitions and restart/producer loss. Conflation of current authority and historical receipt or renewed evidence fails. | Software |
| EO-T5 | 01/02 | Both quantities and multi-channel target select/revoke/status through framed private socket and CLI equal Authority, preserve actor scope, refuse unknown fields/permissions and recover after discarded committed replies. Private source documents, new grants, renewed checkout or a new original ID fail. | Software |

| EO-T6 | 01/03 | Two independent quantities and multi-channel source: actual private socket/CLI current and original reads equal Authority; independent normalized coordinate, grant denial, malformed IDs/epochs, extra fields, missing original, lost reply and Store restart. A new revision/lease, private body disclosure, renewed age or mutation uncertainty fails. | Software/archive |

Independent external inspection/trust/observation vectors are the receipt identity oracle;
real Store and private socket cases establish adapter behavior. Synthetic input
and same-user development sockets do not establish signed native credential
custody, installed host acceptance or physical qualification. Implementation
requires the frozen owning inputs and executed schema 32/33/34/35 Store transitions;
this annex changes no schema or producer dependency pin.
