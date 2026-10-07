# Portable profile implementation and review plan

Version: 0.1.13. Updated: 2026-10-07. Accepted build order; inert import, local approvals, reviewed replacement, retained pins and collection implemented, shared operator routes implemented, native presentation unfinished.
Decision: [ADR 0010](../decisions/0010-data-first-profile-admission.md).
Contract: [WOH.18](../specs/WOH.18-portable-profile-admission.md).
Research and source disposition: [consolidation](extension-consolidation.md).

## Platform result

Separate delivery from control authority. A profile author can add a supported
fingerprint/declaration selection without a Home build. An automation author
can deliver existing bounded rule source without an interpreter. When a mapping
actually needs new computation, an optional WIT helper supplies a typed portable
binary rather than runtime Elixir source. New protocol ownership or capability
meaning still requires a reviewed host binding. All three enter existing Home
review, current guards and evidence; none owns credentials or SQLite.

The narrow first data format deliberately cannot describe every future device.
Its testable benefit is moving exact catalogue membership out of the host build
while retaining the current power mapping. It does not promise that arbitrary
new devices can be supported without a host release or physical qualification.
An imported profile for an already-supported tuple proves admission mechanics;
a new tuple supported by the pinned registry proves independently delivered
membership, still pending actual cohort evidence.

## Source audit and proposed structure

The audit is complete for the first path. These existing boundaries are retained:

| Existing source | Observed behavior / extension seam |
| --- | --- |
| `Lifx.ProfileCatalogue` | Compiled exact fingerprints plus one host-authored Boolean declaration; external import absent |
| `Discovery.Profile`, `EnrollmentReview`, `CaptureSession` | Bounded matching, ambiguity rejection, host-held one-use evidence and reviewed identity; matching grants nothing |
| `Authority.commit_lifx_capture` | Derives operator and compiled declaration; initial/re-review commit rejects caller-authored evidence |
| `Store.EnrollmentWriter` | Authenticated current retry, unique reviewed identity, tombstones and transactional invalidation; re-review requires the same current profile |
| `Lifx.ProfileBasis`, `Store.QualificationWriter` | Pinned registry/full Home+UDP inventory and exact signed physical claims rechecked during execution |
| `Rules.Codec`, `Compiler`, `AdmissionArtifact`, `Store.RuleWriter` | Closed source/IR, restricted single-effect admission, generation barriers; reuse this path rather than a new automation format |
| `Store.Schema`, `Integrity`, `Durable.Backup` | Schema 20 with retained local approvals and qualification snapshots, validated replacement/owner pins, historical table sets and quarantined recovery |
| `Plugins.Bundle`, `IPC`, `Runner` | Independently installed pure preview only; no durable activation or truthful-observation guarantee |

Proposed modules remain namespaces inside the one Mix application:

| Planned location | Responsibility |
| --- | --- |
| `lib/wotex_home/profiles/artifact.ex`, `codec.ex` | Closed v1 byte parser, identities, finite validation; no I/O or authority |
| `lib/wotex_home/profiles/bindings.ex` | Reviewed host binding IDs and derived declarations; never resolve author module names |
| `lib/wotex_home/profiles/custody.ex` | Private immutable publication, verified byte reads and bounded leases; no active pointer |
| `lib/wotex_home/profiles/review.ex` | Exact capture/declaration/dependency/policy diff; proposal only |
| `lib/wotex_home/authority.ex` | Authenticated admission/selection/revocation/status sequencing |
| `lib/wotex_home/durable/store/profile_writer.ex` | Stateless borrowed-handle operations invoked by Store; history, CAS, trust and generation barriers |
| Existing schema/integrity/backup/execution writers | Historical compatibility and current profile pins at each transition |
| `priv/profiles/`, `test/support/profiles/` | Authored public examples, schema and adversarial fixtures; no hardware identities |
| `native/components/` | Optional helper ABI/SDK/containment only, governed by WOH.17 |

The parser, artifact, binding, custody, approval writer and selection review
locations now exist; active transitions and guard integration remain proposed.
Runtime code uses authored data/fixtures,
never parses these Markdown contracts.

## Work packages and stop conditions

