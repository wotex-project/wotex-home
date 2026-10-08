# Single-schedule temporal admission content v1

Version: 0.1.3. Independently bound software content, 2026-10-08. WOH.04 and
WOH.07 own admission semantics; WOH.14 owns durable activation, occurrence
consumption and execution. Constructing this content creates no Store admission,
active generation, clock trust, receipt or effect.

`home-single-schedule-light-admission-v1` is separate from
`home-explicit-light-admission-v1`. Its closed canonical JSON object, at most
262,144 bytes, has eleven fields: profile, scope, exact source and rule documents,
one complete declaration/resource snapshot, invariant pin, portable-selection
pin or null, complete timezone record or null, temporal correspondence basis,
mandatory guards and the fixed physical-qualification obligation. Scope is
`single_schedule_absolute_effect`. Unknown fields and noncanonical bytes refuse.

The source target and resource revision join the declaration snapshot. Only the
existing exact ordinary Boolean Light-power declaration is supported, with one
absolute effect, literal-true predicate, ownership 1 ms, zero cooldown and one
causal effect. The inert rule body uses the existing closed compiler grammar;
it does not acquire explicit admission. The proposal-only correspondence basis
is reused solely for the absolute effect's source/IR semantics. Temporal
calculation and guards have their own profile, obligations and digest domain.

The invariant pin has exact target/revision/digest fields; zero revision requires
null digest. A portable pin binds target, artifact/projection digests, selection
revision/generation, trust revision and resource revision. Selection and trust
use global journal revisions; the target's resource revision is an independent
declaration counter. Trust cannot postdate selection, and the resource revision
must match the source target's exact declaration counter. Null means a
compiled-profile basis, whose actual
absence of a portable selection must later be established inside the Store.
None of these caller-independent shape checks establishes current authorization.

Calendar content retains exact name, digest and canonical base64 of all original
TZif bytes, bounded to 65,536 decoded bytes. Re-decoding checks the full digest,
selected source, resolved one-shot label and the conservative single-candidate
[cadence bound](schedule-planner-v1.md). Interval/countdown content refuses an
unused timezone rather than silently discarding it. Historical decoding never
substitutes today's installed zone or calls an optional verifier.

`single-schedule-temporal-v1` has scope
`calculation_and_guard_correspondence`. Its closed basis binds canonical schedule,
rule and declaration bytes, proposal-basis commitment, timezone digest and the
complete compiled Home application under `wotex-home.single-schedule-runtime.v1`.
SHA-256 of its remaining canonical fields binds the basis itself. Historical
content may retain a different runtime commitment; current use requires the
entire independently computed artifact to match.

The qualifier keeps one bounded positive correspondence result in each caller
process. Before every lookup it revalidates the closed source, single declaration
set and calendar cadence, and freshly inventories the complete loaded/file Home
runtime, including the verifier. Exact source, rule, declaration, timezone,
profile, scope, obligations and runtime bindings select the result. A cold or
changed binding runs all temporal and proposal correspondence checks and repeats
the runtime inventory before publishing its positive result. Invalid inputs or
unavailable runtime clear the result; failed correspondence cannot populate it.
Historical decoding and caller-supplied basis bytes never seed this cache.
Process termination discards it, so Store restart begins cold.

This reuse covers pure source/runtime correspondence only. Every current Store
admission still checks the original author, epoch, grant, exact declaration,
profile selection and invariant. Clock custody, occurrence eligibility, report
freshness, qualification, causal spend, serialization and the final handoff
repeat run on current owned state. Complete history validation still runs before
and after transactions. No schema, retained artifact shape, admission scope,
report-age limit or physical-dispatch default changes.

The executable temporal argument checks integer half-open windows and tolerance
boundaries against a separate interval-containment reference, duplicate/backward
cursor traces, a decades-long bounded forward skip, no later retry after an
uncertain occurrence and boot/generation-scoped countdown boundaries. Guard
correspondence covers all 18,432 finite combinations of eight Boolean inputs,
three invariant decisions, two override states, four window decisions and three
active-count equivalence classes (zero, one, more than one). No multi-writer
arbitration is inferred from this single-active profile.

Guard precedence is maintenance, supported active set, generation, admission,
original author, exact target grant, profile, invariant, override, already
considered coordinate, whole occurrence window and capacity. These are pure
decisions over supplied truth values. The owning Store must independently derive
their current truth and repeat them at occurrence commit, queue, claim and final
handoff. It must reserve capacity, preserve causal spend and unknown receipts,
retain a no-repeat watermark through compaction, fence activation and author
loss, quarantine restore/transfer and prove same-owner restart before autonomous
delivery. No privileged runner identity can replace a missing original author.
Clock qualification and physical qualification remain separately required.

Eleven focused tests cover exact input/runtime binding, historical versus current
runtime, original timezone custody and replacement refusals, altered declaration,
source, proof and guard lists, exact portable/invariant pins, unsupported effects
and composed sets. Separate fresh Elixir processes deliberately replace the
guard with unconditional allow, the window with unconditional eligibility and
the planner with a replaying cursor after warming the result. Loaded/file drift
first refuses runtime availability; matching replacement files still rerun and
fail correspondence. A deleted artifact, forged proposal commitment, expanded
declaration set and changed source also exercise warm-result boundaries. These
software checks do not establish the future durable scheduler transitions,
installed clock/host sleep qualification or physical actuation.

A private, silent call-time profile selected the same actual interval, one-shot
calendar and countdown ACK/observation traces before and after this change. The
baseline run passed three tests in 25.8 seconds (seed 807084); the first changed
run passed three in 14.1 seconds (seed 862120). Full guard comparisons decreased
from 1,935,360 to 55,296, exactly three cold proofs of 18,432 cases. Current
admission remained 102 calls, lifecycle history validation 248 calls and effect
history validation 271 calls. This is a bounded software measurement on this
host, not a latency guarantee, installed clock qualification or hardware result.
The later closed-input cardinality regression was added before final validation.

Final mechanism validation passed 92 tests (seed 8011, 138.4 seconds) across
artifact/runtime/proposal checks and actual durable admission, lifecycle and
occurrence suites. After strengthening direct matching-runtime replacement
coverage, all 21 pure checks passed (seed 634914, 5.8 seconds). Both runs freshly
compiled 259 Home modules against the selected locked test dependency cache;
neither selected suite omits socket tests through a socket-free filter. These
runs establish software guard/recovery behavior only.

The combined actual interval, calendar and countdown execution run then passed
all 200 traces in one fresh process (seed 994781, 745.7 seconds; 152 unrelated
cases excluded by trace tags). It retained the production report-age limits,
final guards and default-disabled physical dispatch. Each trace compares the
independent model with actual SQLite transitions, immutable history and causal
spend. Earlier freshness refusals remain recorded in their owning corpus
documents; this successful run does not turn them into installed-host timing or
physical qualification evidence.
