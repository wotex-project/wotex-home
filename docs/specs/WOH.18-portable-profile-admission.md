# WOH.18 — Portable profile admission

Version: 0.1.11. Status: accepted target; inert import/custody, local approvals, initial enrollment, firmware replacement, retained pins and collection implemented, operator flows unfinished, evidence missing.

## Scope and ownership

**H18-01.** Home accepts independently delivered immutable device-profile data
only through its existing Authority and single Durable.Store. Data-only profiles
and ordinary local control require no Wasm engine, registry or Internet service.
The optional executable boundary is WOH.17. Rule source continues through the
WOH.04 compiler/admission lifecycle; neither a profile package nor a helper can
install an active rule, widen the grammar or own a scheduler.

A profile selects a supported host binding and exact fingerprint. Home owns
capability meanings, units, risk, freshness ceilings, operations, permissions,
identity, packet correlation and transport. Generic TD/TM and protocol machinery
remain WoTEx responsibilities. A profile cannot embed scripts, expressions,
arbitrary packet templates, native code, module names, credential material,
instance endpoints or dynamic dependencies. Unknown bindings and new semantics
require a reviewed host release. Safety-device maintenance stays separately
disabled; data updates cannot add hush, OTA or alarm-clearing authority.

## Initial data format and identity

**H18-02.** The first format is one UTF-8 JSON object, at most 32 KiB, with
exactly these fields. The inert loader implements this format; admission and
target selection remain separate planned operations.

| Field | Closed value |
| --- | --- |
| `format` | `wotex-home.portable-profile.v1` |
| `id`, `version` | Existing bounded Home opaque ID syntax; labels are not byte identities |
| `fingerprint` | Exactly `transport`, `manufacturer`, `model`, `firmware_versions`; existing Profile field syntax, at most 32 distinct firmware values |
| `binding` | First supported value `lifx-direct-power-v1`; no author-supplied parameters |
| `dependencies` | Exactly one `{kind: "registry", sha256: <lowercase hex64>}` entry matching the installed pinned LIFX product registry |
| `provenance` | Exactly `publisher`, `source`, `license`: nonempty inert text, at most 256 UTF-8 bytes each, no control characters |

The initial binding requires UDP, numeric LIFX vendor/product/firmware identities
supported by that registry, and derives only ordinary Boolean Light power with
the current zero-duration operation and host-owned bounds. It does not broaden
the registry or the existing physical qualification profile. No author rank or
qualification reference is accepted. Home derives an unqualified pending
reference pinned to the artifact until a separate exact-cohort review exists.

Reject duplicate JSON keys at every depth, invalid UTF-8, trailing content,
unknown fields, floats, nulls, excessive nesting (maximum eight containers),
oversized strings/arrays and dependency mismatches. Enforce structural bounds
while parsing, before recursively allocating arbitrary input shapes. Never
decode external Erlang terms or create atoms from author input. No archive,
compression, remote context resolution, fetch hook or dependency solver exists
in v1. Provenance is attributed text, not trusted identity; sanitize it for UI
display and do not log it or follow its links automatically.

The artifact identity is SHA-256 over the exact received JSON bytes. Preserve
those bytes. Whitespace changes produce a different artifact even if the host
normalizes to the same meaning. A separately domain-versioned host projection
digest binds the validated profile, derived declaration, binding/registry,
compiler version and relevant policy. It cannot replace raw identity or justify
qualification reuse. The v1 projection encoding is a compact UTF-8 JSON array,
in this exact order: projection format, compiler format, id, version,
`[transport, numeric vendor, numeric product, sorted firmware strings]`, binding,
registry digest, `["Light", "power", "boolean", "none", ["read", "write"],
"ordinary", 5000, 0]`, and `["explicit_selection", "pending_physical_evidence",
0]`. The formats are `wotex-home.profile-projection.v1` and
`wotex-home.profile-binding-compiler.v1`. The final zeroes bind zero-duration
power and no author ranking. Attribute text and raw serialization are excluded
from the semantic projection; raw bytes still have their independent identity.
The pending qualification reference contains the raw artifact digest, so equal
semantic projections cannot transfer qualification between byte identities.
Labels do not select "latest": different bytes claiming the same `id/version`
conflict with an admitted identity; exact bytes retry without overwriting it.
Different matching labels are visible alternatives, never automatic precedence.
Compiled profile labels are reserved too; an external artifact cannot shadow
one during migration. Examples use distinct names and explicit digest selection.
The combined matching catalogue stays within the existing 64-profile ceiling.

