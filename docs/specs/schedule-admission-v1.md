# Single-schedule temporal admission content v1

Version: 0.1.1. Independently bound software content, 2026-10-08. WOH.04 and
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
revision/generation, trust revision and resource revision. Its selection cannot
postdate its declaration. Null means a compiled-profile basis, whose actual
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
content may retain a different runtime commitment; current use repeats the
calculations and requires the entire freshly built artifact to match.

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

Eight focused tests cover exact input/runtime binding, historical versus current
runtime, original timezone custody and replacement refusals, altered declaration,
source, proof and guard lists, exact portable/invariant pins, unsupported effects
and composed sets. Separate fresh Elixir processes deliberately replace the
guard with unconditional allow, the window with unconditional eligibility and
the planner with a replaying cursor; all three fail correspondence. These
software checks do not establish the future durable scheduler transitions,
installed clock/host sleep qualification or physical actuation.