| Phase | Concrete work | Exit evidence |
| --- | --- | --- |
| P0 — reconciliation | Classify compiled data, rule source and executable mappings; settle ADRs, contracts and source disposition | This audit and catalogue alignment; no implementation promotion |
| P1 — inert data import | Implement WOH.18 v1 schema, streaming bounds, raw/projection identities, fixed binding table, finite storage/staging quotas and durable immutable publication; independently authored examples | H18-T1/T8 parser/custody tests, no Store pointer or network; same-label different-byte conflict; pinned dependencies unchanged |
| P2 — durable lifecycle | Add explicit permission/trust provisioning, immutable operation receipts, local digest approvals, admission and per-Thing selection under global maintenance | Real SQLite H18-T2–T6 cases; every invalidation/unknown count and rollback tested, startup integrity and historical status |
| P3 — retained recovery | Add profile pins to observation/effect/qualification/rule artifacts, backup dependency manifests, quotas/leases/GC and schema migration | H18-T5/T8/T9 restart, historical archive and damaged-link tests; missing bytes block without replacement; no active restore |
| P4 — local author/operator flow | Closed Authority/CLI/API import, review, select/revoke/status; display exact identity, semantic diff, separate qualification and historical/current state | Principal-private lost-reply/retry fixtures and API parity; H18-T3/T7 offline operation with runner absent |
| P5 — delivered data profile | Package examples/custody inventory on the actual host; qualify one independently delivered exact cohort | H18-T10 signed Mac / selected Pi 4 / storage and physical cases separately; dispatch stays off until actual obligations pass |
| H1 — optional helper decision | Name a decoder/encoder need outside reviewed data bindings; compare host release, data projection and helper cost | Benefit report plus executable/dependency trust boundary; no new world just for speculative flexibility |
| H2 — helper hardening | Close WOH.17 retirement capacity and compilation/lifting/native memory/OS containment; then add needed typed world | Actual hostile-start, flood/cancel/restart, resource and host evidence before production |
| H3 — helper integration | Join WOH.18 profile lifecycle and exact qualification to verified component results | All data lifecycle cases repeated with component loss/revocation; no new transport/credential owner |

H3 requires a separately versioned profile format/binding for helper dependencies;
v1 only references the existing registry and cannot activate component metadata.

P2 and P3 must ship together before active external profiles are possible; a
partial schema cannot retain references that backup/integrity do not understand.
Before P2 code, commit the executable receipt/row encodings, chosen migration
version and precise projection digest fixtures as one mechanism design. Use the
next actual schema version at implementation time, not a reserved number here.
Before P4, specify route fields/frame limits and credential provisioning; no raw
filesystem path or executable loader enters the public request vocabulary.

P5 data delivery does not depend on H1–H3. Brokered I/O, async resources, warm
pools, native caches, additional author languages and automatic distribution are
later proposals with named benefits and separate gates. Pure and physical work
do not share retry policy. Existing rule source can be distributed now, but its
restricted supported admission and lack of autonomous scheduling stay explicit.

## Difficult paths to prove

| Case | Required assertion |
| --- | --- |
| Duplicate keys, deep nesting, oversized metadata or author-selected module | Reject before unbounded allocation; no evaluation, atoms or module loading |
| Same id/version, new bytes; equal semantics, different serialization | Raw identities remain distinct; admitted label conflict; no silent replacement or evidence transfer |
| Multiple matching profiles or changed reported firmware | Explicit selection and current host capture; no rank supplied by author, stale hint or label fallback |
| Trust/Thing/epoch/rule changes while review is external | Commit CAS rechecks all pins; no partial selection, grant widening or stale active evidence |
| Revocation during held/queued/claimed/handed-off work | Unsent work invalidated; handed-off uncertainty and roots retained; old result cannot become current |
| Lost commit response and later successor | Original scoped historical receipt; current status shown separately; no replay as a new operation |
| Artifact removed or substituted after prepare | Verify pinned bytes/lease before use and commit; missing/corrupt bytes fail dependent work, never use a sibling version |
| ENOSPC/fsync failure or crash between publication and Store commit | No active partial object; orphan harmless; writer reserve and authoritative history preserved |
| GC races install, invocation, selection or backup | Leases plus Store references protect bytes; reject capacity if all objects remain referenced |
| Old backup/schema, missing external files or key-policy rollback | Correct historical table set and exact dependency inventory; quarantine, no inferred freshness or authority |
| Offline with engine removed; update metadata expired | Data-only use works from local approvals; new update fails; no network or optional engine required |
| Helper returns plausible false data or unsafe payload | Qualified decoder scope/independent semantics and existing guards required; preview never commits facts |
| Timeout/caller loss followed immediately by another job | Native retirement observed before production slot reuse; no PID-reuse inference or process-count escape |