## Custody, provenance and offline trust

**H18-03.** Stage bounded bytes in private immutable content-addressed storage;
staging grants no catalog admission, selection or control. Publish complete files
with verified hashes and durable file/directory synchronization before recording
a Store reference. Reopen and verify the bytes actually used. Prevent path
traversal, symlink/ancestor substitution and concurrent replacement under the
chosen host custody model; filenames come from validated digests, not authors.
An administrator controlling the host is outside this custody guarantee.

The implemented inert custody owner requires a host-selected canonical path
without symlink ancestors, a private 0700 root and immutable 0400 files. It
pins path-component and descriptor identities, serializes publication within
one Home VM, and synchronizes the exclusive stage file and directory before
returning success. Its quotas are at most 128 objects, 4 MiB of retained bytes
and 32 monitored caller leases. Incomplete stages consume quota without
becoming published artifacts. Restart removes only a verified temporary hard
link to its exact complete digest-named file. The host must place this owner
under its existing ownership gate before exposing a production lifecycle;
this inert module does not claim a separate cross-process controller lock.
Provenance additionally rejects Unicode control and format characters,
including invisible bidirectional formatting.

The first admission policy is explicit locally provisioned digest approval,
scoped to a supported binding and its exact dependencies. Record the author
claim separately from this operator approval. No default publisher or wildcard
approval exists. Local approval and target selection are authenticated durable
decisions; development unsigned staging/preview cannot become an approval.
Trust-policy changes use the maintenance barrier and WOH.05 host authority.
The implemented `profile:manage` permission is separate from enrollment, physical
qualification, rule management and control, and needs explicit provisioning.
Trusted foreground provisioning issues this permission with no control targets.

A later publisher mode must define signer/key custody, signature encoding,
thresholds, expiry, rotation, revocation and persistent rollback protection
before admission accepts signatures. A signature verifies provenance under
that policy, not Home grants or physical truth. Do not implement an ad hoc
network updater under the local approval mode. TUF, if selected for distribution,
needs its full metadata workflow; the local policy does not claim TUF conformance.

Locally retained explicit approvals have no network freshness requirement.
Known local revocation or policy withdrawal blocks dependent effects at their
current guard boundary. Home cannot claim knowledge of an offline publisher
revocation it has not received. An expired distribution metadata file blocks
new update admission; it neither silently becomes valid offline nor rewrites a
previous local approval. If a later policy introduces time-limited local use,
its trusted-clock, expiry and offline behavior need a separately versioned policy.

## Review and selection

**H18-04.** Keep staged, structurally valid, locally admitted, target-selected
and physically qualified states distinct. Matching reported identity is a review
hint, not authenticated device attestation. Selection requires a fresh host-held
capture, exact enrolled Thing identity/firmware, a derived declaration and an
operator-visible semantic/permission diff. An existing capture cannot be reused
against a changed artifact or policy. Legacy TOFU remains labelled as such.

Review binds artifact/projection/dependency identities, host binding/runtime,
trust-policy generation, authority epoch, global Store revision, current Thing
resource and enrollment revisions, current profile selection generation and
affected rule generation. Preparation may run outside Store; commit reauthenticates
the principal and repeats every relevant pin in its transaction. A stale or
ambiguous review is rejected, never repaired by choosing a newer profile.
Enumeration and quarantine have independent capacities and cannot exhaust the
authoritative storage reserve or admit an unbounded transaction.

Profile management authorizes artifact lifecycle only. Enrollment still requires
`enroll:review`; physical qualification still requires the separate reviewer
and exact claims; control still requires its current target/operation grants.
Existing Thing grants cannot implicitly gain new executable operations through
profile selection. First delivery permits only the same narrow power declaration
or a reduction. Any future widening requires explicitly scoped grant changes
and requalification, separately reviewed and committed; old credentials do not
inherit it. A catalogue update alone changes no enrolled declaration.

The v1 data format cannot reference executable helpers. Helper integration needs
a separately versioned format and reviewed binding that declares exact component,
world and host dependencies; reusing this lifecycle does not make v1 executable.

## Durable transitions and effects

**H18-05.** Admission, selection, revocation and rollback have immutable
principal/epoch/operation identities with canonical content and scoped status
lookup. Exact retries return the original historical receipt without another
revision; changed content conflicts. A historical successful selection is never
presented as the current selection after a successor or revocation.

