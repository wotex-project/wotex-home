# Explicit rule kernel adoption v1

Version: 0.1.4. Updated: 2026-10-15. Status: accepted target.
Owner: WOH.20 H20-02/03/06/08/10; WOH.04 rule admission; WOH.14 durable execution.
Implementation: partial — pure mapping and initial-proposal checking in RKA-01–03.
Evidence: bounded pure/software checks in the
[kernel adoption record](../provenance/routines-kernel-2026-10.md).
Current v4 proof and actual Authority/Store adoption remain planned; no durable
invocation or physical qualification is established by these pure helpers.

## Scope and prerequisites

Use the selected public `Wotex.Routines.Compiler` and `Wotex.Routines.Kernel`
to produce the initial proposal for Home's admitted explicit Boolean Light
rule. Authority calculates outside the Store writer; Store independently repeats
current authorization, source and proposal bindings before creating held work.
The same public invoke operation and durable originals remain available.

This is the initial-proposal join for the existing single-effect profile. Home
continues to own its receipt phases, causal root, serialization, qualification,
attempt history and physical execution. The generic initial Run is an inert
validation value; it is neither persisted nor advanced using fabricated
admission/handoff receipts. Composed runs, sensor predicates, active-set
collection and generic completion progression remain required later stages of
WOH.20, with their own schema and admission obligations.

The [archive shadow profile](routine-shadow-v1.md) compares draft Sandbox policy.
That draft suppresses an already desired value; admitted explicit invocation
currently creates held work independently of desired state. Matching current
reports may close held work without sending at the later admission boundary.
Preserve this distinction. Keep Sandbox as draft evaluator and independent
oracle; merely calling Kernel in that sandbox does not implement this contract.

Consume the exact selected Routines public Compiler.compile/4, Compiler.current/4,
Compiler.to_map/3, Kernel.advance/7, Limits.new/1, Profile.new/1, Basis.new/3,
Basis.semantic_digest/2, Registry.new/2, Snapshot.new/4 and Run.to_map/4 APIs.
Use core Wotex.JSON.encode/2 for bounded, recursively sorted canonical JSON.
No private producer module, test vector, example registry or ambient provider
may supply production semantics. The selected civil cohort already contains
these public APIs; producer absence is a refusal, not an ownership blocker.

## Closed mapping and bounds

**RKA-01 — Preserve supported input.** The pure join accepts one fully valid
Home Rule and its exact valid Thing: literal-true predicate, explicit-request
trigger, automation authority, block-unknown policy, Boolean power write to an
ordinary Light, causal budget one and cooldown zero. Preserve the existing
proposal proof's ownership range 1–86400000 ms and valid additional declaration
content. It remains bound by the complete declaration digest. Durable admission
continues to require ownership exactly 1 ms and the existing single-capability
DirectPowerSafety subset. No wider pure input becomes admitted execution.
Reject malformed native structs, foreign IDs, unsupported semantics and extra
required grammar instead of silently projecting a supported subset.

Use these exact selections; every member is explicit, with no inferred default:

| Selection | Values |
| --- | --- |
| JSON Limits | max_bytes 262144; max_depth 32; max_nodes 20000; max_string_bytes 8192; max_collection_size 128; max_integer 9223372036854775807 |
| Profile | source_bytes 32768; source_depth 16; expanded_nodes 8; predicate_nodes 8; invocation_depth 1; parallel_width 1; effects 1; waits 1; active_definitions 1; active_runs 1; pending_work 1; run_ms 86400000 |

The positive waits/invocation/parallel ceilings satisfy the producer's required
positive selections; Home's closed source admits none of those constructs.
The complete projected wrapper must also encode to at most 262144 bytes.
An original admission document is separately bounded by its existing 4194304
bytes and decoded under Home's historical validator before extracting this
small generic input. It is not copied into the generic JSON program.

**RKA-02 — Consumer-owned installed mapping.** Build a closed offline registry
and one installed Boolean power basis in Home. The producer receives only inert
JSON values. No endpoint, bearer, Store connection, grant object or transport
handle enters the generic program or result. Describing a writeproperty supplies
no device qualification or physical authority.

Each of these three contract bodies has exactly keys format, id, version,
obligations. format is `wotex-home.routine-contract.v1`, version is `1` and
obligations is the ordered array below. Its semantic_digest is `sha256:` plus
SHA-256 of its Wotex canonical JSON. Registry records have exact id/version/digest
references and empty requires arrays:

