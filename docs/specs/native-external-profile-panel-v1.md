# Native external-profile decision review

Version: 0.1.7. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09 and H08-T1/T5/T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08 and H18-T6/T8/T11/T12.
Implementation: local selected reads, complete-file review/confirmation and app composition implemented.
Evidence: [native/Store, retirement/CAS and mounted layout checks](../provenance/native-external-profile-panel-2026-10.md).
The [selected guided successor](native-external-profile-guided-v1.md) is implemented
with [executed evidence](../provenance/native-external-profile-guided-2026-10.md).
[Paired consumption](native-paired-external-profiles-v1.md) now has bounded software
evidence; positive installed signing and qualification remain open.

## Result and scope

The Things task offers explicit external catalogue/history reads and a separately
confirmed first inspection, trust or target decision. This delivery accepts a
complete private decision file through the implemented [original codec](native-external-profile-originals-v1.md).
It binds human review to the selected current controller, publishes the original
through [v9 custody](native-pending-external-profiles-v9.md), and uses the
[fixed SDK](native-external-profile-sdk-v1.md) and Activity original recovery.
Inspection, approval, selection, grants and reports remain separate facts.

This owns local selected first decisions, model lifecycle and visible review.
Paired consumption is owned by the paired successor; guided construction
is owned by the selected guided successor.
The [guidance API](external-profile-guidance-v1.md) now exposes current host-held
reader, source-selection, target-counter and owned inspection artifact data.
The [native typed read contract](native-external-guidance-reads-v1.md) defines
strict decoding and identity bracketing, with
[executed peer/Store evidence](../provenance/native-external-guidance-2026-10.md).
The [pure builders](native-external-profile-builders-v1.md) now have
[independent/native and actual Store evidence](../provenance/native-external-profile-builders-2026-10.md).
Selected guided composition now obtains fresh inputs under its own contract.
No builder derives these facts from an
authoring-contract digest, a report or editable endpoint.
Complete files supply explicit originals here; the Store still decides current
source/reader/import/counter admissibility. This is not complete installed v2 UX.

## Inputs and explicit reads

**NXP-01.** Kind is exactly inspection/trust/target. An explicit file picker accepts
one absolute file URL, at most1024 UTF-8 path bytes. Read with the existing
NativeAuthoringFiles descriptor owner/mode/link/name checks: same-user 0600 regular
one-link file, no final or ancestor symlink, bounded complete read and unchanged
descriptor/name metadata. Never rewrite, chmod or log the file. Native JSON limits
are65536/16384/131072 bytes respectively; the codec separately applies complete
canonical16384/4096/32768-byte limits and strict fields/types/nullability.

Catalogue refresh and original lookup are explicit buttons. Original lookup takes
a positive S64 canonical decimal epoch and Home operation ID (1–128 ASCII bytes,
initial alphanumeric then alphanumeric/dot/underscore/colon/hyphen). Kind selects
its owning status namespace. Validate input before credential work. Display missing
as missing; do not reconstruct an original or treat historical approval as current.
Opening, navigation, file/input selection, editing, startup and timer ticks send
no request. One task at a time uses the shared driver reservation.

Local selected reads capture only existing custody, check native original verifier/
owner/principal if present, then bracket domain reads with authenticated identity.
Catalogue requires equal before/catalogue/after Store revisions and current epoch.
History requires the same active authority/principal, nonregressing watermark and
coverage of its receipt revision; the requested historical epoch may differ.
Current profile:manage is required; target history additionally requires enroll:review.
Paired selection refuses before files, credential, clock, signing or transport;
there is no automatic local fallback.

## Read-only preparation and review

**NXP-02.** Prepare validates the entire file before credential capture, then binds
one actual local selection snapshot/generation, exact credential/reference and
authenticated controller identity. Read the external catalogue and exact original
status, then identity again. Require all Store watermarks equal, unchanged authority/
principal, matching current original epoch and expected_revision, and no existing
original result. Catalogue establishes profile:manage; target status establishes
its extra current permission. A changed file/identity/revision refuses without
publication, operation-ID allocation, silent CAS editing or producer work.

For trust and target, require expected_policy_generation equals the catalogue
generation and expected_trust_revision equals that artifact's current catalogue
trust revision (zero when absent). A new trust approval may name an absent digest;
target decisions require a retained catalogue entry. Target selection requires
approved state; revoke may use revoked/author_unavailable history. Current target
selection/resource counters, inspection admissibility, raw imports and source
checkout remain exact Store checks; preparation does not claim to validate them
from an API that does not expose them.