The Store owns one append-only selection history and current per-Thing generation.
The first implementation uses the existing global maintenance barrier for these
changes, rather than inventing a concurrent live-upgrade protocol. Selection
requires maintenance to be active and invalidation to be committed; maintenance
end never activates rules, refreshes facts or restores qualification. The
selection transaction still validates affected work because pre-barrier reviews
and historical claims may exist. A later per-Thing barrier needs new evidence.

One transaction changes the selection/resource generation, revokes prior
qualification, clears current reports/source grants, rejects unsent work and
suspends dependent rules. Conservatively suspend the current rule policy until
dependency-specific invalidation is justified. Preserve handed-off uncertainty,
immutable receipts and spent roots. Revocation must remain possible during
maintenance or artifact loss; it uses retained identity, not executable bytes.
Rollback is a new selection of retained compatible bytes, never a decrement of
generation or resurrection of an old authorization.

Every observation commit and effect admission, claim and final handoff repeats
current artifact availability/trust/selection, resource/enrollment, grants,
epoch, applicable rule and exact qualification checks. Old workers cannot make
their outputs current after selection changes. Native decoding and compilation
stay outside the SQLite transaction. Use verified bytes/immutable handles and
recheck their pins at commit; filesystem and SQLite do not share a transaction.

Pure calculations may be retried under the same immutable inputs without creating
facts. Physical effects use WOH.14 handoff rules: timeout or loss after handoff
is unknown, no automatic replay, and ACK is not observed state. A retired helper
does not prove a device stopped acting. Safe no-send reconciliation may preserve
history; never substitute a new decoder to reinterpret an old report or claim
command causation from a matching readback.

## Qualification and dependency closure

**H18-06.** Qualification binds the exact raw artifact and semantic projection,
binding, registry, device/firmware cohort, Home/UDP runtime and relevant host
configuration. Executable helpers additionally bind component/WIT bytes and
native runtime/config/containment under WOH.17. Data portability does not mean
equal host behavior or inherited physical qualification. Installation, good
vectors, signatures and compilation cannot satisfy physical cases.

Retain the current complete Home/UDP compiled-code basis. A future smaller
dependency projection must show that omitted code/configuration cannot change
the reviewed mapping, proof or effect guard, with mutation/correspondence and
host evidence. Core policy, adapter, Store or mapping changes reopen affected
qualification. A helper is allowed only for a named mapping need and measured
benefit over an existing declarative or reviewed host binding.

## Retention, disk pressure and recovery

**H18-07.** Artifacts referenced by active selections, durable histories,
receipts, in-flight work or retained backup manifests are pinned. Garbage
collection uses Store-owned references plus staging/invocation leases, serializes
with admission/selection, and never deletes a published object merely because
the last current pointer moved. If safe retention exceeds capacity, reject new
admission; do not discard authoritative evidence. Explicit history retirement
requires its own archival policy and cannot erase replay tombstones.

Disk-full, failed synchronization and partial publication leave no active
partial artifact. Filesystem publication followed by transaction failure may
leave an inert orphan; a Store reference to missing/corrupt bytes blocks
dependent work, records health and never substitutes another version. Preserve
availability of independent Things where the corruption boundary permits it;
corrupt authority/journal links still fail the writer closed.

Schema, startup integrity and each supported historical backup table set must
be updated together. Backups list exact profile/helper bytes, trust approvals,
dependencies and qualification custody. Transfer missing objects with byte
verification before an explicit fenced restore. A restore remains quarantined,
cannot reactivate credentials or old selections by inference, and leaves rules
suspended and freshness unknown until current review. Migration labels existing
compiled profiles as compiled provenance; it cannot fabricate external admission
or qualification. No schema version is allocated by this target document.

## Acceptance

