# Composed routine profile v1

Version: 0.1.3. Updated: 2026-10-16. Status: accepted target.
Owner: WOH.20 H20-02/03/04/05/09; WOH.04 admission; WOH.07 correspondence.
Implementation: planned Home profile; the generic producer is separately implemented.
Evidence: source reconciliation only; RCP-T1–T8 are unexecuted obligations.

## Purpose and ownership

Define the finite source and calculation envelope for Home's first composed
routine profile. A scene with two parallel branches followed by a bounded wait
has one immutable expanded program, including its unchosen alternatives and
every invoked child copy. Its possible effects are counted before a condition,
current-state match, conflict or batch cutoff removes work from a particular cut.

This contract selects Home bounds and defines their measurement. WRO.01 owns
installed Basis, Fact, units and JSON validation; WRO.02 owns source, compilation
and execution; WRO.03 owns due coordinates. Use their public operations rather
than implementing another source grammar or evaluator in Home. Compilation of
supplied claims remains inert. Store must independently establish their current
authors, mappings, facts and complete membership before any durable use.

The existing explicit-rule mapping, one-effect admission, single active rule,
single active schedule, original receipts and causal ledger keep their current
formats and limits. This profile is a separate selection. An old admission does
not authorize its wider source, and a new calculation cannot be submitted to the
old activation route as an equivalent single-effect rule.

## Dependencies and entry state

The inspected producer is WoTEx `973fb32c`; Home's consumed routines revision
remains `d1b2e87b`. The producer's
`docs/packages/wotex-routines/specs/bounded-run-continuation-v1.md` owns explicit
aggregate Limits, neutral resume, Time@2, Run@2, current-state satisfaction and
complete pending Collection@2. Its bounded software milestone is recorded in
`docs/packages/wotex-routines/provenance/bounded-continuation-2026-10.md`.
This source review neither changes Home's lock nor establishes Home adoption.

Required public operations are `Wotex.Routines.Profile.new/1`,
`Wotex.Routines.Limits.new/1`, `Wotex.Routines.Source.new/3`,
`Wotex.Routines.Compiler.compile/4`, `Wotex.Routines.Compiler.current/4`,
`Wotex.Routines.Compiler.to_map/3`, `Wotex.Routines.Kernel.advance/7`,
`Wotex.Routines.Collection.evaluate/3`, `Wotex.Routines.Collection.to_map/3`
and `Wotex.Routines.Arbitration.decide/5`. Constructors validate representation;
they do not attest that an installed Home context is current.

The [kernel adoption contract](routine-kernel-adoption-v1.md) retains its narrow
Boolean mapping and fixed logical initial time. The
[external input contract](routine-external-inputs-v1.md) owns reviewed read-only
Mapping installation and current requested-scope Facts. Neither supplies a
composed output mapping, active-set certificate or positive composition proof.
The latter contract's maximum requested input scope is not a routine binding
limit or proof of complete program membership.

Before composed activation, the remaining Home contracts must freeze:

| Contract deliverable | Required content and refusal until delivered |
| --- | --- |
| [Installed composition mappings](routine-composed-mappings-v1.md) | Accepted closed source/selectors, scalar/externally reviewed semantic matrix and exact Basis/Registry construction; implementation and current Store/admission joins remain planned. No arbitrary caller registry is installed. Unsupported outputs remain unavailable for execution. |
| Complete active-set snapshot and clock custody | [Durable membership](routine-active-membership-v1.md) specifies the complete selected family and reviewed legacy replacement. [Independent clock bases](routine-clock-bases-v1.md) specify custody/Time@2. Complete current facts/pending work, validity and capacity encodings remain planned. Requested/provided-set receipts cannot substitute. |
| Durable run/step/root journal | Exact immutable encodings, atomic reservation/receipt links, no-refund accounting, queue/claim/handoff guards, cancellation, retention, migration, Integrity and Backup joins. Legacy one-effect roots retain their meaning. |
| Composed correspondence and admission | Exact supported proof scope, independent source/run/Store oracles and mutations, complete runtime identity and current activation guards. Existing single-effect correspondence and unsupported frozen models cannot admit this profile. |
| Client and host delivery | Closed authenticated use cases/framing, bounded owner queues and honest per-step outcomes; installed and physical obligations remain separately owned. |

These are unfinished entry conditions for activation, not discretionary defaults
for an implementation. No migration number or producer pin is reserved here.
Pure profile construction and bounded source checks may be implemented only
after this contract's entry fixtures are authored and reviewed.

## Exact selections and input boundary