Per-Thing selection never grants new control semantics in v1. The first global
maintenance barrier intentionally sacrifices upgrade availability for a simpler
auditable transition. Narrower barriers, dependency scopes and GC retirement are
future changes with their own evidence, not hidden optimization assumptions.

## Contract and documentation ownership

| Owner | Consolidated requirement |
| --- | --- |
| WOH.01 | Existing closed semantic vocabulary and WoTEx TD/TM ownership retained |
| WOH.02/03 | Data admission separated from matching, enrollment and qualified protocol mapping |
| WOH.04/07 | Reuse source/compiler/proof; bind profile identity, suspend stale dependent rules; keep full runtime basis |
| WOH.05 | Independent future profile permission, local trust, hostile data/helper model, alarm restrictions |
| WOH.08/09/11 | Runner optional; actual signed/board and exact physical evidence, no data portability inference |
| WOH.14/15/16 | Single-writer lifecycle/receipts, current rechecks, scoped operations, custody/retention/quarantine |
| WOH.17 | Optional executable ABI/containment; development limitations, helper promotion gates |
| WOH.18 | Portable data format, admission/trust/selection and acceptance cases |
| Architecture / ADRs / implementation plan | One ownership diagram and this shared build order |
| Native host guides / component guide | Host-specific delivery procedures; no production procedure invented from a Mac preview |
| Research / validation records | Baselines preserved with reconciled status and source ledger; measured evidence remains historical |

Update owning versions/catalogue whenever behavior changes. Catalogue checks
prove metadata/dependency consistency, not the above acceptance cases. P1–P4
need focused parser/custody, real Store transaction and framed API tests; P5/H2
follow the owning host guides. Never count synthetic claims as a physical pass.

## Current checkpoint

P0 has an audited decision and plan. P1 implements bounded inert import, authored
schema/examples, fixed binding, private immutable custody, monitored leases,
quotas and publication recovery. Raw serialization and semantic projection have
separate identities; data can describe a supported registry product outside the
compiled catalogue without a Home rebuild.

P2/P3 now deliver maintenance-gated local digest approval/revocation, explicit
management provisioning, immutable scoped operation retry/status, held one-use
selection reviews, compatible reviewed target replacement, target revocation,
validated selection chains and owning-domain observation/request/rule/qualification
pins. Schema 20 preserves all qualification snapshots and original historical
identities, validates both directions of journal/review/receipt/pin ownership,
and retains exact schema-4–19 recovery validators. Missing files keep current
work unavailable without deleting history or disabling independent compiled use.
Artifact revocation retains each dependent barrier; later approval cannot restore
a selection. Ordinary narrowing/rereview requires the selection lifecycle after
a target has selected an external profile.

Store-controlled collection keeps every retained artifact and active lease pinned,
serializes its snapshot against lifecycle/backup work and removes only inert
unreferenced bytes/stages. TEMP byte/runtime commitments live for one Store call
and are absent from encrypted archives. Restored history remains quarantined.

The v1 review preserves exact unchanged-firmware correspondence. V2 now creates
an absent target's enrollment/review/first selection atomically without grants,
or captures changed firmware against an approved exact version while preserving
the prior tuple/declaration and refusing widening. Occupied stable identities and
revoked targets stay unavailable. Their authored encodings were committed before
the writer consumed them, and startup/archive validation retains both versions.
P4 now wires trusted custody/review owners after Store ownership in the shared
Host. Closed API/CLI routes now follow the authored mechanism; native operator
presentation remains. P5 and H1–H3
remain open. The WOH.17 preview keeps its independent optional runtime path.
Physical, installed-host containment and storage gates are not qualified by
synthetic signed claims, fixture packets, SQLite rollback or software restart.

