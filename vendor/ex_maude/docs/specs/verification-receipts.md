# Verification receipts

Version: 0.1.0-target. The bundled IoT Port profile now has additive receipt
functions; the wider profile and attestation requirements below remain a target.

Implemented entry points: `ExMaude.IoT.detect_conflicts_with_receipt/2`,
`verify_safety_with_receipt/3`, and `verify_liveness_with_receipt/3`. The
`bundled-iot-v1` profile uses a fresh Port worker and private snapshots of the
bundled model, executable, and adjacent prelude. It does not use a pool, accept
custom Maude imports, sign receipts, store private witnesses, or provide a
positive unbounded proof profile. `:bounded_complete` is a bounded command
completion only. A completed no-finding search does not establish safety or
liveness. Callers may pass `:assumptions`, which are labeled as caller
assertions; the execution observations are separate.

## Purpose

A receipt identifies which question was executed against which exact model and what evidence came back. It is not an authorization token or a certificate of physical safety. Existing high-level return types remain available; adoption of a new API requires an explicit versioned implementation.

## Fields

**EMR-01.** The semantic portion records schema version, operation/profile ID, canonical input identity, rule/initial-state/target identities, encoder/compiler identity where supplied, model dependency-closure digest, checker/library/backend identity, effective search/output/resource budgets and declared assumptions. Distinguish caller assertions from identities measured by the executing worker.

The execution portion records a unique run identity, start/end observations, elapsed duration, queue/native/parse disposition, effective bounds, completion status, findings and a bounded witness reference. Canonical semantic identity excludes timing and incidental process IDs; two runs may ask the same semantic question while having different execution evidence.

## Outcome taxonomy

**EMR-02.** Represent findings and completeness separately. Findings may include conflict pairs, a reachable bad state, deadlock evidence or a profile-defined trace/lasso. Completion may be bounded-complete, inconclusive due to limit, timeout, unavailable, cancelled, malformed result or error. `bounded-complete` means the requested bounded operation finished, not that an unbounded property is proved.

A receipt produced from a legacy inconclusive return uses `legacy_unverified` and does not invent whether a bound or timeout caused it. A future established result must name a separately admitted proof profile and its completeness evidence; this receipt schema cannot create that capability.

## Atomic model identity

**EMR-03.** A filename and a cached 'loaded' flag are not a model identity. Read or resolve immutable model bytes and their transitive imports under a pinned registry. Bind the actual worker/model epoch to the command. Pool-wide broadcast loading may be partial; do not claim it is an atomic model switch. A replacement worker must establish the same model closure before serving a receipt for that identity.

If model identity changes between preparation and execution, return identity mismatch or retry the entire explicitly authorized read-only verification under a new run, never relabel the old output. Native execution and parsing must remain attributable to the same command and effective budgets.

## Budgets and failure

**EMR-04.** A caller deadline covers queueing, loading, native execution, parsing and receipt delivery. Expired work is not later reported as a fresh result. Cancelling or timing out must establish worker disposition; an uncertain worker cannot be reused as though its command had ended. Resource-limit, output-overflow and parser failures are non-successful evidence. A truncated counterexample must be marked incomplete, not converted to no finding.

## Witness and privacy

**EMR-05.** Preserve the returned finding's scope. If a full trace is not available, the receipt says so. A reconstructed trace must be replayed against the exact transition theory before being represented as a witness. Bound witness bytes/nodes and retain a digest to private storage when it contains sensitive state. Default telemetry carries classifications/counts, not raw rules, commands or world states.

A SHA-256 digest is reproducible attribution, not confidentiality or proof. Host-specific signing/attestation can be added outside the receipt's mathematical meaning. An administrator able to replace model/checker binaries is outside an unsigned receipt's trust guarantee.

## Evidence and compatibility

EMR-T1: identical explicit semantic inputs have the same semantic digest but independently recorded execution metadata. EMR-T2: changing a bound, encoder, import or assumption changes identity. EMR-T3: worker replacement and concurrent model-load failures cannot return a falsely matched receipt. EMR-T4: legacy inconclusive results stay inconclusive. EMR-T5: output overflow, cancellation and queue timeout retain their dispositions. EMR-T6: a witness reference verifies against the exact model/input and never contains undisclosed fabricated steps. EMR-T7: secret/private-state canaries do not appear in telemetry.