**RCP-01 — One named Home selection.** The descriptive Home identity is
`wotex-home.composed-profile@1`. It does not add a field to the closed producer
Profile. Supply exactly all twelve selections below to Profile.new/1:

| Profile member | Exact selection | Measurement |
| --- | --- | --- |
| source_bytes | 32768 | Maximum canonical bytes for each individual source |
| source_depth | 16 | Producer JSON source-depth bound |
| expanded_nodes | 64 | Every expanded step node, including structural nodes and invocation wrappers |
| predicate_nodes | 64 | Every expanded predicate node, including root/child conditions and both conditional arms |
| invocation_depth | 4 | Maximum nested invoke edges; root depth is zero, children can have depth one through four |
| parallel_width | 4 | Branches in each parallel node; this is not a global simultaneous-effect limit |
| effects | 16 | Every possible expanded effect leaf |
| waits | 16 | Combined expanded wait and delay nodes |
| active_definitions | 64 | Global independently activated definitions; also the producer's separate per-compilation closure bound |
| active_runs | 64 | Nonterminal root runs; at most one per active immutable revision |
| pending_work | 1024 | All currently eligible proposed/reserved leaves before grouping or cutoff |
| run_ms | 86400000 | Positive root duration ceiling in elapsed milliseconds |

The root plus at most 63 supplied child definitions fits the per-compilation
closure bound. An invoked child is not an independently activated member merely
because its source occurs in that closure. Conversely, an independently active
child revision has its own membership slot even if another program also invokes
it. The global active set counts each independently active definition once;
repeated source copies are still charged separately to each program's expansion
and JSON envelope. These two uses of active_definitions do not certify one
another.

All are ceilings except the fixed identity of the selected Profile itself.
Actual run_ms is explicit and between 1 and 86400000 inclusive; it is never
filled in from the ceiling. Zero effect/wait/invoke counts are legal even
though the producer's required ceiling selections are positive. An explicit
noop is legal syntax, and supplies no effect reservation or successful send.

Use this complete six-member JSON Limits selection for composed calculation:

| Limits member | Exact selection |
| --- | --- |
| max_bytes | 67108864 |
| max_depth | 64 |
| max_nodes | 2000000 |
| max_string_bytes | 65536 |
| max_collection_size | 8192 |
| max_integer | 9223372036854775807 |

These aggregate limits permit the complete 64-member/1024-pending workload;
they do not promise that every Cartesian product of maximum-size member
documents fits. Count every embedded occurrence, including duplicate retained
prior/busy values, full program/context copies and transition bases. Check both
the full input and full output. Nested copies are not shared for byte/node
accounting. No aggregate limit changes the explicit-rule or external-input
formats' independently selected limits.

**RCP-02 — Complete generic inputs.** Source and context are complete WRO.02
values, not a partial IR or Home command. Source has exactly format, profile,
id, revision, parameters, bindings, trigger, condition, steps, overlap and run_ms;
format is `wotex.routines.source@1`, profile is `bounded-composition@1` and
overlap is reject. All required members, including empty parameters and explicit
true condition, are present. Context has exactly registry, bases, bindings,
definitions, arguments and compiler_basis. There are no Home-added members.

Source is a closed generic syntax: manual/due/countdown/edge triggers;
literal/eq/gt/lt/not/all/any conditions; and noop/effect/sequence/parallel/if/
wait/delay/invoke nodes. All required members and typing follow WRO.02. Manual
has no trigger payload. Temporal triggers bind an exact schedule id/digest.
Reported edges bind one qualified observable input, explicit direction, debounce,
cooldown and null Boolean or exact integer hysteresis. Nonnegative debounce/
cooldown values are bounded by max_integer; wait/delay durations are positive
and at most the containing source's explicit run_ms. No omitted field selects
a default; an unknown construct is a refusal, never a noop.

Compilation receives the entire exact child-source closure and parameter values
up front. Missing, duplicated or mismatched definitions/parameters, recursion
anywhere in the supplied closure, malformed native structs, extra fields,
invalid UTF-8, duplicate JSON object keys, floats in integer/typed positions,
precision loss and exceeded
bounds refuse before returning a Program. Validate bytes before decoding and
native values before trusting their struct name. Canonical JSON is compact
UTF-8 with recursively sorted object keys through `Wotex.JSON.encode/2`; array
order, integer values and string bytes remain significant. Object key order
alone cannot change canonical identity.

