# WOH.14 — Durable state and honest command execution

Version: 0.1.106. Status: accepted target.

## Storage choice

The [independent countdown execution corpus](countdown-execution-traces-v1.md)
compares 68 actual Authority/Store traces with a separate boot-local reference.
Qualified and unavailable wall-time modes cover execution, six restart phases,
sticky clock loss before due, generation withdrawal, source reactivation guards,
author/grant loss, overrides, maintenance and five SQL publication faults.
Every event compares immutable rows and causal spend, and captures a private
complete SQLite image. Each image's integrity is checked after execution;
original lookup follows the actual final author status. These are bounded
software checks, not expanded autonomous admission or host qualification.

The [durable countdown lifecycle](schedule-countdown-lifecycle-v1.md) now binds
new single-schedule content/activation to the actual Store clock and consumes
original continuous-clock coordinates without requiring qualified wall time.
Restart and observed clock-basis loss retain immutable missed barriers and fence
unsent work without refunding spend or replaying handed uncertainty. Final
refusal restores tentative phases before retaining expiry. This adds software
transitions under the existing temporal artifact scope; autonomous/composed
runtime, installed clock/sleep and physical qualification remain work.

The independent execution harness compares complete immutable rows and snapshot
integrity after every event, then checks authenticated original receipt lookup
under the final author status. Redundant identical historical reads no longer
occupy the real report-age window between queue, claim and handoff. Refusal
diagnostics retain actual report age; the fixture changes no clock, facts,
deadlines, production guard or writer.

[Retained countdown clock correspondence](schedule-countdown-clock-v1.md)
adds a distinct inert monotonic format with null UTC and original qualified
continuity/boot/generation/age checks. Existing qualified-UTC history retains
its bytes. Countdown arithmetic still checks a past start and strictly future
due instant; calendar/interval activation refuses these wall-unqualified
snapshots. The separate countdown lifecycle now supplies source-specific Store admission,
consumption and durable missed expiry. It creates no autonomous runner or
installed source qualification.

The separate [calendar execution corpus](calendar-execution-traces-v1.md)
compares actual Authority/Store queue, claim, handoff and settlement with an
independent finite-calendar reference. Sixty-eight traces cover selected daily,
weekday and one-shot sources, including expiry, uncertainty, original author
and grant loss, overrides, maintenance, four publication fault boundaries and
actual Store restart. Internal caller-result loss after commit preserves one
original request. Complete installed-input timelines are checked independently
before admission, and immutable originals and causal spend are compared after
every event. This does not widen temporal admission, create timers or qualify
an installed host or hardware.

An [independent bounded calendar corpus](calendar-durable-traces-v1.md) adds
fourteen actual SQLite consumption traces for daily/weekday folds and gaps,
both reviewed one-shot fold choices, uncertainty without retry, duplicate and
backward polling, restart and bounded missed summaries. A separate Python
oracle checks the actual installed dataset against each complete finite
timeline before admission. Original receipts and complete retained rows remain
immutable. Synthetic timezone authority still withdraws without creating an
occurrence. This expands software consumption evidence, not the temporal
admission scope, autonomous runner or installed/physical qualification.

An [independent durable trace corpus](schedule-runtime-traces-v1.md) compares
real Authority/Store/SQLite transitions with a separate fixed-UTC-interval
reference machine. It checks original dispositions, causal spend, handoff
history, generation and considered watermark after each step, including SQL
rollback, target-grant withdrawal/restoration and same-owner restart. Grant loss
rejects unsent work without refunding spend and preserves committed handoff
uncertainty; restoring a grant needs explicit activation. Failed withdrawal
publication preserves the prior grant, generation and request history together.
Range rows and actual missed instants are
distinct. This supplies software evidence; it does not expand the current
temporal admission basis or enable an autonomous runner.
Override and maintenance traces check terminal blocked consumption, later
phase refusals, unchanged handed work, current generation/boot scope, explicit
reactivation and atomic lease/barrier publication rollback.
Original-author revocation traces retain immutable consideration/effect rows,
spent roots and committed handoff uncertainty while refusing the revoked
credential's activation and private lookup. Failed withdrawal publication
preserves principal status, original activation and pending work together.

[Final power commit guards](power-commit-v1.md) repeat queue, no-send, claim and
handoff authority after Store withdrawal and complete history validation. A
policy refusal undoes the tentative transition while committing any required
sticky suspension against
its original unsent phase. Actual SQL failure rolls back the whole transaction;
already spent roots and durable handed uncertainty remain unchanged. The final
attempt read excludes only its own tentative handoff. A refused final handoff
cannot produce a dispatch receipt or transport packet.
Scheduled advancement restores a failed tentative batch, commits any required
withdrawal and terminalizes its failed unsent identity with actual current
receipts. Retained queued/claimed work repeats ordinary freshness and
qualification guards even on an otherwise unchanged pass. New failed queues
remain unspent; committed reservations stay consumed.
An initial current-basis refusal also commits any required suspension after
undoing tentative work; exact artifact restoration cannot revive that generation.
SQL and historical damage remain whole-transaction rollback failures.

A withdrawal already detected inside that transaction survives savepoint
restoration even when runtime custody returns before the enclosing guard.
Store captures validated lifecycle history, binds the exact original
activation/epoch/generation and rebuilds its barrier against the restored
durable phase. Counts and journals reflect that phase, preserving the distinction
between a tentative and committed handoff. No caller supplies this transient
receipt; failed republication rolls back the whole transaction.

Initial held-power admission and power/colour no-send inspection preserve the
same distinction: only closed semantic refusals are policy. Damaged enrollment
or values and SQL failures roll back all tentative work and disable writes,
retaining original receipts and spend. Raw SQL strings are normalized to Store
unavailability. Valid missing/stale/wrong-boot reports and unsupported control
or coherent-colour planning leave the writer usable.

Advisory held-power/colour readers share that closed semantic refusal set.
Malformed guard inputs and unavailable reports/plans leave writes usable;
other failures disable them. Typed errors remain typed and raw SQL errors
normalize to Store unavailability. Original receipts, revisions and causal
spend stay intact. A transient successful plan never acquires effect authority.

The trusted [prepared schedule poll](schedule-poll-v1.md) calculates outside the
writer from one Store-retained, caller-bound, five-second clock/artifact/cursor
snapshot. Its one-use commit repeats current basis and canonical correspondence,
then shares the existing atomic occurrence/request publication. Forged clock or
cursor data, competing consumption, caller death and restart cannot reuse a
preparation or rewind history. This adds no timer or broader admission proof.

Schema 27 adds [distinct scheduled request provenance](schedule-effects-v1.md):
one eligible occurrence can stage one normal held intent with a separate temporal
causal origin. Queue, claim and final handoff repeat the original activation,
current author/basis, owned qualified clock scope and entire due/late window.
Atomic publication and complete history joins preserve rollback, immutable
originals and spent roots. Migration preserves old roots and gives historical
calculation-only rows no effect authority. Separate
[Store-owned advancement](schedule-advance-v1.md) queues held work without a
bearer, uses exact Store-stamped report freshness, repeats guards after
publication and terminalizes expired unsent work without replay or causal refund.
Each pass processes at most sixteen; actual SQL failure rolls back the complete
batch. Autonomous polling, compaction and composed runtime proof remain work;
physical dispatch stays disabled.

