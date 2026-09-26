# WOH.14 — Durable state and honest command execution

Version: 0.1.14. Status: accepted target.

## Storage choice

Use a hybrid local store: transactional current state and a bounded append-only domain journal. Full event sourcing is not required; migrations should not need to replay every historical sensor sample. ETS holds disposable read projections, not authority. A single host-selected SQLite/Exqlite writer is the reference implementation. No broker, distributed database or database server is needed for one home.

**H14-01.** Persist stable Thing identities, enrollment/profile revisions, active/candidate rule revisions, current observations with quality, override leases, command receipts and outbox entries. High-rate diagnostic telemetry has independent retention and cannot exhaust the space reserved for authoritative records. Model weights, backups and large captures live outside row payloads with bounded content-addressed references.

Use WAL with `synchronous=FULL` for authoritative transactions, verified at connection setup; evaluate the macOS VFS/full-sync settings in the host qualification. This is a design choice informed by [SQLite's durability distinctions](https://sqlite.org/pragma.html#pragma_synchronous), not a promise that arbitrary flash media survives power loss. Set foreign keys, finite busy deadlines, checkpoint policy and an explicit disk-space reserve. Backups use a consistent SQLite backup/snapshot procedure, not a copy of only the live `.sqlite` file.

## Transaction boundaries

**H14-02.** A state transition commits its state revision, domain event and resulting command intents together, or none. Event delivery happens after commit. Slow observers cannot block the writer. Duplicate observation IDs and per-source sequence/epoch constraints are checked in the transaction; a timestamp alone is not a deduplication key.

The current writer now accepts a report only for an active enrolled Thing and an exactly matching declared capability. This lookup and the observation insert share one transaction, so revocation or a changed declaration cannot race a new report into the journal. A bounded batch records 1 to 32 distinct capabilities from the same source event in one transaction. It commits all new reports, returns all-duplicate replay without a write, and rolls back a stale, invalid or partially replayed batch. The adapter remains responsible for authenticating or correlating its source; a matching declaration does not upgrade an unauthenticated local packet's trust.

**H14-03.** A mutation request binds `(principal, authority epoch, operation ID)` to canonical content and its disposition. An identical retry returns that disposition; reuse with other content conflicts. Do not expose low-entropy command hashes publicly. Receipt retention and tombstones must prevent an old retry becoming a new physical effect after pruning.

After authentication, a request may have a durable `held` receipt while current authority and policy are resolved. Held outbox rows are not command admission and cannot be claimed by a driver. A rejection has a receipt but no effect row. Only a separately fenced transition after current-state checks may create queued work.

The initial store schema records enrollment, principals, grants, revocation and authority events alongside observations and held requests. Migration from the observation-only and receipt schemas retains the global revision. A held receipt can be returned on an exact authenticated retry, but it never authorizes dispatch by itself; future promotion must recheck current principal, enrollment, epoch, rule generation, resource revision and guards.

Startup checks that every held receipt has its matching held outbox row and that no outbox row belongs to a rejected receipt. An inconsistent pair blocks Store startup. The read-only recovery view counts held work without treating it as queued or claiming a physical outcome.

The first writer now limits held outbox work to 32 requests per principal and 1,024 globally. The count and a new receipt are decided in the same SQLite transaction. A request above either ceiling receives a durable `rejected/pending_capacity` receipt with no outbox row; an identical retry returns that receipt. An authenticated `cancel` moves one held receipt to durable `rejected/cancelled`, deletes its held outbox row and appends a request journal event in one transaction. Repeated cancellation and exact submission retries return that terminal receipt; operation-ID reuse with changed content still conflicts. Cancellation cannot undo any future physical handoff, so this operation is restricted to held work. These are initial backpressure controls, not a complete retention or disk-reserve policy. Rejected-receipt growth and pruning/tombstones still need bounded designs before long-lived production use.

Trusted Thing or principal revocation now rejects all matching held requests in the same SQLite transaction as the authority change. Each affected request gets its own journal revision and terminal reason (`target_revoked` or `principal_revoked`), its held outbox row is removed, and the returned revision is the last committed event. An exact retry remains bound to the rejected receipt. Principal revocation also cuts off credential reads. This closes stranded held capacity; it does not recall future queued or physically handed-off work, which requires the separate fenced execution state machine.

The trusted Store can now narrow an active Thing declaration with an expected resource revision. Identity, profile revision, capability keys, value types, risk classes and extensions must remain exact; operations may only be removed, Kelvin bounds tightened, freshness shortened and evidence references replaced. A new capability or wider range requires a separate requalification and grant workflow. One transaction increments the resource revision, deletes current reports and pending source-epoch grants, journals the declaration change and rejects every held request for the Thing as `declaration_changed`. Historical reports remain journaled, but no old current report can satisfy a guard or overwrite the new declaration. Exact retries still return the terminal receipt. This is an in-process trusted reduction, not an API route or an authenticated profile-upgrade workflow.

Trusted target-grant revocation removes exactly one principal/Thing grant and rejects only that pair's held requests in the same transaction, with a separate journal revision for each rejection. Other principals' grants and the principal's other targets remain active. The affected principal can still query its own terminal receipt by operation ID; a new request for the removed target is rejected. This is not a per-capability grant system or a physical handoff fence.

Trusted principal credential rotation generates and returns one new 32-byte credential, replaces only its persisted digest, journals the change and rejects all that principal's held requests as `credential_rotated` in one transaction. The prior credential fails immediately; the new credential retains the principal's grants and may inspect its prior terminal receipts. This is an in-process recovery primitive, not a credential distribution route or Keychain enrollment flow.

## Device I/O is not a database transaction

A command progresses through `admitted`, `queued`, `claimed`, `dispatching`, `protocol_accepted`, then `observed`, `contradicted`, `failed` or `outcome_unknown`. Protocols may omit intermediate acknowledgements. No device I/O occurs inside a database transaction.

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

## Acceptance

H14-T1: kill the process before and after every commit/handoff boundary; assert state, outbox and receipt consistency. H14-T2: duplicate/reordered requests and delayed acknowledgements. H14-T3: disk full, WAL growth, slow checkpoint and corrupt backup. H14-T4: power-loss tests on the actual target storage. H14-T5: scene partial completion reports each member without fake atomicity. H14-T6: history replay and expired retries issue zero unauthorized effects. H14-T7: wall-clock jumps and restarts do not duplicate schedule actions.