Context may describe claims for an inert calculation. Production context must
be assembled by Home from reviewed installed mappings; a caller cannot choose
compiler_basis, source trust, permissions, resource domains or executable
semantics by supplying this context. Unsupported quantity shapes/units may
remain readable under their reader contract. They refuse routine projection
unless the installed mapping and executable/proof profile represent them
exactly. In particular compound HSV/XY values are not coerced to a scalar,
Boolean or enum merely because those types exist in the selected producer.

## Counting, identity and calculation

**RCP-03 — Count the expansion.** Charge all possible paths after exact argument
binding. A conditional costs its own node plus both complete child trees. Each
invoke costs its wrapper, the invoked child's condition and every node of that
invocation's expanded body. Two calls to one child count twice. A child source
included but never invoked is structurally validated and retained in source
identity; it contributes no executed-tree node/effect/wait count. A child trigger
does not start an independent root. Its condition and narrower run duration
remain part of the invoked tree.

Count predicate syntax nodes before postfix lowering: a literal/comparison is
one, not is one plus its argument, and all/any is one plus all operands. Count
root and invoked-child conditions, if conditions and wait conditions. Both
branches and repeated child copies count. Source JSON depth, compiled path
length and invocation depth are distinct. Retain WRO.02's compiled-path ceiling
of 32 integer elements; no Home join concatenates source IDs to create paths.

Examples are counting obligations, not accepted production programs without
their full source/context: parallel with four effect children costs five nodes
and four effects; two such nested parallel nodes can expose eight eligible
effects despite each local width being at most four. A sequence with two invokes
of a child containing a two-effect sequence costs nine nodes and four effects
(one parent sequence, two invoke wrappers, two child sequences, four leaves).
The root true condition plus two child true conditions costs three predicates.
A fifth nested invoke or a seventeenth effect/wait refuses even if its branch
is false or its current reported value would suppress a send.

**RCP-04 — Bind the full program.** Compiler.compile/4 must return a complete
Program; Compiler.current/4 must regenerate it against the independently
provided current context before use. Compare the complete regenerated value,
not only source_digest, ir_digest or a selected output leaf. Compiler.to_map/3
against the retained context establishes internal correspondence only.
Source identity binds the supplied child closure, parameter values and mappings;
IR identity binds the normalized expansion, Profile and compiler identity.
Equal source content under a changed installed/compiler/runtime basis needs
fresh review/correspondence; historical bytes and receipt identities stay intact.

Home's bound checks must agree with the public compiler for the entire tree.
Do not implement a second normalizer. If an independent counting check and the
producer disagree, return a refusal; never silently choose the smaller count.
Neither matching hashes nor a valid Program constitutes positive admission.

**RCP-05 — Collect before cutting.** Each current eligible proposed or reserved
effect counts toward pending_work, including all equivalent contributors and
leaves omitted from a prior batch. Only after the full Collection@2 has passed
validation may arbitration select at most sixteen effect groups. A reserved
contributor remains retained work, not a request to reserve or send it twice.
1024 pending leaves fit the profile; 1025 refuse regardless of batch_limit.

Use neutral resume for a retained live original. A nil event or a rejected new
busy original cannot hide its pending work. Handle the new trigger's skipped-busy
history separately. Terminal runs, handed-off steps and current-state satisfied
steps produce no pending proposal. Current conditions can temporarily exclude
an unsent leaf without rewriting its original or refunding its reservation.
Collection completeness is relative to supplied membership; Home must still
certify the complete actual active set under the separate Store contract.

**RCP-06 — Refuse whole calculations.** Overlarge input, output, expanded tree,
collection or retained run returns a typed refusal and no truncated/partial
collection, Program, approval or command. Never raise Limits, split membership,
drop an unchosen branch, remove a conflicting late member or fall back to the
legacy evaluator in response. Future activation must check the complete
prospective set's capacity; a valid individual Program alone promises no
aggregate capacity. If current data cannot fit, return a blocked capacity
outcome for the whole cut and create no new effect reservation from that cut.

Pure operations return the producer's payload-free `Wotex.Routines.Error` with
its code/path and no caller document or private report. Boundary constructors
retain their named structural/bound refusals. Home-facing error translation
belongs to the later authenticated use-case contract; it must distinguish
unsupported semantics, exceeded capacity, stale basis and absent producer.
It cannot translate any of them to completed, already-satisfied or permission.

## Failure, compatibility and recovery

This profile selection owns no process, timer, file, database or durable retry.
Repeating a pure calculation with identical inputs yields the identical Program
or refusal; it neither creates nor resumes a Home operation. Missing producer
APIs refuse before generic calculation. Loss of an analysis backend cannot
turn unsupported/inconclusive results into positive correspondence.

