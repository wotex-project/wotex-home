# Consumer-owned profile authoring

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18, H18-09/H18-T13–H18-T18.
Implementation: tagged private custody and authenticated inert staging implemented;
authenticated authoring operation/journal/assessment/generation planned. Evidence:
independent frame vectors and focused actual-root/Store tests.

## Result, location and dependencies

A Home operator can manually author or optionally ask a configured AI to draft
a supported model mapping against the exact installed WoTEx contract. Both
paths finalize and validate through the same producer and remain proposals.
No separate definitions repository, shared catalogue, cloud or AI is required.

Public model templates live in Home's existing priv/profiles layout, with
independent vectors in test/support/profiles. These are proposed v2 assets,
not a change to current v1 fixtures. Drafts, supplied documents, installation
identities and approval history live in Home's private custody. No runtime
profile loader reads Markdown, scans a neighboring repository or fetches a URL.

Implemented WoTEx WPF.01–03 in owned source own the closed mapping language, pure compiler and
authoring contract/finalizer/diagnostics. WPF.03 exports supported schemas,
bindings/contracts and limits, computes local-reference hashes without guessing
semantics, and reports deterministic compatibility. Public APIs are Contract.export/4,
Draft.finalize/2 and Validation.check/3, with checked projections for their native
values. Exact archive evidence is retained by the producer. Home's authenticated/
durable authoring operation and application dependency adoption remain planned;
when absent, this successor reports unavailable and uses no local substitute.
The [v2 envelope](device-profile-mappings-v2.md) joins finalized mappings to
Home consumption contracts. [WOH.18](WOH.18-portable-profile-admission.md) owns
import, trust, selection, retention and recovery. Existing v1 behavior is unchanged.

## Inputs, identity and limits

An authenticated authoring request contains exactly mode, contract_digest,
base_draft_ref, source_refs, fixture_refs, instruction and limits. Mode is manual
or generated. Contract_digest is lower hex64 over the trusted host-exported
WPF.03 contract, not a contract supplied by the model. Base_draft_ref is null
or a private immutable digest/revision handle owned by this actor. Source_refs
and fixture_refs are explicit unique private custody handles; no URI is fetched.
Instruction is bounded UTF-8 text, never executable code or an authority grant.
Unknown/duplicate fields reject. Actor, authority epoch and current installed
binding/producer/policy basis come from Authority, not these request fields.

| Resource | First Home ceiling |
| --- | --- |
| Mapping/envelope/individual definition | 64 KiB each; depth eight, 4096 JSON nodes |
| Complete generated draft/finalized raw closure | 256 KiB; 32 channels/definitions/dependencies, per v2 |
| Instruction | 4096 UTF-8 bytes, no NUL/control characters except newline/tab |
| Selected source passages | 32, each ≤4096 UTF-8 bytes; aggregate ≤128 KiB |
| Fixture reports | 32; each obeys WRT.06 C02 bounds; aggregate input ≤256 KiB |
| Diagnostics | 64 and 24 KiB encoded; truncate without reporting success |
| Field evidence / unresolved paths | 256 evidence entries / 64 unresolved paths |
| Generation attempts | 1–3 explicitly requested; no hidden provider retry |
| Per-attempt / total deadline | Required positive monotonic milliseconds, ≤30000 / ≤120000; attempts and repair consume the same total |
| Pending authoring operations | ≤16 host-wide and one executing generation per operator |

All limits are explicit and may narrow these ceilings. Authoring shares WOH.18
custody's existing 128-object, 4-MiB and 32-lease quotas; no reserve bypass or
automatic deletion of selected/history/backup objects. Source originals need
not enter a model: only approved bounded passages do. Request refusal on
capacity changes neither a draft nor an active profile. Deadline is owned by
the host; restart retires the executing attempt rather than extending time.
Source/draft custody objects need a separately closed successor encoding;
they are not parsed as v1 profile artifacts or admitted by relaxing that codec.
Set max_check_steps explicitly within WPF.03's 1000000-step ceiling; all
authoring schema/finalizer counts share that budget and refuse on exhaustion;
WPF.01/02 work retains its separately enforced reader/numeric limits.

The retained candidate record binds actor/authority epoch, immutable request,
base draft revision, original draft bytes, exact contract/installed-basis digests,
sources/fixtures, finalized bytes/report, field evidence and unresolved paths.
It also records generation adapter/build identity when applicable. These are
conceptual successor obligations, not a declared existing SQLite schema/API.
Freeze the closed record encoding and original-operation receipt/migration
contract before adding a durable writer; re-use the one Store authority.

