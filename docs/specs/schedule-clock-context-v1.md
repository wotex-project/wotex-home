# Lazy writer clock context v1

Version: 0.1.1. Implemented borrowed-call context and receipt-clock integration,
2026-10-08. WOH.14 owns the single writer and final guards; WOH.04 owns the
separate temporal confidence. This prepares the execution boundary and grants
no schedule activation, occurrence, clock trust or physical authority.

Store constructs one context for each affected rule invocation, power admission,
claim or handoff call. It contains three lazy trusted callbacks: Store receipt
clock, purpose-specific temporal snapshot and current host timezone source.
Ordinary rule, invariant and execution mechanisms sample only the receipt
callback. They do not read UTC, acquire temporal custody or require an available
clock source. Existing trusted test/firmware receipt-clock functions retain
their original tuple behavior; those functions can never supply a temporal
snapshot through this context.

Temporal sampling reads the Store receipt clock before and after the private
source callback. The five-field snapshot is closed: complete scope, original
sample, checked monotonic coordinate, uncertainty interval and reason. Its
six-field scope contains deployment, owner, authority epoch, Store boot epoch,
clock generation and runtime digest. Actual source authentication and complete
scope come from the [Store-bound clock owner](schedule-clock-owner-v1.md),
not from parsing this context or from a caller-created map.

Both receipt samples must share a valid boot and nondecreasing signed-64
monotonic coordinates. The returned coordinate must lie between them; scope
boot, sample boot and clock generation must join. Samples retain their closed
codec and cannot be from the future. Qualified snapshots must have no refusal
reason and exactly equal the independently advanced original sample interval.
Explicit unqualified snapshots retain null UTC and the typed unavailable reason.
Malformed, expanded, mismatched, stale or failing callbacks refuse temporal
confidence. Typed corruption errors propagate for the owning Store health gate.

The timezone callback is separate from temporal sampling. Its source must first
pass the complete closed schedule codec. Calendar results retain exact name,
digest and independently redecoded TZif bytes; an interval/countdown accepts
only no zone. A receipt-clock function, absent zone, altered parsed offsets or
substituted name/digest cannot supply calendar custody. Store's writer callback
uses the fixed host timezone root; public requests cannot select it.

The actual Store temporal snapshot now uses this context and continues to
withdraw an unavailable installed clock owner under a new boot-local generation.
Its legacy source-free state remains explicitly unqualified. Rule/invariant/
power guards use the same current Store receipt clock as before. Temporal
reservation, queue, claim and handoff consumption and durable schedule lifecycle
remain following work; a valid context is not itself an execution artifact.

Six focused context cases use independent signed-clock interval vectors, verify
callback laziness, both surrounding receipt samples, malformed/future/expanded
scope, explicit unqualified state, rollback and callback failure, typed corruption
and complete timezone correspondence. Together with actual clock ownership,
power handoff, rule activation, invariant and causal-root regressions, 94 tests
pass. These are software boundary checks, not installed clock or physical
qualification.