| id | Exact ordered obligations and meaning |
| --- | --- |
| wotex-home.rule-security | current_authenticated_invoker, current_original_author, exact_target_grant, single_store_commit: current invoker permission, current admitted author's authority and grants, exact current target scope and one Store commit remain mandatory |
| wotex-home.rule-lifecycle | inert_proposal, held_before_queue, handoff_before_transport, no_uncertain_retry: proposal is inert; held, queue and handoff are separate; no physical retry follows uncertainty |
| wotex-home.boolean-report | current_qualified_device_report, exact_boolean_equality, no_protocol_inference: current qualified device evidence and exact Boolean equality establish reported match; protocol completion alone cannot |

The basis has format `wotex.routines.basis@1`, id
`wotex-home.boolean-power`, version `1`, annotations `{}`, output null and
required_contracts `[]`. Its affordance is exactly property/power/writeproperty;
value is Boolean, unit null, enum `[]`. It references the security and lifecycle
contracts above. Evidence selects only device_report, freshness_ms from the
validated power capability, require_source_time false, continuity snapshot,
completion reported_match and the exact report-contract reference. Effects have
resource_roles `["target"]`, repeat never, stop separate_effect, supersession
block_until_known, partial_possible true and unknown_possible true. Timing has
deadline_ms equal to the Rule ownership_ms, duration/dwell/cooldown_ms zero,
uncertainty block. Analysis is unsupported, profile null, properties `[]`.

Construct the descriptor body without its four digest fields. byte_digest is
`sha256:` plus the hash of that exact canonical body; semantic_digest uses the
public Basis.semantic_digest/2 projection. implementation_digest and
compiler_digest are `sha256:` plus RKA-04's current runtime digest. The basis
registry record requires all three exact contract references. Validate the
complete closure and basis through public constructors before compilation.
Equal body/semantic hashes do not equate code identity with device qualification.

**RKA-03 — Exact generic source and initial result.** Compile format
`wotex.routines.source@1`, profile `bounded-composition@1`, Home rule id and
decimal source_revision string, parameters `{}`, bindings `["output"]`, manual
trigger, literal true condition, overlap reject and run_ms equal to ownership_ms.
Its only step is id power, kind effect, binding output, input the exact requested
Boolean and completion reported_match. Context has the RKA-02 registry/basis,
definitions `[]`, arguments `{}`, compiler_basis `sha256:` plus current runtime,
and output binding to the exact basis reference and mapped Thing IRI, with target
role bound to that same IRI. The mapping is exactly `urn:wotex-home:thing:` plus
unpadded URL-safe Base64 of the raw Home Thing ID bytes. It is injective across
all valid 1–128-byte Home IDs, including IDs without a URI scheme. Whole-resource
domains are exactly that one mapped IRI. Never require Home opaque IDs to be
absolute IRIs or pass a generic IRI back as a new Home device identity.

The invocation's generic original is `home:rule:` plus lowercase SHA-256 of
the deterministic Erlang term
`{"wotex-home.rule-original.v1", principal_id, authority_epoch, operation_id}`.
It cannot substitute for Home's principal/epoch/operation durable original.
Snapshot id is `sha256:` plus preparation_digest, membership_generation is
`rule-generation:` plus the decimal generation, active_programs is the one IR
digest and resource_revisions uses the one mapped IRI as key and actual Home
resource revision as value.
The output binding basis uses the installed semantic digest, source_id
`wotex-home.rule-invocation`, source_epoch `sha256:` plus preparation_digest,
source_time_basis null and fact null. There is no observation or inferred edge.

Kernel receives manual event with that original and program digest, prior
`{"original":null,"busy":null,"edge":null}`, and explicit time epoch
`wotex-home.explicit-kernel`, clock_generation `wotex-home.explicit-kernel.v1`,
elapsed_ms 0 and both UTC bounds null. This is a logical initial-proposal
coordinate. Its prospective ownership/deadline is not a current host clock,
physical duration, new timeout or permission to continue an expired run.