Field evidence entries contain exactly instance_path, source_ref and locator.
Paths use RFC 6901 over known draft fields, ≤512 bytes; source_ref names one
selected immutable source; locator is inert text ≤256 bytes. Unresolved paths
are unique/sorted bounded pointers. Source attribution proves neither truth nor
qualification; it makes a proposed model/firmware/selector/scale reviewable.
Required facts lacking evidence or with conflicting source claims block review
completion. They never become guessed zeroes, units or selectors.

## Requirements and transitions

### Private typed custody objects

Before the durable authoring writer, the existing private Custody owns immutable
tagged objects alongside its unchanged plain v1 profile files. Each tagged file
contains exactly ASCII WOHA (four bytes), version 1 (one byte), kind tag (one
byte), payload length (unsigned big-endian 32 bits), raw SHA-256 of payload
(32 bytes) and that exact payload. No trailing bytes or unknown versions/tags
are accepted. The complete file digest is its custody handle; payload_sha256
separately identifies original bytes. Kind is part of the file digest, so the
same bytes under source/draft are different objects and cannot alias an approval.

| Tag / kind | Nonempty payload byte ceiling |
| --- | --- |
| 1 source | 262144 |
| 2 draft | 262144 |
| 3 bundle | 262144 |
| 4 fixture | 65536 |
| 5 contract | 262144 |
| 6 envelope | 65536 |
| 7 profile | 65536 |
| 8 definition | 65536 |

`Profiles.AuthoringObject.new/2` constructs the frame from kind and original
bytes; parse/1 verifies exact length, kind bound and payload digest. Its native
fields are exactly bytes (complete frame), digest, kind, payload and
payload_sha256. summary/1 revalidates all fields and returns exactly kind,
object_digest, payload_sha256 and payload_bytes. Invalid native/frame input
returns invalid_authoring_object. This checks storage representation, never
document compatibility, attribution, review, capture or physical truth.

`Custody.stage_object/3`, read_object/2 and lease_object/2 use that parser and the
same pinned root, non-replacing synchronized publication, descriptor checks and
monitored leases as v1. Plain v1 and tagged reads are separate APIs. A tagged
object cannot be read/selected/exported as a v1 Artifact. File names remain the
complete-file digest plus .json; the suffix is an opaque custody convention,
not a claim that a tagged frame is JSON. Inventory counts frame bytes, including
the 42-byte header, against the same 128-object/4-MiB/32-lease ceilings. Duplicate
publication consumes no new quota. Crash orphans continue consuming quota.

Collection validates either historical v1 syntax or an exact tagged frame,
protects both lease kinds and the Store-supplied retained digest set, and never
parses a tagged payload as active data. A changed checksum/length, symlink,
permission, descriptor, root or publication identity fails closed. Maximum file
and temporary-file access is 262186 bytes; v1 parsing still enforces 32768 bytes.
Store-only export_objects/2 accepts at most 128 sorted unique complete summary
records and returns those exact summaries plus frame bytes after all objects
verify; caller/field/digest/size mismatch refuses without partial output.
Existing export_many/2 and its v1 archive encoding retain their original shape.

`Authority.stage_authoring_object/4` authenticates current profile:manage through
the single Store before staging, and returns only the summary. It does not start
an authoring operation or establish actor ownership of a source reference.
Authenticated durable reference ownership, retained journal rows, quota
reservations and backup packaging are the next writer's prerequisites; generic
custody alone must not claim them. No new SQLite version is required for this
storage component. Root-file tests exercise actual quotas, publication, leases,
collection, checksum corruption, wrong API/type, caller ownership and restart;
independent binary/digest vectors precede code.
The [custody software record](../provenance/authoring-custody-2026-10.md) retains
the implemented source and executed root/Store checks; durable authoring remains
separate work.

**H18A-01 — Contract and authoring.** Authority exports the exact installed
WPF.03 contract narrowed to Home's v2 support and current operator scope.
The consumer restriction layer is an explicit review basis, not a rewritten
producer schema. Exported bindings contain grammar/mechanics, no private routes,
capture values or credentials. Manual tools receive the same contract as AI.
Provider schemas can assist generation; final checks always use WPF.03 plus
Home's current envelope/consumption policy. No copying validators/unit algebra.

**H18A-02 — Generation boundary.** A configured, explicitly selected generator
receives only the approved contract, instruction and source passages/examples.
It has no device transport, shell, install, Store, bearer or activation port.
Remote processing requires the operator's explicit permitted source/export
policy; otherwise use a configured local generator or manual authoring.
Recheck that policy before each provider handoff. Revocation blocks future
handoffs; it cannot retract sources already handed to the provider. Record
that earlier handoff separately from draft acceptance and never replay it on
an original-operation retry. Provider credentials remain host-held.
Unavailable models or unsupported generation schemas return unavailable; they
cannot silently change provider, disclose sources or weaken validation.
Documents and diagnostic feedback are data, including instructions embedded
in them. The model cannot choose new sources, bindings, permissions or limits.