Prepared construction is private to the selected driver and retains exact checked
bytes, capture and selection/identity basis. Reflection redacts private data.
It also owns a one-way, thread-safe retirement reference: anybody holding the
decision may retire it, nobody may reactivate it. This reference grants no authority.

Show the decision's action and consequences, current controller/principal/owner,
epoch/operation/CAS and canonical SHA. Inspection shows its reader basis and
envelope/profile handles, profile reference and definition count; it grants no
approval. Trust shows exact artifact, previous trust/policy and explicit inspection
reference on approve; approval grants no target selection. Target shows action,
target/artifact/trust/policy, previous selection/resource and select's source
reference/owner/selection hash; selection grants no access and replacement/revoke
withdraw existing target grants. Do not show full JSON, bearer, private path, raw
payload, private physical identity or invented current source truth. Basename may
identify the file. Long IDs/hashes wrap at all supported responsive widths.

## Confirmation, retirement and publication

**NXP-03.** Confirmation is a distinct checked toggle and Submit action over the
same frozen decision. Reacquire existing custody and compare its complete bytes/
reference to preparation. Repeat the current read-only basis and compare identity,
Store revision, policy/trust and original. Preserve selected metadata/generation;
no automatic reprepare. Check the decision lifetime before/after each asynchronous
hop and before credentials, publication and SDK delivery. Parent-task cancellation
also retires it immediately, including while a detached request worker is waiting;
that worker cannot regain permission when a reply eventually arrives.

A scoped additional local request check composes with the existing selected-local
fence. It may only refuse: check before opening each request, immediately before
writing its frame and after reading the reply. Nested checks compose, not replace
one another. It cannot create a credential, select an endpoint, bypass native peer
leases or turn original recovery into selected work. This prevents a decision
retired between SDK status and mutation from sending that mutation.

Retain the entire input under v9 with the exact expected controller/capture before
calling the SDK. After publication, recheck the actual retained original, lifetime
and selection, then run the fixed SDK in that same request-check scope. A verified
receipt and still-live decision may begin whole-file CAS resolution. If invalidation
wins before that point, retain the original; late delivery cannot authorize a new
send or remove an unconfirmed original. Once verified resolution has begun, later
presentation retirement may hide its confirmed result but does not undo that fact.
Failed publication/resolution marks reload needed and retains existing uncertainty.
All first refusals retain the original; this panel has no initial-error cleanup list.

Input/kind/session/access/sleep/wake changes retire preparation and delayed display.
The model clears confirmation immediately on Prepare/Submit/failure/invalidation.
Duplicate clicks and other app work use shared busy guards. A retired prepared
response is retired again on arrival and discarded. An already sent request is
not cancelled or rolled back by display retirement; Activity keeps its original.
An explicit subsequent read can show the immutable receipt and separately refresh
the current catalogue. No automatic refresh follows mutation.

## Acceptance

Use the frozen original/receipt corpora, actual Authority/Store/UDS and independently
expected request sequences. No fixture may create a successful signing backend.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NXP-T1 | 01/02 | All kinds/actions/families, strict private files, catalogue/history, current policy/trust, malformed IDs/integers, wrong owner/epoch/CAS, paired selection. Unsafe read, stale review, fallback or preparation write fails. | Native/framed/Store |
| NXP-T2 | 02/03 | Delayed prepare, changed file/input/custody/selection/wake, fresh confirmation, retirement/cancellation between status and mutation, nested request guards and duplicate clicks. Re-enabled lifetime, stale send or bypassed original/peer guards fails. | Native/actual socket |
| NXP-T3 | 03 | Real two-family first inspection/approve/select/revokes, actual failed publication/resolution, lost reply and Activity restart recovery. Mutation before publication, missing original or premature success/removal fails. | Store/private file/process |
| NXP-T4 | 01–03 | Mounted idle/prepared/confirmed/success/missing/uncertain/error at480/599/600/839/840/1320 widths and normal/enlarged text. Clipped facts, implicit requests, private payload display or false active-state claim fails. | Native visible software |

Record exact source/toolchain/fixture/commands/results and remaining guided-builder,
paired, installed accessibility/signing, publisher and physical obligations. No
Store schema, dependency, producer API or physical dispatch change is required.
