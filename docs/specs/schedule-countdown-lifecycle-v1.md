# Retained countdown admission and expiry v1

Version: 0.1.1. Implemented single-schedule Store transitions, 2026-10-08.
WOH.04 owns temporal admission, WOH.14 execution and WOH.16 recovery.

The separate [independent execution corpus](countdown-execution-traces-v1.md)
checks complete event sequences against a boot-local reference in qualified and
unavailable wall-time modes. Its bounded software evidence retains the current
artifact scope and installed/autonomous qualification obligations.

A countdown source binds an original Store boot, clock generation, past start
and duration of one second through 24 hours. New review/admission and activation
require the actual Store-owned clock context and a strictly future due
coordinate. The final content guard repeats that boundary after enclosing
history validation. Exact immutable retries resolve first and need no current
clock. No caller-supplied current clock, bearer transfer or source
installation is introduced.

Current readiness is separate from initial activation: reaching due does not
suspend the definition. Each consideration and effect boundary requires the
original boot/generation and qualified continuous monotonic sample, unchanged
owned scope, nondecreasing observation and original maximum sample age. Qualified
UTC is optional for this source. A monotonic-only sample retains null UTC and the
existing wall-time-unavailable reason; calendar/interval sources still refuse
it. The private host clock owner supplies no installed monotonic-only source.

The existing planner consumes one deterministic countdown coordinate at most
once. Early polls retain nothing. At due it can retain an ordinary held request;
at or beyond the half-open late-window end it retains one expired consideration
with no request or root. The actual queue, claim, handoff, acknowledgement and
reported-state paths retain their ordinary author/grant, profile/runtime,
invariant/override, fresh report, whole-Thing, causal and worker-ownership guards.
Holding, queueing, handoff, protocol acceptance and observed state stay distinct.
The declared temporal artifact scope remains calculation/guard correspondence;
autonomous and composed runtime qualification remain work.

An observed loss of the original continuous clock, a clock-generation withdrawal
or a normal Store restart permanently withdraws the current countdown through
the existing generation fence. It rejects held/queued/claimed work and preserves
handed uncertainty and original causal spend. The actual new boot is allocated
before startup recovery. Countdown expiry and handed-work recovery share one
SQLite transaction before requests are served, without consulting empty cold
profile custody as if it established a current loss. Already superseded
generations are not fenced again. Retired/read-only and quarantined recovery
modes create no countdown expiry or activation authority.

Expiry uses the existing immutable lifecycle table with the distinct closed
canonical record `wotex-home.schedule-countdown-expiry.v1`. Its seven ordered
members are format, original activation revision, original authority epoch,
expected Store revision, cause, observed boot and observed clock generation.
Causes are `countdown_missed:old_boot`, `countdown_missed:clock_changed` and
`countdown_missed:clock_unavailable`. Activation/epoch are positive signed-64
integers; expected revision is at least activation. Boot is a bounded Home ID.
Generation is nonnegative signed-64; zero records actual exhaustion and never
clock confidence. Null generation is allowed only when the source could not
supply a validated current sample. The record contains no UTC, monotonic due
coordinate, qualified future sample or effect authority.

The reserved withdrawal operation hashes those exact bytes. Historical checks
join the original source, activation, author, epoch, predecessor, generation,
barrier, journal and affected/unknown counts. Old-boot expiry requires a different
source boot; generation loss requires the same boot and different generation;
unavailable custody retains the same boot and null or original generation.
Expanded, noncanonical, substituted or malformed records refuse. Existing
generic withdrawal bytes remain unchanged and cannot impersonate this cause.
No table, schema version or archive table set changes.

A final clock loss cannot preserve a tentative queue, claim, handoff or poll.
The enclosing savepoint restores original work before rebuilding the captured
expiry barrier, retaining the actually observed cause even if custody returns.
A failed expiry publication rolls back the complete barrier and pending changes;
the writer is disabled. Explicit clock invalidation adopts its new transient
generation and removes poll/claim ownership only after that durable transition
commits. Startup publication failure releases the host lock and leaves prior
history available for a subsequently validated startup.

Fresh custody cannot resume the missed activation. New activation of the exact
expired countdown source also refuses, including when the original same-boot,
same-generation clock returns before due. A new countdown requires new source
content and ordinary current admission/activation. Existing original receipts
remain principal-private immutable history.

Focused software checks cover actual private-clock admission, substituted
boot/generation/start/due refusal, due/late consumption, same-generation return,
restart, source withdrawal, SQL rollback, framed adapter recovery and exact
causal rows. Controlled monotonic-only execution traverses held, queued, claimed,
durable handoff, acknowledgement and observed settlement, then actual Store
restart. Final queue/claim/handoff clock-loss faults check restored phase and
zero tentative handoffs. These fixtures establish software correspondence;
they do not qualify installed clocks/sleep, target-storage power loss, controller
transfer, native countdown creation, autonomous timers or physical hardware.

On 2026-10-08, all 107 affected admission/lifecycle/occurrence, framed API,
clock/context and closed-expiry tests passed. A separate run passed 25 selected
execution cases: twelve countdown phase/final-fault cases, twelve existing
restored-withdrawal cases and one actual interval restart trace. The specified
calendar selector in that run matched no case and supplies no evidence.
A six-case follow-up passed four countdown final-poll fault boundaries, one
actual one-shot calendar claimed-expiry trace and the interval restart trace.
The initial final-poll publication-failure probe exposed a raw SQLite error
incorrectly classified as policy; its corrected rerun rolled back all rows and
disabled the writer. The earlier 105-case run had one typed UTC clock-refusal
regression; preserving that refusal preceded the clean 107-case run.