**H18A-03 — Finalize and assess.** For each candidate Home calls WPF.03's
finalizer and validator, then checks the v2 envelope and supplied independent
fixtures. Finalizer hashes/order are derived mechanics; authored scale, units,
sentinels and protocol selection are unchanged. Expected fixture results must
come from independently reviewed vendor/protocol evidence, not the same model
that authored the draft. Preserve raw sentinels, exact conversion, null/quality
and actual source time. A wrong register inside a supported selector grammar
can remain producer-compatible; source review/independent model fixtures must
refuse its use rather than claim the generic validator knows the hardware.
Reports show compatibility, capture status, uncovered
channels and unresolved source facts separately; never a single confidence score.

| Event | Required basis | Result / failure |
| --- | --- | --- |
| Start manual/generated draft | Current author permission, exact contract, source policy and capacity | Private pending candidate; no active-state change |
| Model response | Same pending operation/attempt and authority epoch, within both deadlines | Retain bounded candidate or invalid/unavailable disposition |
| Repair | Same approved input set, remaining attempt/time budget | New immutable draft revision; every candidate re-finalized/revalidated |
| Assess | Current installed basis, exact bytes, independent fixtures | Compatible/incompatible proposal; no trust/qualification granted |
| Review for import | Exact draft/report/source/fixture identities and current actor/policy | Existing WOH.18 import/trust proposal, or stale/unresolved refusal |
| Select for a Thing | Existing WOH.18 current capture, grants, declaration/qualification and Store transaction | Separate selection outcome; authoring cannot perform it |
| Cancel/revoke/deadline/restart | Pending operation basis | Retire attempt; late responses cannot update successor or active state |

**H18A-04 — Review and race guards.** Any candidate/source/fixture change creates
a new revision and invalidates prior assessment. Before import/trust/selection,
Authority rechecks current producer/schema/rule/binding identities, accepted
meanings, actor/epoch, base revision and source policy. Missing bytes, changed
firmware/capture or revoked authority refuses stale use. A compatible old report
is retained history, not a current certificate. Never infer enrollment or
physical qualification from model matching, schema checks or fixture success.

**H18A-05 — Retention and recovery.** Repeated authenticated original-operation
queries return the same retained draft/attempt result; they do not regenerate
or spend another provider attempt. A changed request requires a new operation.
A lost provider response is unavailable/unknown generation, with no model/tool
effect replay; explicitly requested repair uses the remaining shared budget.
Restore preserves original bytes/basis and quarantines candidates with missing
dependencies. No remote fetch, stale activation or automatic provider restart.
Private draft cleanup obeys existing custody references/leases and cannot remove
selected profiles or rewrite approvals. Telemetry records counts/dispositions,
duration and opaque operation correlation, never document/profile/secret bytes.

## Implementation entry and acceptance

Freeze producer schemas/public seams and independent v2/authoring vectors first.
Then define the authenticated public authoring operation encoding, durable
original receipt and migration/backup encoding under WOH.14/18. No new schema
number, route or provider pin is chosen by this document. Physical dispatch
remains default-disabled until its actual owning qualification passes.

| Case | Requirements | Stimulus and expected falsifier | Evidence |
| --- | --- | --- | --- |
| H18-T13 | 01, 03 | Manual and scripted-generator drafts describe unseen quantity through same producer/archive; different result or model branch fails | Pure/software |
| H18-T14 | 01–03 | Wrong units/register/selector despite valid JSON, forged hash, conflicting/missing source and unsupported provider schema | Explicit incompatible/unresolved/unavailable; no import/select |
| H18-T15 | 02, 05 | Inject source instructions to reveal credentials or activate a profile; cancel/revoke during generation | No forbidden port/export, late result cannot commit |
| H18-T16 | 03–05 | Change binding, fixture, draft revision, actor or capture between assessment/review/use | Current-basis refusal; old report remains history |
| H18-T17 | 02, 05 | At/above each quota/deadline, three failed repairs, lost response/restart/restore | Bounded disposition, original retry does not regenerate, no active changes |
| H18-T18 | 01, 04–05 | Offline export/import to another host with different grants/accepted semantics | Revalidated locally, no imported approval or physical claim |

Software cases are required but cannot prove a manufacturer mapping is physically
correct. WOH.11 and the relevant lab procedure own that separate evidence.
Primary rationale is the producer's [research decision](https://github.com/wotex-project/wotex/blob/main/docs/architecture/consumer-profile-authoring-research.md).