Schema 26 adds [durable occurrence consumption](schedule-occurrences-v1.md):
one deterministic candidate or one bounded missed range, an immutable clock/
calculation record and a cursor projection in the same transaction. Duplicate
polls, correction and fresh-clock same-owner restart cannot replay retained UTC
coordinates. Complete history and cursor correspondence is checked at writer,
startup and archive boundaries. Empty migration manufactures no authority.
Calculation-only schema-26 records remain blocked after upgrade. Schema 27
separately retains new held-request provenance and temporal execution guards;
no autonomous timer is created and physical dispatch remains disabled.

Schema 25 adds the [single-schedule lifecycle](schedule-lifecycle-v1.md):
immutable original activation/suspension operations, owned current clock and
installed timezone checks, generation fencing, post-barrier repeat/rollback and
sticky withdrawal when an authority basis is lost. Exact receipts survive later
suspension, restart and transfer. Empty migration changes no authority; damaged
lifecycle history fails live/startup/archive validation. This Store slice creates
no occurrence or device effect on its own; occurrence retention and temporal
guards are separately described above and physical dispatch stays disabled.

Schema 24 adds an inactive [temporal content ledger](schedule-ledger-v1.md)
for exact original review/admission operations. It binds the separate temporal
artifact to current authenticated author, target, declaration, profile and
invariant inputs under revision CAS. Complete journal correspondence is checked
at startup, archive verification and before/after ordinary writer transactions.
Exact retry remains private and immutable at capacity or after grant loss.
Migration adds empty history without minting activation, time trust or a held
effect. Autonomous occurrence consumption and final temporal execution guards
remain separate work; this content cannot attach timers to explicit admission.

Schema 21 implements the authored [ownership and retirement mechanism](controller-transfer-v1.md):
local origin identities preserve prior epoch/revision, and a separately authorized
maintenance-gated source retirement appends one immutable private receipt and
permanently blocks further source mutations. Original reads and exact-byte export
remain available in the current process; normal startup refuses the retired
source. An explicitly trusted offline source-reader owns the same lock and
validates retired history without migration, socket or worker startup. It permits
only original read/export work and cannot clear quarantine or revive source
authority. Guarded destination acceptance and foreground receiving are now
implemented; real old-writer isolation remains a separate qualification gate.
Canonical destination operations/receipts validate original private scope,
integer epoch/generation and exactly three revision commitments. Source decoding
rejects numerically equal floating revisions in live/startup/archive gates.
Schema 22 now adds bounded acceptance storage and read-only alternating ownership
and transfer-barrier validation. Active schema 21 migration preserves all rows
and authority; retired startup refuses before migration. The guarded destination
writer now performs the atomic three-revision transition with source counts,
retained-row correspondence, private exact receipt lookup and final owner-guard
rollback. The one-use private recovery owner, recovery-mode Store and timed
foreground receiver now repeat actual source/profile custody, original challenge,
current trust and conservative clock guards through that transaction. Key-free
original receipt recovery creates no challenge or acceptance authority. Recovery
stays read-only until closing before separate ordinary Host startup. A fresh
epoch-specific transfer role preserves copied revoked roles; exact retained
[enrollment succession](controller-enrollment-succession-v1.md) permits the
receiving reviewer to recheck compiled identities without target or qualification
grants. Historical crossing and transfer-barrier links validate on startup and
archive use. Full development checks pass 946 tests with four optional native
backend skips; installed storage, accurate clock, physical isolation and device
qualification remain open.

Schema 23 adds [original native target access](native-target-access-v1.md),
with immutable principal/epoch/operation inputs and receipts. Existing native
custody must match before lookup or mutation. Exact committed retries return
history without restoring grants. Reviewed profile/resource/binding changes and
principal revocation withdraw native grants in their owning transaction;
ordinary target revocation also remains effective. Grant/revoke invalidate
principal-scoped held and execution work, retaining causal spend and handed-off
uncertainty. Store transaction guards, startup and archives validate ledger,
journal, selected profile/trust history and actual current targets. Migration
from active schema 22 creates no grant and refuses unexplained native targets
with actual DDL rollback. This software slice provides no public provisioning
route, signed native controls or physical qualification.

Use a hybrid local store: transactional current state and a bounded append-only domain journal. Full event sourcing is not required; migrations should not need to replay every historical sensor sample. ETS holds disposable read projections, not authority. A single host-selected SQLite/Exqlite writer is the reference implementation. No broker, distributed database or database server is needed for one home.

**H14-01.** Persist stable Thing identities, enrollment/profile revisions, active/candidate rule revisions, current observations with quality, override leases, command receipts and outbox entries. High-rate diagnostic telemetry has independent retention and cannot exhaust the space reserved for authoritative records. Model weights, backups and large captures live outside row payloads with bounded content-addressed references.

Schema version 12 adds immutable candidate-review records, not active rules. Each record retains canonical bounded rule data (at most 64 KiB), the reviewed declaration/resource snapshot (at most 32 Things), a closed rejected/pending summary and its content digest, scoped to principal/epoch/operation ID. The complete artifact is bounded to 4 MiB. The Store alone journals and commits it after rechecking current authority and the complete reviewed basis. Startup and backup integrity validate canonical shapes, digest bindings, historical revision ordering and the original journal link without rerunning a native checker or upgrading old evidence. A 1,024-row ceiling rejects new records while keeping exact retries and status available. Migration preserves all prior receipts and generations; candidate history has no outbox, scheduler or effect authority.

Schema version 14 adds one retained causal root for every scoped explicit-request
receipt. `Store.CausalLedger` borrows the writer transaction; it owns no process,
credential, clock or transport. New roots bind their creation revision to the
first held/rejected request event. A root starts unused; accepting its one
depth-one intent reserves it with the exact queued event revision in the same
transaction as the receipt and execution row. Failed transactions reserve
nothing. Claim and handoff repeat the original reservation check. A duplicate
queue admission is only an unchanged receipt read, never another reservation.

Cancelling, abandoning or invalidating unsent work may delete its execution row
but never deletes or refunds the root. Terminal and unknown outcomes retain it;
reconciliation is an evidence refinement, not a new effect. Exact retries and
credential rotation retain the original root identity. Its row count is bounded
by the retained-receipt ceiling; no root-finishing, pruning or reusable-token
operation exists. A new root alone grants no control permission or qualification.

Migration from version 13 or earlier preserves revisions and journal bytes,
labels every old root `legacy_request` with no invented creation revision, and
conservatively reserves any existing execution or prior queue event, including
work already cancelled. Exactly one old queued event supplies a reservation
revision; missing or multiple events leave provenance explicitly unavailable.
Such a spent root cannot be readmitted, and cannot pass claim/handoff without
the original unique queue basis. Unused legacy roots can be explicitly admitted
under the full current guards. Startup and encrypted-backup verification reject
missing roots, invalid counts, refunded queue history, cross-operation/future
event references and inconsistent execution admission links. These are bounded
software intent reservations, not physical cause evidence or admitted-rule roots.