New Time@2/Run@2 and Collection@2 are explicit selections, not a reinterpretation
of old formats. Fixed logical Time@1 in the existing explicit-rule path stays
inert and cannot be reused for composed deadlines. The current countdown clock
contract still requires qualified monotonic continuity; a Store receipt tuple
alone supplies no installed elapsed-clock qualification. Separate elapsed/UTC
custody, restarts and wake discontinuity must be specified before live composed
continuation. No backup migration manufactures new current authority, elapsed
continuity or positive proof from a decoded Program.

Admission, lost-reply recovery, nonrefundable roots, current-state satisfaction,
cancellation and uncertain handoff remain obligations of the pending composed
Store/journal contracts. This document does not declare them implemented by
restating the pure producer. Physical dispatch remains default-disabled.

## Acceptance and implementation entry

Before implementing this Home profile, freeze independent source/count vectors
and complete canonical producer inputs in the owning test fixtures. A reference
counter must traverse source/child declarations independently of the producer's
IR, compiler helpers and Home production counter. Expected counts and refused
boundaries must be hand-auditable. Add exact-limit and one-over cases, not tests
that only mirror the selected constants. No installed source, clock or device
is needed for this pure evidence.

| Case | Requirements | Setup and expected observation / falsifier | Evidence level |
| --- | --- | --- | --- |
| RCP-T1 | 01–02 | All twelve Profile and six Limits selections round-trip unchanged; missing/extra/zero/altered selections refuse the Home selection; existing rule/input limits remain unchanged | Pure native |
| RCP-T2 | 02–03 | Independent vectors cover 64/65 expanded nodes, 64/65 predicate nodes, 4/5 nested invokes, 4/5 local parallel branches, 16/17 effects and combined waits/delays; false branches and repeated children still count | Independent pure |
| RCP-T3 | 02–04 | Exact parameter types, child versions and units succeed; recursive unused closure, bad argument, duplicate key, malformed native value and unsupported compound projection refuse; no no-op substitution | Pure native |
| RCP-T4 | 03–04 | Independently counted two-invoke and nested-parallel examples match complete public Compiler output. Isolated omitted-branch, omitted-child-condition and wrong-path mutations are caught through assertions | Independent pure/mutation |
| RCP-T5 | 04 | Changing unused closure bytes, parameter value, selected mapping, compiler/runtime identity or rehashed IR refuses old correspondence; object-key reordering alone preserves canonical bytes | Pure native |
| RCP-T6 | 01, 05–06 | 64 coherent members expose 1024 pending leaves; repeated 16-group cuts retain every original. A final-member conflict is detected before cutoff; 1023 pending selection and missing live continuation refuse whole collection | Independent producer/native |
| RCP-T7 | 01–02, 06 | Construct exact byte/depth/node/collection limits and one-over values including nested input/prior/output copies; refusal returns no partial cut. A schema-valid individually fitting program cannot bypass aggregate refusal | Pure native |
| RCP-T8 | 02, 04–06 | Invoke existing admission with a composed source, new profile or generic valid Program; it refuses and leaves old active rows/originals/charges unchanged. Producer absence and unsupported analysis cannot activate the new profile | Actual Authority/SQLite software |

RCP-T6's generic producer analogue is already exercised in its own milestone;
Home must run the actual selected dependency/cohort rather than cite that result
as Home evidence. RCP-T8 needs a real Store transaction, not a source search.
Catalogue H20-T2/T4/T8 remain incomplete until their larger owning obligations
also have evidence. Record exact source, lock, toolchain, fixtures, command and
results when these cases execute. No test or archive here qualifies a host clock
or physical effect.

## Sources and decisions

Reconciliation used Home `b3a4a272` (`Rules.KernelMapping`, `Rules.KernelProposal`,
`Rules.RestrictedBasis`, `Durable.Store.RuleWriter`, `Schedules.ClockSample`
and `Durable.Store.ClockContext`) and WoTEx `973fb32c` (public Profile, Source,
Compiler and Collection contracts; implementation read only to check counting
semantics). The original research is retained at Home `f454204`; it supplies
motivation, not executable grammar or acceptance evidence.

Local parallel width and nested invocation depth are now explicit to avoid
confusing four branches per node with four total pending effects, or four
nested calls with four total tree nodes. Delay consumes the same finite waiting
budget as wait. Aggregate JSON capacity is independent of semantic activity
capacity. These choices preserve WOH.20's complete-set and sixteen-effect
obligations while closing previously implicit measurements.