The sole accepted result has exactly run, proposals, outcome, edge, basis.
outcome is running; edge is null. Public Run validation must accept it under
the regenerated program. It has the exact original/program/source/compiler and
logical time, start/last 0, deadline ownership_ms, status running, reason/window
null, one proposed root effect step at path `[]`, started_ms 0, deadline_ms
ownership_ms, branch null, every receipt slot null and spent `[]`. A shortened
step deadline or later last_ms is not the canonical initial result. General
retained Run validity alone does not establish that initial transition.
There is exactly one proposal with the exact program, original, binding, mapped Thing IRI,
whole-resource domains, writeproperty operation, Boolean input, reported_match
threshold and report-contract reference. Path is `[]`; step_original equals the
one validated Run step original. Validate all proposal and basis fields, not a
handpicked target/value pair. Basis must equal the exact event/prior/snapshot/time
and compiler/source/program inputs supplied. Unknown keys or a partial,
completed, reserved, handed-off, spent, zero-effect or extra-effect result refuse.

## Current proof and historical compatibility

**RKA-04 — Current proposal v4.** RestrictedBasis emits
`explicit-boolean-light-v4`, scope proposal_generation_only. Retain the v3
fields and ordered obligations, then append generic_manual_kernel,
exact_single_proposal and complete_kernel_runtime_cohort. Add exactly
kernel_mapping_digest, kernel_source_digest, kernel_ir_digest and
kernel_compiler_profile. The first three are bare lowercase SHA-256 values;
kernel_compiler_profile is `wotex.routines.compiler@1`. Existing compiler_profile,
source_digest and ir_digest still bind Home's closed compiler and rule source.
The generic fields bind the actual RKA-02/03 compilation, not example bytes.
rule_digest uses the v4 profile domain; basis_digest retains deterministic
Erlang-term SHA-256 of all other native fields.

runtime_digest uses the exact ordered applications
`[:wotex_home, :wotex_routines, :wotex_continuum, :wotex, :ex_booking, :decimal, :jason, :ex_json_schema, :nimble_options, :tz]`
and domain `wotex-home.explicit-kernel-runtime.v1`. This is the closure owned by
[RTR-01](routine-temporal-runtime-v1.md). Inventory binds complete application
versions/module lists/retained BEAM bytes, loaded/file consistency and old-code
refusal. This includes every producer dependency even when a requested input is
simple. Bounds and cleanup remain those of the temporal runtime contract.
The mapping/source/IR fields use bare hashes even where public producer JSON
uses its required `sha256:` prefix.
Cold qualification repeats the complete inventory after finite verification.
At most one process-local positive proof may be reused under exact fresh
rule/declaration/runtime bindings; it cannot cache grants, clocks, facts or
historical rows. A changed or failed binding clears it.

Retain the independent existing Sandbox/compiler/gate/root correspondence and
add actual public Kernel initial-proposal checks for the supplied source, both
Boolean values and distinct original scopes. A producer mutation that changes
the source, program, proposal, evidence or original must fail correspondence.
Do not qualify only a fixed example while ignoring the requested rule.

**RKA-05 — History stays history.** Decode exact v3 proof fields, obligations
and hashes without requiring a producer, clock, current grant or new proof.
Current admission requires rebuilt v4 equality. Old rule admissions and their
origin/request/causal rows remain readable and unchanged. A stale old active
rule cannot create or dispatch work; normal current re-admission and activation
are required. Old temporal artifacts remain historically valid; their current
proposal/runtime comparison can withdraw an obsolete schedule under RTR-04.
There is no receipt rewrite, schema migration, root refund, new original or
synthetic proof upgrade on restart or restored data. Existing quarantine holds.

The admission document's proposal_basis encodes every native field using its
known string key; result, scope and the ordered obligations use their known
string values. Decode only the exact profile-specific v3 or v4 grammar, with
the native deterministic-term basis hash intact. Unknown keys, reordered or
missing obligations and mixed-profile fields refuse. Never create atoms from
untrusted strings or call the generic producer merely to decode history.

The existing review_rules preview emits the current v4 proposal projection.
Its exact keys are profile, scope, target_id, rule_digest, registry_digest,
runtime_digest, compiler_profile, source_digest, ir_digest, obligations and the
four kernel fields from RKA-04. It continues to omit result and basis_digest;
preview is informative and supplies no admission authority. The native parser
requires that exact v4 profile, ordered obligations, both compiler profiles,
target equality and all eight bare hashes. A missing/malformed generic member,
extra key or relabelled v3 record is an invalid response. The operation name,
request grammar and recorded original identities do not change.

## Authority and Store transitions