Focused SQLite/Authority tests now cover real held selection commit, exact lost-
reply retry without bytes/review custody, scoped conflict, missing dependencies,
runtime mismatch, expiry/review-owner loss, target/artifact revocation and
reapproval without fallback, ordinary lifecycle bypass rejection, successor
request/rule/qualification pins, retained original claims, rollback after all
barriers, restart and encrypted recovery. Missing/corrupt pins in all four owning
domains reject integrity verification. On 2026-10-07 the full Mix suite passed
658 tests with zero failures; four opt-in component-native tests were skipped
because `WOTEX_HOME_COMPONENT_NATIVE_TESTS` was unset. Socket tests ran. Format,
warnings-as-errors compilation, catalogue validation and Git whitespace checks
passed. Mix also reported the existing unmatched support-file load-filter warning;
no assertion or compiler failure resulted.

On 2026-10-07 the initial/firmware transaction slice passed 347 focused durable,
portable-profile, Authority/history and LIFX-basis tests with zero failures and no
socket exclusions. It covers a scripted registry product outside compiled
profiles, no granted targets or qualification, occupied identities/tombstones,
complete initial rollback, prior/current firmware review and signed qualification
history, startup and encrypted verification. Format, warnings-as-errors
compilation, contract catalogue and Git whitespace checks passed. These results
are software fixture evidence; the earlier full-suite result belongs to the
preceding replacement slice.

The shared Host custody/review slice passed nine focused host tests on
2026-10-07, including real local socket lifecycle, competing Store ownership
before namespace creation, canonical OS aliases, refusal of nonprivate/symlink
roots, caller lease cleanup and Store/custody/review/downstream-worker restart
ordering. It creates no credential or profile approval. Fifty broader host/API/
profile tests and six route/peer-identity tests passed, as did
`mix woh.native.live.host.smoke`: the compiled Swift client authenticated against
the actual private foreground host. Format, warnings-as-errors compilation,
catalogue metadata and Git whitespace checks passed. Native app identity,
firmware boot and physical storage are still unqualified.

The P4 shared operator slice implements all nine authored closed routes and CLI
commands, plus explicit foreground manager/operator bootstrap with independent
permissions and zero targets. Maximum import bytes fit the existing frame;
canonical Base64, duplicate/nesting/extra fields and private descriptor custody
are checked. Reviews expose prior/captured identity and pending qualification.
Actual socket/CLI tests retain one-use review identity and original receipts
after missing bytes/review-owner loss; framed initial/changed-firmware,
principal-private status/cancel, metadata availability and Store-owned collection
cases pass. Native profile presentation, fresh host artifacts and physical/
installed-host qualification remain later work.

On 2026-10-07 the shared API/CLI slice passed 57 focused profile/Authority/host
cases and 31 adapter/CLI/byte-context/review-owner regressions, with zero failures
and no socket exclusions. A real reply is dropped before retaining its body,
then resolved by original epoch/operation. Format, warnings-as-errors compile,
contract catalogue and Git whitespace checks passed. These are shared software
checks; native presentation and fresh artifacts are still subsequent work.

The next P4 native client slice now implements all nine routes with exact
original-operation hashes and closed nested status/review decoders. Independent
peer fixtures cover malformed shapes, absence/revocation, initial/replacement
identity and changed-firmware status. Live Swift/CLI parity on a disposable
foreground host covers import, approval/revocation, original receipts, catalogue/
target snapshots and collection. Existing health/drip deadline, read-watermark,
rule and maintenance native fixtures pass after the global duplicate/depth scan.
Window composition and native capture/selection live correspondence remain next;
no fixture supplies installed-host or physical acceptance.

On 2026-10-07 the native client passed 61 independent profile peer cases and the
expanded live Swift/CLI receipt parity task. Existing native health/drip-deadline,
read-view watermark, rule-policy and 32-case maintenance checks passed. Swift 6
arm64 macOS 15 compilation rejected warnings. Mix format, warnings-as-errors
compilation, contract metadata and Git whitespace checks passed. The live check
found and corrected a collection decoder assumption: its actual closed reply
has five fields and does not include a transient lease count. No native window,
installed app identity, firmware or physical qualification was exercised.