H18-T1: independent authors deliver data profiles without rebuilding Home; wrong
format, duplicate keys, nesting, identity collisions, missing dependencies and
unknown bindings fail under finite bounds without loading executable code.
H18-T2: matching, ambiguity, spoofed firmware and reused/stale captures cannot
admit a target; an operator reviews the exact artifact and semantic diff.
H18-T3: lifecycle permission, enrollment, qualification and effect grants remain
independent; selection/rollback cannot widen any existing credential.
H18-T4: concurrent trust/profile/Thing/rule changes and revoked authors fail CAS;
real transaction failures roll back selection, invalidation and journal together.
H18-T5: lost replies, duplicate operations, restart and superseded status retain
original receipts without claiming currentness or refunding causal reservations.
H18-T6: every observation/effect boundary rejects stale artifact/generation;
handoff races, ACK-only, contradiction and timeout retain honest uncertainty.
H18-T7: offline admission/control with provisioned approvals work without an
engine or registry; withdrawn trust and expired update metadata fail closed.
H18-T8: missing/corrupt files, disk exhaustion, publication crashes and concurrent
GC cannot substitute bytes, erase referenced history or activate partial data.
H18-T9: historical-schema backups, migration, quarantined restore and incompatible
rollback preserve custody, tombstones and disabled authority until review.
H18-T10: same data identities run on independently inventoried macOS and exact
Nerves hosts; signed/board/storage and device-cohort cases pass separately.

## Current implementation boundary

`Profiles.Codec`, `Artifact`, `Bindings` and `Custody` implement bounded inert
import, the fixed host binding, exact identities and private publication/leases.
Authority and Store implement local digest approval/revocation under separate
management permission and active maintenance, original scoped retry/status and
retained catalogue. Approval grants no target authority. A public import route
remains unfinished; the shared Host now supervises private custody/reviews.

Trusted selection now snapshots every authority/trust/Thing/rule pin and consumes
fresh operator-bound evidence into a bounded held review. Store-owned commit
checks original receipts before CAS or files, checks out the exact proposal,
rereads bytes/runtime outside SQLite, repeats current basis/history correspondence
inside the transaction and enforces the original capture deadline before commit.
Compatible replacement changes the declaration/resource/binding/selection in one
transaction, clears current reports/source grants/overrides, revokes qualification
and preserves original evidence and causal spend. Current rule policy must already
be suspended by maintenance. Target and artifact revocation record explicit
unavailable generations, work invalidation and uncertainty counts; reapproval
cannot restore an old selection. Missing files permit historical lookup and
revocation, while current dependent work stays unavailable.

Schema 20 validates selection chains, scoped parents, original enrollment reviews,
trust/resource generations, exact current pointers and observation/request/rule/
qualification pins in both directions on live use, startup and encrypted recovery.
Schema 19 keeps its original empty selection/pin requirement. Canonical metadata
and historical declaration projection remain verifiable without today's installed
registry. Call-local byte/runtime checks are cleared after every Store call and
excluded from archives. Coarse enrollment cannot activate an approved portable
label; ordinary narrowing/review cannot bypass an existing selection. Missing
bytes keep dependent facts unknown; corrupted authority links disable writes.

Qualification snapshots preserve guarded declaration/actor/epoch/review provenance
and explicitly unknown migrated fields. New verified qualification may replace
only a revoked head; original retry returns its original revision without restoring
current authority. Backups list every retained claim and raw/projection/registry
dependency; quarantine never activates these histories.

Store-controlled collection accepts a serialized retained-reference snapshot only
from its configured Store owner under active maintenance and management permission.
Every retained artifact, including revoked approvals, and every monitored lease
stays pinned. Collection changes no authority revision or receipt and cannot
repair missing dependencies. The shared Host now wires both owners after Store ownership; installed storage
qualification remains open.

The v1 review keeps its exact prior firmware correspondence. V2 separates the
Store's prior tuple/declaration from fresh captured identity. Initial selection
records an absent target with null prior identity/declaration and zero CAS pins,
then creates enrollment, review and first selected generation atomically without
control grants. Occupied stable identities and revoked targets are rejected.
Replacement preserves stable identity/manufacturer/model and no-widening semantics;
changed firmware must match an exact newly approved artifact version and gets a
new reviewed identity. Old qualification remains revoked until new signed evidence
binds the new basis. Both review versions validate retained journal/predecessor
correspondence at startup and encrypted recovery. Public operator flows and
hardware/installed-host acceptance remain unfinished.
The shared Host now starts private custody and reviews after the Store lock,
with canonical root paths and downstream consumer restart barriers. Existing
compiled enrollment continues independently. The
[ledger mechanism](portable-profile-ledger-v1.md) and
[build plan](../plans/portable-profile-admission.md) describe these delivered
boundaries; the catalogue remains partial with evidence missing. Synthetic signed
fixtures establish ledger behavior only and introduce no qualified physical host.