**RKA-06 — Prepare, calculate, commit.** Authority.invoke_rule/6 first asks Store
for an authenticated preparation. Existing Store.invoke_rule/6 remains a client
compatibility entry delegating to the same Authority sequence; it must not call
an old writer path that builds an effect without Kernel. Preparation/commit are
trusted in-process APIs, with no new CLI/socket/pairing/native protocol operation.
The generic call receives only the preparation's checked inert data, never the
credential used to obtain or commit it.

Preparation repeats input validation, current actor control:ordinary permission
and scoped original lookup first. An exact existing rule_id/generation origin
returns its retained request receipt without calculation, new proof or current
target grant. Another origin/manual operation at that principal/epoch/operation
refuses rule_operation_conflict; `occ:` public IDs remain reserved. A new
operation checks maintenance, epoch/generation/active admission, the current
original author's review/manage/control permissions and target grant, complete
source/declaration/profile pins, invoker target grant and current invariant and
override under Store time. It writes no receipt, root, slot or lease.

The prepared native map has exactly format, principal_id, authority_epoch,
operation_id, rule_generation, admission_revision, rule_id, artifact_document,
artifact_digest, runtime_digest, preparation_digest. format is
`wotex-home.rule-invocation-preparation.v1`; IDs use Home's ASCII 1–128-byte
grammar; epoch is 1..9223372036854775807, generation is 0..9223372036854775806,
admission_revision is positive i64. Artifact bytes are the exact current
admission, bounded above, with its existing digest. runtime_digest is RKA-04's
bare hash. preparation_digest is SHA-256 of deterministic Erlang term
`{"wotex-home.rule-invocation-preparation.v1", principal_id, authority_epoch,
operation_id, rule_generation, admission_revision, rule_id, artifact_digest,
runtime_digest}`. This commitment is reproducible and grants no authority.

Authority calculates the actual public Kernel result outside the writer.
The projected JSON map has exactly format, preparation_digest, runtime_digest,
mapping_digest, program, result. format is
`wotex-home.explicit-kernel-proposal.v1`; all three digest fields are bare
lowercase SHA-256 with exact bindings; program is
the complete public Compiler.to_map/3 value; result satisfies RKA-03. No caller
can override a bound, registry, mapping, time, prior state or supported grammar.

**RKA-07 — Single writer repeats.** Commit authenticates again. An exact durable
original wins over a stale calculated result; a conflicting origin refuses.
For a new original, regenerate preparation from current state and require exact
identity/bindings. Unrelated Store revision changes alone do not invalidate it;
every relevant current basis must still match. Recompile/validate the complete
generic program and result under RKA-01–04. Only its checked proposal supplies
the requested Boolean used to create the one Home held request. One transaction
inserts receipt/journal, exact rule origin and causal root under existing limits.
No generic result directly queues, claims, hands off, reports or authorizes work.
No refusal receipt is manufactured for a rolled-back new invocation. A later
retry needs fresh preparation; any already committed scoped original wins.

After tentative publication and enclosing history validation, a final unscoped
guard repeats the current runtime, actor/author/epoch/generation/source, complete
declaration/profile/invariant bindings, invoker grant and Store-owned current
invariant/override decision. A changed basis rolls back every tentative receipt,
origin, root and revision. No earlier positive projection or cached proof can
replace that final read. Queue/claim/final handoff retain their existing fresh
qualification/report, serialization, attempt, causal and current authority
guards. No deadline, freshness bound or default dispatch flag is widened.

| Transition | Result |
| --- | --- |
| Exact original at prepare or commit | Return retained scoped request receipt; no Kernel call required and no new spend |
| Valid new preparation and proposal; all current/final checks pass | One held request with existing origin and initially unspent causal root |
| Producer unavailable/refused, malformed projection or stale current/final basis | Typed refusal, no new original or positive publication; writer remains usable |
| SQL failure or damaged retained history | Complete rollback, store_unavailable or owning corruption error, writer disabled |
| Lost reply, cancellation, restart or old admission | Recover original; preserve committed spend/uncertainty; new authorization is never inferred |

