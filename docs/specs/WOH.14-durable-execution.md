# WOH.14 — Durable state and honest command execution

Version: 0.1.2. Status: accepted target.

## Storage choice

Use a hybrid local store: transactional current state and a bounded append-only domain journal. Full event sourcing is not required; migrations should not need to replay every historical sensor sample. ETS holds disposable read projections, not authority. A single host-selected SQLite/Exqlite writer is the reference implementation. No broker, distributed database or database server is needed for one home.

**H14-01.** Persist stable Thing identities, enrollment/profile revisions, active/candidate rule revisions, current observations with quality, override leases, command receipts and outbox entries. High-rate diagnostic telemetry has independent retention and cannot exhaust the space reserved for authoritative records. Model weights, backups and large captures live outside row payloads with bounded content-addressed references.

Use WAL with `synchronous=FULL` for authoritative transactions, verified at connection setup; evaluate the macOS VFS/full-sync settings in the host qualification. This is a design choice informed by [SQLite's durability distinctions](https://sqlite.org/pragma.html#pragma_synchronous), not a promise that arbitrary flash media survives power loss. Set foreign keys, finite busy deadlines, checkpoint policy and an explicit disk-space reserve. Backups use a consistent SQLite backup/snapshot procedure, not a copy of only the live `.sqlite` file.

## Transaction boundaries

**H14-02.** A state transition commits its state revision, domain event and resulting command intents together, or none. Event delivery happens after commit. Slow observers cannot block the writer. Duplicate observation IDs and per-source sequence/epoch constraints are checked in the transaction; a timestamp alone is not a deduplication key.

**H14-03.** A mutation request binds `(principal, authority epoch, operation ID)` to canonical content and its disposition. An identical retry returns that disposition; reuse with other content conflicts. Do not expose low-entropy command hashes publicly. Receipt retention and tombstones must prevent an old retry becoming a new physical effect after pruning.

After authentication, a request may have a durable `held` receipt while current authority and policy are resolved. Held outbox rows are not command admission and cannot be claimed by a driver. A rejection has a receipt but no effect row. Only a separately fenced transition after current-state checks may create queued work.

The initial store schema records enrollment, principals, grants, revocation and authority events alongside observations and held requests. Migration from the observation-only and receipt schemas retains the global revision. A held receipt can be returned on an exact authenticated retry, but it never authorizes dispatch by itself; future promotion must recheck current principal, enrollment, epoch, rule generation, resource revision and guards.

## Device I/O is not a database transaction

A command progresses through `admitted`, `queued`, `claimed`, `dispatching`, `protocol_accepted`, then `observed`, `contradicted`, `failed` or `outcome_unknown`. Protocols may omit intermediate acknowledgements. No device I/O occurs inside a database transaction.

**H14-04.** Persist a claim before handoff. A crash between handoff and recording its result produces unknown outcome. Read state or ask the operator according to the profile. Never blindly repeat a toggle, pulse, unlock, hush, reset or other non-idempotent operation. Absolute state-setting can be retried only under a documented profile with current authority, bounded attempts and no conflicting newer request. 'At-most-once command admission' is not 'exactly-once device actuation'.

**H14-05.** A scene carries independent per-device results. Partial completion is a normal outcome. Compensation is a new authorized plan against current observations, not an automatic inversion of all prior commands. Delayed acknowledgements do not overwrite a newer desired revision. Reads describe reported state, not proof that photons or mechanical movement occurred.

## Time and replay

**H14-06.** Record source event time, receive time, monotonic time and boot epoch separately. Use monotonic deadlines within a boot. After restart, rebuild timers from persisted wall-time facts only when clock confidence permits it. Never reuse a persisted monotonic value from another boot. Timezone and daylight-saving policy are versioned schedule inputs.

Old telemetry can update history without issuing a present-time action. A replay process has no actuator credentials. Device resets create a new source epoch; counter wrap and reset are not guessed from wall time alone.

## Failure behavior

Store corruption, full disk or failed durability checks make ordinary mutation unavailable with a clear reason, not ephemeral success. Preserve read-only diagnostics when possible. Recovery checks referential integrity, active artifact identity and pending claims before enabling dispatch. Restore selects one authority and separately restores radio key/counter continuity. It never auto-promotes a cloned backup into a second writer.

## Acceptance

H14-T1: kill the process before and after every commit/handoff boundary; assert state, outbox and receipt consistency. H14-T2: duplicate/reordered requests and delayed acknowledgements. H14-T3: disk full, WAL growth, slow checkpoint and corrupt backup. H14-T4: power-loss tests on the actual target storage. H14-T5: scene partial completion reports each member without fake atomicity. H14-T6: history replay and expired retries issue zero unauthorized effects. H14-T7: wall-clock jumps and restarts do not duplicate schedule actions.