Use WAL with `synchronous=FULL` for authoritative transactions, verified at connection setup; evaluate the macOS VFS/full-sync settings in the host qualification. This is a design choice informed by [SQLite's durability distinctions](https://sqlite.org/pragma.html#pragma_synchronous), not a promise that arbitrary flash media survives power loss. Set foreign keys, finite busy deadlines, checkpoint policy and an explicit disk-space reserve. Backups use a consistent SQLite backup/snapshot procedure, not a copy of only the live `.sqlite` file.

Schema 20 retains immutable qualification history beside the current qualification
head. New records bind the exact declaration, authenticated qualifier, epoch and
reviewed enrollment revision to the original authority event. The 4,096-row
ceiling refuses further admission without deleting evidence. A revoked head may
be replaced only after all current qualification guards pass; retrying an earlier
signed claim returns its original revision and never reinstates that head.
Migration copies existing qualified and revoked slots with explicitly unknown
provenance fields, preserving revisions and statuses. A retained migration
revision prevents later guarded records being relabelled as legacy. Integrity
checks both directions of journal links, current-head equality and original
review/actor pins. Transaction fault injection verifies history and head roll
back together. These tests use synthetic signed claims and establish no physical
qualification. Profile selection remains disabled pending its complete guards.

## Transaction boundaries

Direct-power admission, claim guards, durable handoff, ACK, readback, worker-loss
settlement and generation fencing now compose `Store.ExecutionWriter`.
It receives only the borrowed SQLite handle and the pinned qualification
root/key basis, never Store's host lock, monitors or process state. Store keeps
token issuance, caller ownership, monitoring, clock origins and transaction
commit. Held power/colour inspection and no-send settlement share that domain;
none of these stateless functions can open a device transport.

The single Store retains claimant monitors through `claimed`, `dispatching`
and `protocol_accepted`, including across unrelated authority transactions.
Observed/contradicted settlement releases its live token promptly. An unknown
worker remains monitored until it exits, so recovery cannot race a live
transport; its token cannot advance the terminal unknown receipt. A regression interleaves
unrelated principal creation with both handoff and ACK, then kills the worker:
the same owner can acknowledge and its death records an unknown outcome.

Explicit trusted power reconciliation now refines `outcome_unknown` to
`observed` or `contradicted` without sending or requeueing. It authenticates
the original principal, current read/control permission and target grant,
rechecks authority epoch, the sealed declaration/resource and signed
qualification package, and requires the exact caller-selected current report
revision to be newer than the unknown receipt. The report must be valid,
fresh, production reported Boolean power in the selected current boot epoch.
A still-live claim owner blocks recovery. The reason retains both the unknown
receipt and evidence revisions; an exact retry returns that terminal receipt.
Contradictory evidence records a mismatch, not a failed send. A matching report
does not prove the earlier command caused the state. No public wire recovery
route is exposed, and production restart must use the host's rest-for-one
tree to stop old transport workers before the replacement Store serves work.

Canonical submission, exact retry, receipt decoding and pre-claim cancellation
are now composed by stateless `Store.RequestLedger`. It uses the shared checked
revision allocator and request journal for the initial held/rejected decision,
so an exhausted revision cannot create a partial receipt or outbox row.
Truncated or out-of-range persisted receipt rows return corruption instead of
raising. Store still owns the transaction, connection and worker monitors;
the ledger cannot promote a held request, send a packet or renew a retry.

**H14-02.** A state transition commits its state revision, domain event and resulting command intents together, or none. Event delivery happens after commit. Slow observers cannot block the writer. Duplicate observation IDs and per-source sequence/epoch constraints are checked in the transaction; a timestamp alone is not a deduplication key.

The current writer now accepts a report only for an active enrolled Thing and an exactly matching declared capability. This lookup and the observation insert share one transaction, so revocation or a changed declaration cannot race a new report into the journal. A bounded batch records 1 to 32 distinct capabilities from the same source event in one transaction. It commits all new reports, returns all-duplicate replay without a write, and rolls back a stale, invalid or partially replayed batch. The adapter remains responsible for authenticating or correlating its source; a matching declaration does not upgrade an unauthenticated local packet's trust.

Schema version 15 adds a nullable Store-owned receipt epoch/time pair to the current observation and its original journal row. Every newly accepted single report, batch, enrolled refresh and guarded power readback stamps the pair inside the existing writer transaction; a batch shares one sampled Store clock. The adapter metadata is preserved separately. Exact duplicates, stale/conflicting events and rolled-back batches never renew it. Migration from version 14 or earlier leaves historical pairs null without manufacturing an age or journal event. Restart preserves the original pairs but cannot use another Store boot's elapsed time as current freshness.

Startup and encrypted-backup verification validate complete pairs, bounded epoch IDs, integer nonnegative time, nondecreasing time within each receipt epoch and exact current-to-original-journal identity/content/clock correspondence. Epoch validation uses bounded pages. The new authenticated fact projection rechecks the same original binding on live reads and disables writing on corrupt report data. It treats untimed, old-boot, future, expired, unknown-quality and lab reports as unknown, without changing revision. Backup accepts validated versions 4–15 with exact version-specific table sets; retained clocks in quarantined staging cannot reactivate a controller. These timestamps establish accepted receipt age only, not source authentication, packet age, physical causation or dynamic invariant policy. Existing direct-power guards still check the qualified adapter report basis; this projection does not replace their qualification or admit rules.

**H14-03.** A mutation request binds `(principal, authority epoch, operation ID)` to canonical content and its disposition. An identical retry returns that disposition; reuse with other content conflicts. Do not expose low-entropy command hashes publicly. Receipt retention and tombstones must prevent an old retry becoming a new physical effect after pruning.

After authentication, a request may have a durable `held` receipt while current authority and policy are resolved. Held outbox rows are not command admission and cannot be claimed by a driver. A rejection has a receipt but no effect row. Only a separately fenced transition after current-state checks may create queued work.

The initial store schema records enrollment, principals, grants, revocation and authority events alongside observations and held requests. Migration from the observation-only and receipt schemas retains the global revision. A held receipt can be returned on an exact authenticated retry, but it never authorizes dispatch by itself; future promotion must recheck current principal, enrollment, epoch, rule generation, resource revision and guards.

Schema version 6 adds reviewed enrollment bindings. Migration from version 5 preserves receipts, execution rows and global revision; backup verification continues to accept version 4 and 5 archives as legacy snapshots. Startup checks each binding against an enrolled Thing and its original operator. Reviewed enrollment is still not a qualified control profile and grants no dispatch authority.

Schema version 7 adds a versioned enrollment review history and preserves version 6 bindings as legacy reviews. Startup requires the active binding to match its history row and authority event. Re-review is one authority transaction with report clearing and pending-work invalidation, so a prior firmware identity cannot continue to satisfy a fresh guard. Migration does not upgrade old digests by assertion.

Schema version 8 adds a checked profile-qualification slot and the first transactional `held` to `queued` transition for direct absolute Light power. Admission reauthenticates the owner, reruns current epoch/grant/declaration and same-boot fresh-report checks, requires a version 2 reviewed identity and exact pinned registry/current runtime digests in the qualification row, and records the two-byte sealed power intent, whole-Thing effect domain, baseline/resource revisions, receipt and request event together. It also reopens the private content-addressed sanitized claim package and rechecks the signed physical decision and nine case receipts; a row with a missing, changed or untrusted package is unqualified for queueing. If the report already equals the desired value it closes the held request as `already_reported_no_send` before requiring profile qualification. An exact queued retry returns the existing receipt. Signed synthetic claim fixtures test this state transition and authority revocation. No real reviewed decision or packet transport owner exists, so dispatch remains disabled. The durable handoff repeats the same exact direct-power basis before any future transport may consume work; rule-originated work additionally requires active-rule/override/invariant state that is not yet implemented.

A trusted in-process worker can now claim one queued direct-power row. The Store rechecks current principal, grant, authority epoch, Thing/profile/resource revision, qualification digest and signed claim package, exact sealed power value, original report revision and fresh same-boot reported mismatch in one transaction. It records a random 32-byte BLOB token, worker boot epoch, first attempt, `claimed` receipt and journal revision together. Startup refuses a token stored with SQLite text affinity, even if its apparent length is 32. The caller PID is monitored for the current process, but worker exit before handoff does not requeue or finish the persisted claim. Restart reports the stranded claim; a second claim and owner cancellation are refused. A trusted recovery operation can reject an abandoned claim only after its monitored worker is gone, including after Store restart, and only while its durable handoff revision remains absent. Rejection deletes the execution row, journals `worker_abandoned_before_handoff` and frees the whole-Thing effect domain.

The same live worker may cross the first real durable handoff boundary only with its exact 32-byte claim token. Immediately before recording `dispatching`, the Store repeats the complete claim guard using the sealed boot epoch and baseline, including the current principal/grant/epoch, rule generation, declaration, static invariant, qualification package and fresh reported mismatch. The marker, receipt and request event share one revision. A different process cannot borrow the token. If the owning worker exits after this marker, the Store records `outcome_unknown/worker_exit_after_handoff`; it never requeues the command or calls the loss a failure. A restart applies the existing `crash_after_handoff` recovery before serving requests.

Schema version 13 records the Store's own boot epoch and elapsed monotonic
milliseconds with each new handoff marker, in that same transaction. The Store
samples this clock after repeating the current guard; neither the request nor
the worker's observation clock supplies the recorded time. Claim, ACK,
settlement, revocation, reconciliation and restart never replace it. Migration
keeps old handoffs explicitly untimed rather than inventing a clock value.
Startup and backup verification reject incomplete pairs, impossible ordering,
timestamps without their original handoff journal event and backwards elapsed
time within one Store epoch. A previous Store epoch is historical evidence,
not a current monotonic deadline. These records support future per-Thing
attempt spacing/rate gates. A handoff time does not
establish physical transition time, minimum on/off dwell or command causation.

The first such gate is now repeated before direct-power queueing, claiming and
the final durable handoff. The closed compiled Home policy fixes a 60-second
rolling window, 32 handoffs and 250-ms minimum spacing. Policy rejection leaves
the existing held/queued/claimed receipt and global revision unchanged; it
never sleeps inside the writer, automatically requeues or resends. Already
reported no-send work can close without consuming an attempt when the effect
domain is idle. The final check and timestamp write share the handoff
transaction, so successful checks in another process are not reusable tokens.
Recent history is read with a bounded `max_handoffs + 1` result, using current
Store-epoch timestamps; old epochs and nullable legacy timing require one
complete new-boot window before another attempt. All retained terminal and
unknown handoffs count; their outcome does not replenish the budget. A future
timestamp, malformed current history or invalid policy fails closed as corrupt
execution data. Rate limits do not substitute for current grants, signed
qualification, fresh observations, whole-Thing serialization or claimant
ownership, and do not limit unrelated read traffic or third-party controllers.

An opt-in Authority operation now runs each power exchange as a temporary supervised task. The task opens and closes its selected-interface transport, owns the Store claim for its lifetime, builds bytes before handoff, and sends only after `dispatching` commits. A correlated ACK commits `protocol_accepted` without claiming state. A correlated readback is validated against the exact target, Boolean capability and claim boot epoch; its observation journal write and the terminal `observed` or `contradicted/readback_mismatch` receipt commit in one SQLite transaction. A readback may settle without an ACK, while send uncertainty, missing readback and bounded receive exhaustion become an explicit `_after_handoff` unknown reason. The Store accepts each transition only from the monitored claimant with the exact BLOB token. Deterministic tests cover the full claimed/dispatching/protocol-accepted/observed sequence, mismatch without ACK and post-handoff worker death. Dispatch remains disabled in normal host configuration and is not exposed on the local request socket; actual profile qualification and hardware evidence remain separate gates.

The direct-power claim now derives its static invariant decision from the exact current integrated-Light declaration instead of passing a literal allow value into baseline policy. Only the one-capability, ordinary Boolean, extension-free profile can pass; other shapes yield `invariant_unresolved`. Its physical claim package and current authority checks remain mandatory. This decision supplies no dynamic safety facts, active-rule authority or packet transport by itself.

The abandoned-claim check reads the current receipt before deciding whether a worker is still active. Authority transactions remove obsolete worker monitors after they reject claimed work, so a surviving worker cannot make an already rejected operation appear recoverable or block status handling. A token from a rejected claim cannot acquire a new execution row.

Schema version 9 persists `rule_generation` independently of the authority epoch. Queueing seals its current value into the execution row; claiming compares it again. The first trusted empty-policy fence advances it under an expected Store revision and authority epoch, atomically rejecting unsent held/queued/claimed rows and marking recorded handoffs `outcome_unknown` with an `_after_handoff` reason. Startup refuses stale unsent generation rows and a mismatch between the generation value and its fence journal. The fence bounds affected work to 1,024 rows and fails without partial invalidation above that limit. It does not activate a rule or grant dispatch.

Schema version 10 stores one bounded operator override lease per Thing, with its original operator, authority epoch, resource revision, monotonic interval, boot epoch and issuing journal revision. Issuance and revocation share the Store transaction and advance the global revision. Startup validates each retained lease against its issuing authority event and referenced Thing and principal. Current-boot leases are read only after current credential, grants and declaration checks. Old rows remain inspectable through backup but are never active after restart. Live in-process lease calls derive elapsed monotonic milliseconds from a Store-owned origin for this start, so the socket facade does not trust client time. The table is bounded to 4,096 rows; new issuance fails at capacity while replacement of an existing row remains possible. Revocation, grant removal, credential rotation and declaration narrowing clear affected rows atomically with their authority event, so an obsolete lease cannot block the next operator until its old expiry. Issuance also rechecks the retained issuer and grant before declaring a conflict. Schema version 11 adds a bounded immutable override-operation receipt keyed by principal, authority epoch and operation ID. Issuance records request fields, the original lease interval and issue revision in the same transaction as the lease row. A matching retry returns that receipt without writing or renewing; changed fields conflict. A revoke, including the trusted in-process path, records its revision once in a matching operation receipt and is an exact retry thereafter. Retain IDs rather than prune them into reusable authority; when the ceiling is reached, new issues fail closed while status and revoke remain available. A restart cannot make a stored monotonic interval active. This is not an active-rule pointer or transport authorization.

Before either queueing or closing a held power/colour request as already reported, the Store now checks that no queued, claimed, dispatching, protocol-accepted or unknown execution row occupies the target's whole-Thing effect domain. A busy domain leaves the held receipt unchanged with `effect_domain_busy`. Version 8 startup also refuses multiple unresolved ledger rows for one effect domain. This prevents an earlier unresolved effect from making a later no-send decision misleading. A terminal observed, contradicted or failed row releases the domain; an unknown row requires explicit reconciliation before new work can advance.

Startup checks that every held receipt has its matching held outbox row and that no outbox row belongs to a rejected receipt. An inconsistent pair blocks Store startup. The read-only recovery view counts held work without treating it as queued or claiming a physical outcome.

The first writer now limits held outbox work to 32 requests per principal and 1,024 globally. The count and a new receipt are decided in the same SQLite transaction. A request above either ceiling receives a durable `rejected/pending_capacity` receipt with no outbox row; an identical retry returns that receipt. An authenticated `cancel` moves one held receipt to durable `rejected/cancelled`, deletes its held outbox row and appends a request journal event in one transaction. Repeated cancellation and exact submission retries return that terminal receipt; operation-ID reuse with changed content still conflicts. Version 8 also permits the owner to cancel still-queued work before any claim, deleting its execution row and writing `rejected/cancelled_before_claim` with a new journal revision. Claimed or handed-off work cannot be cancelled through this operation. These are initial backpressure controls, not a complete retention or disk-reserve policy. Rejected-receipt growth and pruning/tombstones still need bounded designs before long-lived production use.

A second ceiling now limits retained request IDs to 65,536 by default; a trusted Store startup option may select a smaller positive ceiling for a constrained host. The count check occurs in the new-ID transaction before inserting a receipt. At the ceiling, a new ID returns `receipt_capacity` without a receipt or effect row; exact retries and conflicts for previously recorded IDs are still resolved first, and terminal changes to existing held rows still work. Health reports retained count and configured ceiling. This bounds receipt-row growth but deliberately refuses all new IDs at saturation; it does not replace a disk reserve, retention schedule, or safe tombstone/epoch rollover design. The append-only journals also require independent bounds before long-lived production use.

Trusted Thing or principal revocation now rejects all matching held requests in the same SQLite transaction as the authority change. Each affected request gets its own journal revision and terminal reason (`target_revoked` or `principal_revoked`), its held outbox row is removed, and the returned revision is the last committed event. An exact retry remains bound to the rejected receipt. Principal revocation also cuts off credential reads. Version 5 also rejects matching unsent queued/claimed work and records already handed-off work as unknown in the same authority transaction. It cannot recall a packet that crossed the handoff boundary.

A trusted target-grant expansion now requires credential replacement in the
same transaction. The Store checks an active principal, active ungranted Thing
and the 32-target ceiling, inserts the grant, replaces the credential hash and
journals one authority event. It clears leases and rejects or invalidates all
pending work belonging to that principal as `credential_rotated`; handed-off
work becomes unknown through the existing execution invalidation rules. A
duplicate or unavailable target changes neither credential nor revision. This
is deliberately broader invalidation than the new target alone because the old
bearer may already be distributed.

The trusted Store can now narrow an active Thing declaration with an expected resource revision. Identity, profile revision, capability keys, value types, risk classes and extensions must remain exact; operations may only be removed, Kelvin bounds tightened, freshness shortened and evidence references replaced. A new capability or wider range requires a separate requalification and grant workflow. One transaction increments the resource revision, deletes current reports and pending source-epoch grants, journals the declaration change and rejects every held request for the Thing as `declaration_changed`. Historical reports remain journaled, but no old current report can satisfy a guard or overwrite the new declaration. Exact retries still return the terminal receipt. This is an in-process trusted reduction, not an API route or an authenticated profile-upgrade workflow.

Trusted target-grant revocation removes exactly one principal/Thing grant and rejects only that pair's held requests in the same transaction, with a separate journal revision for each rejection. Other principals' grants and the principal's other targets remain active. The affected principal can still query its own terminal receipt by operation ID; a new request for the removed target is rejected. The same scoped transaction now invalidates queued/claimed ledger rows and marks handed-off rows unknown. This is not a per-capability grant system or a physical handoff fence.

Trusted principal credential rotation generates and returns one new 32-byte credential, replaces only its persisted digest, journals the change and rejects all that principal's held requests as `credential_rotated` in one transaction. The prior credential fails immediately; the new credential retains the principal's grants and may inspect its prior terminal receipts. The same rotation transaction invalidates that principal's queued/claimed ledger rows and marks handed-off rows unknown. This is an in-process recovery primitive, not a credential distribution route or Keychain enrollment flow.

The first read-only held-power inspection reauthenticates the request owner and rechecks its held outbox row, current authority epoch, active Thing declaration/revision, target grant, ordinary permission and a fresh reported Boolean value in the caller's boot epoch. It reports whether the current observation already matches the desired absolute power value and includes the exact store/report revisions used. A missing, stale, synthetic, unknown or wrong-boot report blocks the check. This result is a transient guard input only: no receipt is promoted, no effect is claimed and no packet may be sent from this inspection. Promotion must repeat the checks in its own transaction and independently establish rule/override and transport authority.

A corresponding read-only held-colour inspection reconstructs the original typed brightness, HSV or Kelvin mutation from its durable receipt, rechecks the same principal/Thing authority, and reads all three current colour observations from the Store's single writer view. It invokes the pure HSBK planner only when those reports form one fresh, coherent LightState source event; mixed revisions, wrong boot epochs, stale or synthetic reports cannot yield a plan. The result includes the exact report revisions and remains transient. A later claim must rebuild and compare the plan while holding the whole-light effect domain and checking current authority; this inspection alone cannot authorize a UDP write.

The Store can now resolve a held absolute Light-power request without a send when a fresh current report already equals its desired Boolean value. One transaction reauthenticates and rechecks the held row, current declaration, epoch, grant and observation, then removes the outbox row and writes a terminal `rejected/already_reported_no_send` receipt plus journal event. The `rejected` disposition states that no actuation was admitted; it does not assert physical success or claim that the value will remain unchanged. A stale, absent, wrong-boot or mismatching report leaves the request held. Identical retries return the same terminal receipt across restart. This is not a substitute for the queued/claimed dispatch state machine.

The same no-send transition is available for a held Light brightness, HSV or Kelvin request only after the Store rebuilds a complete colour plan from one fresh coherent `LightState` source event in its transaction. It compares the complete reported and desired HSBK tuples at the protocol's integer resolution, including Kelvin and saturation. A Kelvin request that would switch a coloured light into white mode is an effect even when its numeric Kelvin already matches. The transition rechecks current authority and writes the same terminal `rejected/already_reported_no_send` receipt and journal event; a stale or mixed baseline, changed grant or unequal tuple cannot close the held row. This avoids a redundant packet without asserting that the light will remain at that value.

## Internal writer boundary

Enrolled-LIFX refresh basis and report commits now compose stateless
`Store.RefreshWriter`. It authenticates a read/control principal and exact
grant, then repeats the current stable binding, immutable declaration and
resource revisions before the observation writer accepts the batch or scoped
source-epoch change. Capture/discovery stays outside the writer; no credential,
target endpoint or device channel crosses into the capture owner.

The remaining principal-scoped snapshot, catalogue, history, observation-event
and request-event projections now compose `Store.StateReadModel`. Its closed
execution-state vocabulary comes from the same request ledger used by status.
Startup/version-migration and backup snapshot consistency checks now share the
read-only `Store.Integrity` collaborator. Store invokes both synchronously
and owns health fail-closure; neither can allocate authority, migrate state
independently, retain a connection or perform device I/O.

**H14-08.** One supervised process owns the SQLite connection, host lock,
monotonic boot origin and transaction serialization. That ownership does not
make one source module responsible for every domain. Schema installation and
migration, observation projection, enrollment, principal grants, request
execution, qualification and overrides live in explicit internal modules with
closed inputs and results. They receive the owned database handle only during
the writer's call and never retain it, start a competing writer or perform
device I/O.

The writer process remains the atomicity boundary and may compose multiple
internal transaction modules in one SQLite transaction. External adapters do
not call those modules or issue SQL. The application authority API selects the
use case; the writer validates and commits it. Refactoring internal modules
must preserve the schema, receipt identity, revision sequence and crash
semantics unless a separately versioned migration changes them.

The version 1-through-11 DDL and migration sequence now lives in a stateless
`Store.Schema` collaborator. It receives the Store-owned handle only during
startup, runs each historical integrity gate before migrating and invokes the
Store's final semantic validator afterward. It has no process, open/close call
or runtime transaction API. Migration fixtures from observation-only through
the current override schema retain their revisions and fail closed on corrupt
rows.

Observation validation and write projection now live in a stateless
`Store.ObservationWriter` collaborator. It owns single-report and atomic batch
insertion, replay/sequence checks, one-use source-epoch grants and the scoped
LIFX refresh epoch transition. The Store validates call shape, opens the
transaction and remains the only process and connection owner; the collaborator
receives that handle synchronously and returns only commit/rollback data. Store
and refresh regression tests preserve revisions, duplicate handling, atomic
multi-capability writes and restart epoch behavior.

Global revision allocation and the two journal append shapes now live in a
stateless `Store.Journal` collaborator. Authority and request events advance
the same `meta.revision` value only after their journal row is inserted inside
the Store-owned transaction. Observation, enrollment, grants, execution,
qualification and override code share this primitive instead of carrying
copies that could drift. The collaborator has no process, connection lifecycle
or transaction entry point; callers cannot commit a journal row outside the
single writer's active transaction.

Shared authentication and active-resource reads now live in a stateless
`Store.Access` collaborator. It decodes active credential permissions, bounded
target grants and enrolled Thing documents for the transaction modules, and
classifies malformed persisted shapes as principal or enrollment corruption.
It has no credential-generation, grant-mutation, transaction or connection
lifecycle authority. Observation and review collaborators use the same access
decoder as the Store instead of carrying weaker copies.

LIFX power-profile qualification now lives in a stateless
`Store.QualificationWriter` collaborator. It reauthenticates the qualifying
principal and target grant, verifies the current version-2 enrollment identity,
exact narrow declaration, resource revision, pinned product registry and
runtime digest, and retains the signed content-addressed claim before appending
the qualification event. Admission and final handoff call its same read-side
revalidation, so a revoked reviewer, changed binding, declaration or artifact
cannot reuse an old qualification row. The Store still owns the transaction,
credential hashing, decision-signature entry point and only database handle.

Operator override leases and their idempotent operation receipts now live in a
stateless `Store.OverrideWriter` collaborator. It owns lease issue, status,
expiry interpretation, explicit revocation, capacity limits and cleanup on
Thing, principal or target-grant changes. Every issue and revoke still appends
the shared authority revision inside the Store-owned transaction. The Store
owns the boot-relative clock, validates public call shapes and supplies only
the current boot epoch and monotonic value, so persisted monotonic timestamps
cannot become valid after restart and the collaborator cannot create a second
clock or writer authority.

## Device I/O is not a database transaction

Enrollment and principal grants now have separate stateless transaction
collaborators. `Store.EnrollmentWriter` binds reviewed identities, retains
review history, narrows declarations and revokes Things with report clearing
and request invalidation in the same transaction. `Store.PrincipalWriter`
provisions and revokes principals, changes grants, and replaces credential
hashes while clearing affected leases and invalidating pending work. The Store
still generates credential bytes and owns every transaction and connection;
both collaborators compose the shared access, journal, override and request
invalidation primitives synchronously.

Authority changes and cancellation share the stateless
`Store.RequestInvalidator` collaborator. It rejects held and unsent execution
rows, records possible effects after handoff as unknown, and advances the
shared request journal for every affected operation within the surrounding
Store transaction. Enrollment, principal grants, rule fences and explicit
cancellation use the same transition implementation.

A command progresses through `admitted`, `queued`, `claimed`, `dispatching`, `protocol_accepted`, then `observed`, `contradicted`, `failed` or `outcome_unknown`. Protocols may omit intermediate acknowledgements. No device I/O occurs inside a database transaction.

For the first single-Thing absolute Light path, `admitted` is a journaled decision and the committed work starts in `queued`; there is no externally visible interval in which admission exists without a queued record. A queued record binds the original scoped operation ID, authority epoch, current resource revision, active-rule generation (zero for a direct operator request), exact profile/evidence revision, complete desired wire value or its sealed derivation inputs, effect domain and fresh observation basis. The request's canonical content remains immutable. An inactive, revoked or unqualified profile cannot supply this record. Admission rechecks the principal, grant, declaration, current safety facts, applicable override and rule generation in the same writer transaction; a prior read-only inspection is advisory. A matching reported value takes the no-send terminal transition instead of queueing. No rule review result or raw packet is an admission token.

The execution transition table is normative. A transition appends a request event and updates the receipt/work row at one global revision in one transaction. A state not listed as a source cannot take that transition, including on retry.

| From | To | Required boundary |
| --- | --- | --- |
| `held` | `rejected` | Current policy denies, the owner cancels, authority narrows, or a fresh report proves no send is needed. No effect row survives. |
| `held` | `queued` | Complete admission checks and qualified profile evidence commit with the queued row. |
| `queued` | `claimed` | One live worker obtains a random claim token under the whole-Thing effect-domain lock; queued work remains inaccessible to drivers. |
| `queued` | `rejected` | The owner cancels before claim or a current guard permanently invalidates the queued work; its original operation ID remains terminal. |
| `claimed` | `queued` or `rejected` | The worker has not crossed the durable handoff marker; expiry, revocation or changed authority requires a fresh guard before another claim. |
| `claimed` | `dispatching` | The Store rechecks epoch, principal/grant, profile, rule generation, declaration, current observations and effect-domain ownership, then persists the exact handoff marker. Only the selected transport owner may consume that token, once. |
| `dispatching` | `protocol_accepted`, `observed`, `contradicted`, `failed` or `outcome_unknown` | A bounded transport/readback result attaches to that same claim. Socket send acceptance alone cannot be `protocol_accepted` or `observed`. |
| `protocol_accepted` | `observed`, `contradicted` or `outcome_unknown` | A fresh correlated readback or expired evidence window settles the claim. An ACK alone is not an observed state. |
| `outcome_unknown` | `observed` or `contradicted` | Only an explicit reconciliation with new evidence may refine the record; it never silently retries a physical command. |

`claimed` contains no send authority. The transport owner must be a supervised child of the Store authority and may receive bytes only after the durable `dispatching` marker. Startup stops old transport owners before reconciling claims. Queued work is rechecked before a new claim; a stranded `claimed` row may be requeued only when its worker and transport owner are definitively gone. Any `dispatching` or `protocol_accepted` row left by a crash becomes `outcome_unknown` before dispatch is enabled; a packet may have crossed the process boundary even if no ACK was persisted. A stale claim token, epoch or rule generation cannot hand off bytes. Revocation rejects unsent queued/claimed work in the same authority transaction and reports already handed-off work as unknown; it cannot recall a packet. A delayed ACK/readback may update only the matching current claim and cannot overwrite a newer effect-domain decision.

The bounded first implementation may have dispatch disabled while it establishes these rows and recovery checks. Health must then report queued, claimed and unknown counts separately from held work. Neither a database migration nor a synthetic fixture turns dispatch on. Schema migration must preserve the old scoped receipts and global revision, and startup refuses any receipt/work mismatch or duplicate active whole-Thing claim.

Schema version 5 now adds a separate execution ledger with a unique active claim per whole-Thing effect domain, immutable admission basis fields, a bounded sealed planned value, claim token, handoff revision and current state. The migration rebuilds the receipt constraint so later states can be represented; it retains version 4 held/rejected receipts, outbox rows and global revisions. Startup rejects mismatched receipt/execution rows and foreign-key errors. After integrity checks, any persisted `dispatching` or `protocol_accepted` row is atomically journaled as `outcome_unknown/crash_after_handoff` before the Store serves requests. Exact retries return that same revised receipt across further restarts; `cancel` cannot withdraw it. Health separates held, queued, claimed and unknown counts. At version 5 these rows were recovery infrastructure and synthetic crash-boundary evidence only; version 8 adds a guarded direct-power admission transition without claim or transport consumption. A stranded `claimed` row is reported, not automatically requeued, until worker ownership can be proved. Dispatch remains disabled.

The principal-scoped request event reader now accepts every closed ledger disposition, including queued, claimed, synthetic handoff and recovered unknown rows. It validates each state and bounded reason before returning it. A cursor over a real queued/claimed operation must remain readable rather than treating the Store's own journal as corrupt; the event remains a receipt transition, not proof of a physical device state.

Trusted Thing/principal revocation, target-grant revocation, credential rotation and declaration narrowing now use the same version 5 ledger invalidation inside their authority transaction. Queued and claimed rows are deleted with a terminal rejected receipt; dispatching or protocol-accepted rows retain an `outcome_unknown` receipt and a reason ending in `_after_handoff`. Each affected operation gets a request-journal revision. Synthetic queued, claimed, handoff and supervised settlement fixtures verify the transition and restart behavior; the installed host keeps the internal send route disabled until explicitly configured with a qualified cohort.

**H14-04.** Persist a claim before handoff. A crash between handoff and recording its result produces unknown outcome. Read state or ask the operator according to the profile. Never blindly repeat a toggle, pulse, unlock, hush, reset or other non-idempotent operation. Absolute state-setting can be retried only under a documented profile with current authority, bounded attempts and no conflicting newer request. 'At-most-once command admission' is not 'exactly-once device actuation'.

**H14-05.** A scene carries independent per-device results. Partial completion is a normal outcome. Compensation is a new authorized plan against current observations, not an automatic inversion of all prior commands. Delayed acknowledgements do not overwrite a newer desired revision. Reads describe reported state, not proof that photons or mechanical movement occurred.

## Time and replay

**H14-06.** Record source event time, receive time, monotonic time and boot epoch separately. Use monotonic deadlines within a boot. After restart, rebuild timers from persisted wall-time facts only when clock confidence permits it. Never reuse a persisted monotonic value from another boot. Timezone and daylight-saving policy are versioned schedule inputs.

Authorized local clients can now page stored observation history by global revision for one granted capability. Readback revalidates persisted quality, trust, timestamps, epochs and value shape; corrupt rows fail closed instead of becoming a valid report. A page is pinned to a current store watermark and restarts after any intervening write. This does not yet impose journal retention or prove crash/power-loss durability.

Old telemetry can update history without issuing a present-time action. A replay process has no actuator credentials. Device resets create a new source epoch; counter wrap and reset are not guessed from wall time alone.

The writer now has a trusted, one-use source-epoch grant for a single enrolled capability. Issuing it requires the exact current old epoch and report revision; it is durable across restart, journaled as an authority event, and never exposed on the local request socket. A report in the new epoch consumes the grant in the same transaction as its observation. A newer report in the old epoch makes the grant stale until the trusted caller requalifies and reissues it against the new revision. Revocation deletes pending grants. This mechanism records the decision, but the adapter/operator must still establish actual device identity before calling it; a LIFX source/target match alone is not authentication. Schema version 3 migrates to version 4 without dropping reports.

## Failure behavior

Store corruption, full disk or failed durability checks make ordinary mutation unavailable with a clear reason, not ephemeral success. Preserve read-only diagnostics when possible. Recovery checks referential integrity, active artifact identity and pending claims before enabling dispatch. Restore selects one authority and separately restores radio key/counter continuity. It never auto-promotes a cloned backup into a second writer.

Store now refuses a database carrying the offline `restore_quarantine` marker before enabling its normal WAL writer. WOH.16 staging adds this marker only after archive verification and before writing the new file. No marker-clearing or ownership-transfer operation exists yet.

Schema 16 retains immutable reported-constraint operation history. The writer checks complete canonical source and shared predicate IR, exact declaration pins, predecessor revisions and authority-journal identity. Current constraints are read again inside queue, claim and handoff transactions. Replacement invalidates held and unsent work and marks handed-off work unknown. The decision uses only current Store receipt clocks and active policy-author grants; restarting or revoking an author cannot erase a restriction. Orderly supervisor shutdown closes both database and ownership-lock handles before a replacement Store starts.

## Acceptance

H14-T1: kill the process before and after every commit/handoff boundary; assert state, outbox and receipt consistency. H14-T2: duplicate/reordered requests and delayed acknowledgements. H14-T3: disk full, WAL growth, slow checkpoint and corrupt backup. H14-T4: power-loss tests on the actual target storage. H14-T5: scene partial completion reports each member without fake atomicity. H14-T6: history replay and expired retries issue zero unauthorized effects. H14-T7: wall-clock jumps and restarts do not duplicate schedule actions. H14-T8: run observation, enrollment, request and override transaction modules through the one writer and prove that no module can retain the database handle, bypass revision advancement or perform device I/O.

## Schema 17 rule authority and origin integrity

Immutable bounded `rule_admissions` and `rule_activations` retain original principal/epoch/operation receipts and journal links. Activation compares the Store revision, atomically advances rule generation and the active admission pointer, and invalidates old held/unsent work while preserving handed-off uncertainty. The active pointer must match the latest activation or maintenance fence. Every historical activation generation must equal its ordered generation-event count, and a nonzero admission must precede activation in the same authority epoch. Migration from 16 adds empty rule history without minting authority or changing the watermark.

Explicit invocation adds immutable `request_rule_origins` and matching admission/generation markers on its retained causal root in the same request transaction. Integrity validates the markers in both directions, exact original receipt/journal identity, source effect/resource binding and preceding activation. Startup, live status and encrypted backup verification reject damaged authority records. Original retries survive suspension/restart without creating or sending another effect. The existing causal reservation and final device guards remain mandatory; admission alone creates no execution row.

The live rule path now validates the complete latest activation receipt, its authority epoch and the ordered generation journal before status, successor activation, invocation, queue, claim or final handoff. A damaged predecessor/generation/count cannot be hidden behind an otherwise matching active pointer. Corruption disables Store writes and leaves the existing request, revision, causal reservation and handoff marker unchanged. Historical operation lookup remains principal-private; regression cases cover each execution boundary and a corrupted inactive maintenance fence.

Schema 18 retains a host-maintenance barrier and immutable principal/epoch/operation receipts. Begin advances an empty rule generation and atomically rejects held/queued/claimed work while preserving handed-off uncertainty. New ordinary requests, rule work, queue, claim and final handoff are blocked under the same writer. Existing request identity, causal spend, observations and recovery reads remain available. Restart retains the barrier; end requires the current epoch, Store revision and original begin revision and leaves the rule pointer empty. Full journal, predecessor, generation and historical affected/unknown counts are validated on live reads, startup and encrypted recovery. A failed transaction leaves no partial fence, receipt or marker. This is software interruption evidence, not physical storage or packet-recall evidence.

## Future component activation

Production component activation/revocation under [WOH.17](WOH.17-component-extensions.md) belongs to this single writer. Immutable artifact pins and revision/generation barriers must cover staging, queue, claim and handoff; invalidate unsent work and preserve handed-off uncertainty in the same transaction. Retain original historical identities and causal reservations. The initial development installer/preview changes no durable schema, active profile pointer, request or observation path.

## Portable profile ledger

[WOH.18](WOH.18-portable-profile-admission.md) owns data admission and
shared profile/helper selection. This Store alone owns immutable scoped
operations, trust decisions, per-Thing generations and retained history. Initial
selection requires the existing global maintenance barrier; its transaction
revokes qualification, clears current facts/source grants, invalidates unsent
work and conservatively suspends rules while retaining handoff uncertainty and
spent roots. Observation, queue, claim and handoff recheck the exact current
selection and available bytes. File publication and SQLite do not share a
transaction: publish synchronized immutable objects first, keep leases/pins,
and tolerate inert orphans; missing referenced bytes cannot select a substitute.
Schema/integrity/historical backup sets must change together before activation.
Schema 19 now retains bounded local digest approvals/revocations, canonical
scoped receipts, immutable metadata and global trust-policy generations.
The Store verifies custody before an approval transaction; current management
permission and original receipt lookup precede CAS or file checks on retries.
Lifecycle mutation requires the active maintenance barrier. Live/startup/archive
validation checks the complete trust and journal history, and corrupt links
disable writes. Migration preserves all prior state. Approval cannot change a
Thing, qualify a device or create work. Schema 19 retains its original empty
selection/pin requirement; schema 20 validates actual guarded selection history.

Portable-profile guards now run at the Store's current observation,
refresh, request, rule, qualification and effect boundaries. Store verifies
bounded custody commitments and the current full runtime before SQLite
transactions; these call-local TEMP checks are cleared on every reply and cannot
enter a recovery snapshot. Unavailable profile policy rolls back without
disabling independent compiled work; corrupt authority links disable writes.
Historical receipt reads remain historical. Schema 20 now retains exact
selection generations, original enrollment-review and parent-operation links,
and pins for observations, requests, rule admissions and qualifications. The
Store consumes one held review only after authenticated original-receipt lookup
and current CAS, revalidates bytes/runtime outside SQLite, repeats the complete
basis inside the transaction and checks the original deadline before commit.
Compatible reviewed target replacement and revocation clear reports/grants/
overrides, revoke qualification heads and retain original claims and spent roots.
Current use repeats owning-domain pins; complete journal/history correspondence
is required at startup and backup verification. Ordinary narrowing/review cannot
bypass a selected target's lifecycle. The v2 review path now atomically creates
an absent target's enrollment/review/first selection without grants, or replaces
firmware from fresh exact captured evidence while retaining the old tuple and
qualification. Occupied identities and revoked targets cannot be reused. Public
operator and production-host flows remain unfinished.

The retained-profile recovery slice now implements the authored
[archive mechanism](portable-profile-recovery-v1.md): Store-serialized encrypted
export includes every retained exact raw object, including revoked history, with
raw/projection/registry correspondence. Store-only custody export checks private
descriptor/path identity and historical data independently of current registry
availability. Missing/corrupt objects fail the complete export; unreferenced
objects and transient leases/reviews are not transferred. Database-only archives
retain their historical format and table-set checks. Verification checks the
authenticated exact object set before reporting inclusion or writing files.
New private directory staging synchronizes immutable bytes and a fully marked
quarantined database, preserves source history and refuses overwrite/startup.
Foreground recovery reads its key only through bounded canonical stdin custody.
Fenced activation, installed key brokerage, external qualification packages and
actual old-writer/radio-counter isolation remain separate requirements.

The authored [controller transfer mechanism](controller-transfer-v1.md) defines
permanent source retirement, one-use destination review, separately trusted
isolation evidence and Store-owned acceptance with new epoch/barrier and revoked
archived authority. Its consumer and canonical ledger encodings remain next work.
No restore marker can be cleared by the existing archive or public API.