**RKA-08 — Closed failures and cleanup.** Adapter errors are payload-free:
routine_kernel_unavailable for missing required public module/function;
unsupported_kernel_profile for unsupported valid Home semantics;
routine_kernel_refused for a bounded producer refusal or caught producer failure;
invalid_kernel_projection for malformed/mismatched native result or wrapper.
No partial output or fallback evaluator follows any of them. Changed current
preparation returns rule_basis_changed; existing precise actor/grant/epoch/
generation/maintenance/invariant/override/capacity errors retain their meanings.
For invocation, the closed inherited semantic denial set is unauthorized,
principal_unavailable, target_unavailable, permission_denied, maintenance_active,
invalid_rule_operation, invalid_rule_operation_input, rule_operation_conflict,
reserved_operation_id, stale_authority_epoch, stale_rule_generation,
resnapshot_required, rule_inactive, rule_basis_changed, stale_rule_admission,
unsupported_admission_profile, invariant_unresolved, operator_override_active,
rule_capacity, rule_activation_capacity, receipt_capacity, causal_budget_exhausted,
causal_provenance_unavailable, runtime_artifact_unavailable,
profile_selection_unavailable, profile_selection_revoked, profile_trust_changed,
profile_author_unavailable, profile_artifact_unavailable, profile_basis_changed
and profile_lifecycle_required, plus the four adapter errors above. Only these
denials leave Store writable. An inner collaborator's policy wrapper cannot
promote arbitrary SQL messages or unclassified errors to semantic denial.
Historical corruption errors retain their owning fatal classification.
Pure helpers start no process, read no application data/clock/environment, fetch
nothing and
retain no run. Test-only code/file mutations restore matching original BEAMs and
compiler options, stop owned Stores and remove disposable directories.

## Acceptance and delivery

| Case | Requirements | Required observation / falsifier | Level |
| --- | --- | --- | --- |
| RKA-T1 | 01–03 | Both Boolean values, boundary IDs/revisions/ownership and exact mapping/source/program/result; independent expected effect/original; no services or device handles | Pure |
| RKA-T2 | 01–03, 08 | Unsupported input, altered native fields, limits, registry/basis, program/IR, event/prior/time, every result/proposal field, wrong original and forged spend refuse with no fallback | Pure/software |
| RKA-T3 | 03–04 | Actual public Compiler/Kernel call, independently computed source-specific expected result and mutation rejection; retain draft 360-case comparison as separate evidence | Software/archive |
| RKA-T4 | 04–05 | Warm proof changes/refuses each of ten producer members' bytes/version/module list/absence; cold closing drift refuses; exact v3 stays historical and cannot seed current proof | Software |
| RKA-T5 | 06–07 | Authority and compatibility API call Kernel outside writer, one actual held original/root; concurrent same-original invocations/lost replies recover that original without duplicate work | Durable software |
| RKA-T6 | 06–08 | Mutate actor/author grant, epoch/generation, source/declaration/profile, invariant/override or runtime between prepare/calculate/commit and final publication; no stale held work or spent-root refund | Durable software |
| RKA-T7 | 07–08 | Inject publication/final-guard SQL faults: receipt/origin/root/revision all roll back, history stays exact, writer disables; semantic denial stays usable | Durable software |
| RKA-T8 | 05–08 | Actual retained v3 admissions/origins through restart and current refusal; byte-identical history and original recovery with producer absent; old uncertain work never replays | Durable software |
| RKA-T9 | 06–08 | Existing framed/local socket invoke operation returns same scoped receipt/refusal; no new external preparation/commit route or raw-message bypass | Adapter software |

Commit the authored contract before implementation. Deliver pure mapping/result,
current/historical proof, then actual Authority/Store integration in logical
local commits with focused checks. Run the owning rule/temporal mechanism gate
at the adoption milestone. Full application, installed host, load and physical
campaigns remain distinct; no fixture or passing build supplies their evidence.

## Inspected sources and decisions

Source review used Home `6921dc1`, selected Routines
`f3e77a431a917b639f7b0d52a93b78c27def4344`, core/Continuum
`687a5cd70267fa47dbfb36e28eccad6ef2964fdf` and ExBooking
`3fa614cd3cf106aba7161e17015969634afc3730`. The owning lockfiles identify the
eventually consumed builds. Public APIs are present in this inspected cohort;
no generic producer extension is required by the initial-proposal join.
The contracts and runtime inputs above replace the archive comparison's
synthetic example registry. No example digest, physical identity or qualification
is copied into production. The independent draft comparison, initial-proposal
correspondence and later durable effect evidence retain their distinct scopes.
