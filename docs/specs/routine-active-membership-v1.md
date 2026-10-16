# Durable routine membership v1

Version: 0.1.1. Updated: 2026-10-16. Status: accepted target.
Owner: WOH.20 H20-03/05/06/08; WOH.04 activation; WOH.14 atomic barriers.
Implementation: planned; no schema, activation or dependency change.
Evidence: current-source reconciliation; RAM-T1–T12 are unexecuted obligations.

## Purpose and compatibility decision

One Store-owned membership identifies every selected definition in Home's
composed automation family. Up to 64 independently activated manual, edge or
temporal definitions share that family. Each definition can contain the full
bounded composition in the [profile contract](routine-composed-profile-v1.md);
its trigger does not change its authority or causal budget. An invoked child
source alone occupies no separate active slot.

Home currently has mutually exclusive legacy rule/schedule activation under
one rule_generation. A legacy rule can have several held request originals;
the generic Collection associates one member program with one retained live
run. Those requests have no composed Run journal. Do not invent missing run
history, fold several originals into one run or convert their one-effect roots
to a sixteen-effect root.

Composed activation therefore uses an explicit reviewed transition of the whole
automation family. It fences the legacy selection and pending work, then
publishes newly admitted composed members atomically. Legacy and composed
activation families are not selected simultaneously. This is an explicit
compatibility boundary of the new activation API, not automatic migration or
an inference from seeing an empty legacy pointer. A former one-effect rule or
schedule can be authored/admitted in the new family through its exact successor
source and current proof; it is never imported as authorized by its old receipt.

Ordinary direct controls remain available in both families under their current
permissions and guards. A family transition uses the existing global fence
policy, which also invalidates pending ordinary requests. Its review must show
that impact. New requests after the transition still use their own one-effect
roots. Already uncertain executions remain unresolved whole-Thing exclusions;
switching families cannot clear them or authorize a resend.

This contract owns membership, family transitions and their compatibility
guards. The complete fact/clock/current-author snapshot and arbitration cut
are separately required. A valid membership value establishes no current grant,
input availability, positive proof, clock trust or permission to dispatch.

## Owners and entry conditions

Consume [installed source/mapping identities](routine-composed-mappings-v1.md)
and the immutable composed admission artifact defined by the subsequent
correspondence/admission contract. WRO.02 owns compiled source, paths and
removed-definition continuation. WOH.14/16 own the single transaction, immutable
originals, no-refund accounting and quarantined restore. These joins do not
introduce another writer or give a device worker a Store handle/bearer.

Current source is Home 644eac3f. RuleWriter.activate/6 and ScheduleLifecycle
already fence through rule_generation and preserve original history. They
invalidate pending held/queued/claimed requests and preserve handed-off work
as unknown. ScheduleLifecycle's structural projection permits one current
schedule only when active_rule_admission is zero. This target adds a selected
family guard before new legacy activation; exact original recovery still runs
before that guard. It does not rewrite historical activation receipts.

Before implementation, the journal owner must freeze exact membership operation,
head/history, impact, admission dependency and run/step/root encodings; their
canonical hashes; migration/startup Integrity/Backup joins; and bounded atomic
barrier writes. No migration number is allocated here. The complete snapshot,
[independent clock contract](routine-clock-bases-v1.md), proof and client/host
contracts must also be complete before composed activation. Clock custody is
specified separately from a full current snapshot/time-validity certificate. No partial implementation may
enable activation by treating these entry conditions as defaults.

## Closed logical values and bounds

**RAM-01 — One complete durable membership.** A native membership view is a
plain string-keyed object with exactly these members:

| Member | Required value |
| --- | --- |
| format | wotex-home.routine-membership@1 |
| scope | durable_automation_membership_only |
| authority_epoch | Positive signed-64 current authority epoch |
| family | legacy or composed |
| membership_generation | Nonnegative signed-64 composed membership counter |
| legacy_rule_generation | Actual nonnegative signed-64 legacy rule_generation |
| legacy_rule_admission | Selected structurally linked legacy admission revision, or 0 |
| legacy_schedule_activation | Selected structurally linked legacy schedule activation revision, or 0 |
| members | Complete ordered composed member array |

In legacy family, members is empty and at most one legacy selection is nonzero.
Those legacy fields describe selected heads under the existing historical
joins, not current runtime/proof qualification. They do not revive an obsolete
proof. In composed family, both legacy selection fields are zero and members
has zero through 64 entries. Empty composed membership remains composed;
it does not restore a legacy selection. Never return a partial member list as
this scope. A malformed/broken current-to-history link refuses, not an empty set.

Each selected member has exactly definition_id, source_revision, admission_revision,
program_digest, author_id, activation_principal_id and activation_revision.
Definition/principal IDs use Home's full ASCII
1–128-byte ID grammar. source_revision is the exact canonical positive decimal
string within signed-64 from the source bundle. admission_revision is positive
signed-64; program_digest is the exact `sha256:` plus lowercase hex64 generic
IR digest. Sort by definition_id bytes; reject duplicates by definition_id or
program_digest, including two revisions of one ID. Each field must join the
entire retained current admission and Program, rather than a caller-authored
summary. No caller priority, effect budget, endpoint or mutable next-run value
belongs in a member.

activation_principal_id is the authenticated actor who actually added this
selection, and activation_revision is that committed membership activation's
positive revision. They are Store-derived lineage, not caller choices. Every
live use independently checks this activator and the admitted source author;
one cannot supply the other's grants. An unrelated membership edit by a new
manager does not replace the old member's activating principal or refresh its
authority. Removal and fresh explicit reactivation create a new activation link;
original/no-repeat history remains retained as specified below.

membership_generation advances once for each changed composed membership,
family transition or committed removal barrier. Legacy-only activation still
advances its existing legacy_rule_generation; it does not manufacture a composed
generation. Thus comparison always includes family, authority_epoch, both
generations and both legacy selections, not membership_generation alone.
The same unchanged composed members retain their exact admission/Program IDs
when another member is added or removed. An independent active child revision
occupies its own slot; merely invoking its source does not.

Migration initializes membership_generation to zero and family legacy, with no
composed members. Existing legacy heads, generations, journal rows and request
roots retain their original bytes/meaning. Initialization grants no authority;
legacy runtime guards still decide whether selected historical work is current.
Only a later explicit committed transition may select composed family.

**RAM-02 — Inputs describe the entire requested set.** The new native membership
operation has exactly authority_epoch, operation_id, expected_store_revision,
expected_family, expected_membership_generation, expected_legacy_rule_generation,
action, members and reviewed_impact_sha256. Actor identity comes from Store
authentication and is not an input field. action is enter_composed, replace or
leave_composed. IDs/counters use RAM-01 bounds; expected_store_revision is
nonnegative signed-64. reviewed_impact_sha256 is bare lowercase hex64 of the
actual reviewed impact, under the journal owner's frozen encoding.

enter_composed requires expected_family legacy; replace and leave_composed
require composed. leave_composed requires members empty. Other actions supply
the entire desired sorted member set, including unchanged members, rather than
an add/remove patch. Input members contain exactly the five admission selectors
definition_id, source_revision, admission_revision, program_digest and author_id;
the two activation-lineage fields are not accepted. Store inherits unchanged
selected members' actual lineage and creates it for genuinely added selections.
Missing/extra fields, unknown action, unsorted/duplicate
members, 65 members, floats, malformed native structs or exceeded bounds refuse.
No implicit family transition is inferred from a valid generic Program.

Both the native operation and membership view are bounded to 65536 compact
UTF-8 JSON bytes, depth eight, 4096 nodes, 64 members in any collection and
128 bytes per string. Every nested occurrence counts. All selected member and
header fields fit those bounds at their stated maxima. Bound bytes/structure
before decoding; reject duplicate JSON keys, extra native fields and noncanonical
numeric input without atom creation. Resource excess returns
routine_membership_capacity; malformed shape/value returns
invalid_routine_membership. These bounds do not define the separate detailed
impact document or enlarge a public socket frame; those encodings remain
explicit journal/client entry conditions.

The operation namespace is routine_membership, keyed by the authenticated
principal/authority_epoch/operation_id tuple, separately from rule/schedule
operation namespaces. Known successful exact originals return their immutable
receipt before new CAS, current family, producer, clock or admission checks;
changed input at that key conflicts. Authenticate the current actor/management
permissions before lookup. Producer absence cannot prevent historical original
recovery. New work remains subject to all current checks below.

Metadata-only complete membership reads and this actor's exact original/status
reads require the same four management permissions in RAM-03. They need no
current producer, clock or target grant to return only these membership/receipt
references and counts. Detailed source, target, report or private custody reads
retain their own grant checks. Do not return a grant-filtered member subset
under the complete metadata scope.

Persist at most 1024 membership operation originals in this namespace. Capacity
exhaustion refuses new originals without eviction, reused identities or partial
changes. Exact originals remain readable. Retention/compaction needs a separate
no-repeat successor before it can free this capacity. Integer exhaustion likewise
refuses the whole operation; no wrap, zero sentinel or implicit reset is allowed.

A whole barrier may affect at most 1024 distinct pending request originals
(held, queued, claimed, dispatching or protocol-accepted), 64 unfenced live
composed run heads and their at most 4096 expanded step records. Count a request
once even if linked to multiple contributors; count each contributor's own
step/root history separately. Existing outcome_unknown records remain retained
and excluded from physical reuse; they are not deleted to fit this bound.
The new shared admission/queue capacity owner must enforce these joint bounds
and reserve the journal/revision headroom for a complete later barrier before
publishing new work. Independent per-table limits cannot imply that guarantee.
First entry preflights the actual legacy barrier footprint and refuses unchanged
if it cannot fit; it does not trim a prefix of old work.

Automatic withdrawal has no user-operation original and must not need a free
slot in the 1024-operation namespace. The journal contract must account for its
cause-linked history separately and reserve full withdrawal capacity. User
history exhaustion cannot turn revoked authority into continued eligibility.

## Guards, review and atomic transitions

**RAM-03 — Authenticate the actual management operation.** New operations
require an active authenticated principal with rule:manage, rule:review,
control:ordinary and read permissions; active writable controller; matching
authority epoch/global CAS/family/generations; and no maintenance barrier.
Every proposed member requires a currently valid full composed admission,
current original author and explicit current actor/author grants for its entire
read/write target closure, including unchosen/unused child sources. Neither the
manager nor an equivalent member supplies another author's permission. Root,
input and output proof/custody/runtime checks remain separate entry obligations.
Unchanged members additionally require their retained activating principal's
current scope; a new manager cannot launder its withdrawal through a full-set edit.

Removal/fencing cannot require the removed author's continuing permission or
a missing target's grant. A management actor may withdraw unsafe work under
their management scope; that never grants control over the withdrawn target.
Trusted committed revocation/maintenance/transfer barriers do not authenticate
as a user or require an actor whose authority has just been removed.

The review binds the exact old family/generations/members, entire proposed set,
legacy selection and all affected original identities/phases. Report counts
separately for affected requests, runs/steps and possible handed-off outcomes.
Include ordinary held/queued/claimed requests in a family transition's global
fence impact. No raw hardware identity, private route, credential, grant secret
or capture appears in review output. Changed phases, added pending work or
different impact after review require fresh review; the Store cannot silently
substitute a broader barrier. Review does not reserve a membership, root or lock.

**RAM-04 — Enter composed family.** Within one Store transaction:

1. Validate existing legacy histories and the complete proposed admissions,
   review impact, counters and shared capacities. Identify every pending
   request/run/step before mutating anything; never use a batch prefix.
2. Execute one actual empty legacy rule-generation fence. It clears the selected
   legacy rule and makes the old schedule activation ineligible under its old
   generation. Preserve both original histories. Increment legacy_rule_generation
   exactly once, with its existing authority-journal link.
3. Reject unsent held/queued/claimed work under the fence; retain spend.
   Handed-off/protocol-accepted work becomes or remains outcome_unknown with
   original markers and domain exclusions. Existing unknowns remain unchanged.
4. Publish family composed, the complete new member set and one incremented
   membership_generation with exact old/new/event/operation links. Create no
   run, trigger original, receipt queue item or new effect reservation here.
5. Repeat the full relevant authority/admission/runtime/counter and impact
   checks at the final unscoped Store publication guard. Commit all rows and
   receipt together, or roll back the whole transition.

The final repeat reconstructs the expected post-state including only the exact
authorized tentative mutations, and freshly checks the remaining mutable/private
basis. It must not compare against the old head and then ignore the mismatch,
nor reuse a cached opening authorization after writing the new head. Membership
transactions perform no Kernel transition calculation or transport I/O; Home's
durable fences apply without manufacturing generic Run changes.

This intentionally uses the existing global invalidation policy. Ordinary
requests are not silently exempted or assigned new roots. The later new ordinary
request path remains usable. Family entry never activates a copied old proof or
recovers cancelled work merely because the new definition expresses the same
Boolean value or recurrence.

**RAM-05 — Replace composed members.** Validate the complete proposed set,
every current admission/author/target scope and the prospective full capacity.
Publish a single new membership_generation. Unchanged exact member tuples keep
their activation lineage, current runs, roots, edge histories and trigger
watermarks, subject to
fresh snapshot/current guards. Removed/revised members lose all future unsent
progress; old started/uncertain effects retain their original history/exclusions.
A new member/revision gets no imported edge baseline, considered-due watermark,
live run or old original namespace merely because its ID resembles a predecessor.
Overlap remains at most one nonterminal run per immutable revision.

Readding an exact previously selected revision still consults that revision's
retained original index and no-repeat temporal watermarks. Never reset its
history to make cancelled/considered work new. Reactivation establishes a fresh
edge baseline and the temporal owner's current skip-only activation boundary;
it cannot rewind a watermark or catch up a past due range. A fresh revision's
initial temporal boundary likewise excludes unauthorized catch-up. Neither a
reset baseline nor a new family generation turns an old report into a new edge.

No ordinary request is cancelled merely for a composed-only membership change.
Do not increment legacy_rule_generation as a convenience here: existing direct
request queue/claim/handoff checks bind that separate generation. Affect only
the composed originals/dependencies actually removed or invalidated, plus any
separately justified current authority barrier. The complete subsequent cut must
include new membership before it can reserve further effects.

When the requested set is already exactly current, retain a no_change operation
receipt without advancing membership_generation, generating a trigger or fencing
requests. Its operation/journal retention may advance the Store revision; its
receipt must not claim a membership change. Exact retry returns that original.
Missing current admission/proof is still a refusal for a new no_change operation;
only original recovery bypasses fresh eligibility checks.

**RAM-06 — Leave composed family.** Explicitly review and fence all composed
members/runs and all pending requests using the global fence impact, preserving
started uncertainty/spend as at entry. Advance both the legacy empty-rule fence
generation and membership_generation exactly once, then publish legacy family
with empty members and no selected legacy rule/schedule. Do not restore the
pre-entry selection. A later legacy activation must pass its ordinary current
admission/runtime/author/target checks under a fresh operation.

New legacy activation/deactivation/schedule lifecycle changes while composed
family is selected refuse automation_family_conflict, including an attempted
empty legacy activation. Perform that check after exact original lookup but
before tentative mutation. Inert legacy drafting/admission and historical reads
retain their own current contracts. A raw message cannot bypass the family
guard by avoiding Authority. Claim/handoff also repeat selected-origin/family
guards, so a pre-entry prepared proposal cannot become eligible afterward.

## Other barriers, removed originals and recovery

**RAM-07 — Preserve global and scoped withdrawal.** A trusted global rule fence,
maintenance/recovery/transfer barrier or observed unrecoverable runtime loss
must include composed members and their originals in the same transaction.
Clear the member set and increment membership_generation when it changes.
An empty composed set retains composed family unless the explicit reviewed
leave operation is committed. Legacy-only empty-rule helpers cannot leave a
hidden active composed set behind. Neither old API names nor an empty legacy
pointer prove that the whole automation set was fenced.

A scoped committed principal/grant/declaration/profile/input loss removes every
dependent composed member using the complete retained dependency closure and
advances membership_generation once for that cause. Retire unsent dependent
progress and preserve every charge/started outcome atomically with the cause.
Dependencies include the admitted source author and retained activating principal
as distinct roles, as well as the selected input/profile authors and targets.
Independent members/ordinary requests retain their current scope unless the
cause's existing global policy requires otherwise. A missing current Fact alone
is unknown data, not a definition retirement; UTC loss alone cannot retire an
elapsed-only definition. The qualified clock/snapshot owners define those
transient versus permanent losses explicitly.

Removal must commit a Home-owned execution fence without depending on a live
producer, clock or private source. The journal contract must encode that fence,
its cause, affected originals and retained spend independently of generic Run
decoding. Preserve the old generic bytes; do not fabricate a terminal Run,
receipt, satisfied state or handoff to represent the Home fence. A previously
stored generic running status cannot override this durable exclusion.

When generic reconciliation is available, calculate outside the writer through
WRO.02's direct Kernel seam with the actual stored Program/original and a
snapshot excluding it from active_programs, then commit only against current
original/fence revisions. Collection contains only current selected members.
Later qualified receipts
may refine removed original history but cannot start a root, revive membership,
advance a dependent step or cause resend. Receipt and original lookup must still
find removed/retired members. Terminal history and unresolved domain claims
are not counted as active definitions or silently discarded as nonmembers.

**RAM-08 — Make failures atomic and retries original-first.** Policy/CAS/review/
proof/capacity refusal publishes no new member selection, counter increment,
fence, operation success or reservation. SQL/journal/history corruption remains
a whole-transaction error with the existing Store health/write fence; it is
never relabeled an empty set, capacity denial or successful withdrawal. Inject
failure after legacy fence, each affected request/run write, new head and
receipt publication. Every failing prefix must leave the exact original state.

Logical lost-reply retry uses the original principal/epoch/operation and exact
body; it returns one committed receipt even after a later family switch.
Repeated scheduling/polling sees the committed selected family/generations,
not an uncommitted head. Closing the initiating client stops no valid selected
automation. Worker I/O is allowed only after its separate durable current
handoff guard/marker, never during a membership transaction.

Same-owner restart validates exact head/history/admission/dependency joins and
retains the selected family. It creates no trigger, edge, new original, grant
or clock continuity. Boot-local continuation expiry and current proof/runtime
withdrawal remain mandatory. Restored archives stay quarantined with no active
membership or authority; transfer never selects copied members automatically.
Historical family/operation/admission/run identities remain inspectable under
the owning recovery contract. A prior binary without the new schema/guards may
not open the migrated Store writable; rollback needs its owning qualified
recovery path, never removal of the family field to make an old binary start.

## Outputs, refusals and acceptance

Successful change receipts must retain the scoped original, action, old/new
families and generations, exact input/impact/new-head hashes, changed or
no_change disposition, barrier/final revisions and separate affected/unknown
counts. Exact canonical wire and Integrity/Backup joins belong to the journal
entry condition; an implementation cannot choose them ad hoc. The complete
membership view is durable_automation_membership_only, never the later
complete-current-facts/arbitration certificate.

New failures are payload-free errors: invalid_routine_membership,
routine_membership_conflict (changed input at a known original),
automation_family_conflict, routine_membership_basis_changed (CAS/generation/
review drift), routine_membership_capacity and routine_membership_unavailable.
Authentication, maintenance, unsupported/stale composed admission and damaged
history retain their owning typed outcomes. Bound and structurally validate the
input, then check actor/known original first, followed by healthy writable/
maintenance/epoch/CAS/family/generations, complete set and
admission/scope, capacity, impact and final repeat. No partial success is returned.

Normal trace: select two newly admitted manual/edge members, review the old
legacy rule and ordinary held request affected by entry, commit one global
fence plus the whole new set, then calculate a separate complete cut. Both old
roots retain their original budgets and history; no new run starts at entry.
Adverse trace: a worker commits handoff after review but before entry. The new
impact differs, so the operation refuses unchanged. After fresh review, a new
entry marks that old original unknown and retains its busy domain; it cannot
retry the physical command under a composed root.

| Case | Requirements | Setup and expected observation / falsifier | Evidence level |
| --- | --- | --- | --- |
| RAM-T1 | 01–02 | Historical legacy rule and schedule fixtures initialize without changed rows/authority. Exact closed empty/64-member views validate; 65, duplicate revision/ID/digest, malformed counter and broken head joins refuse | Actual migration/SQLite |
| RAM-T2 | 02–04 | Real enter operation binds complete old/new admissions and review, fences pending ordinary/automation work once, advances both counters once and creates no run or effect reservation | Actual Authority/SQLite |
| RAM-T3 | 02, 06 | New legacy activate/deactivate/schedule/empty activation and raw routes refuse in composed family; exact pre-entry originals still return original receipts without changing family or heads | Actual API/Store |
| RAM-T4 | 03–05 | Replace one member among 64; unchanged activator/run/edge/watermark identities survive, removed work loses unsent progress, ordinary queued work retains legacy generation and unrelated state | Actual SQLite/kernel join |
| RAM-T5 | 02, 05, 08 | Same set under a new operation retains no_change once; lost reply, concurrent exact duplicate and later family switch return the original receipt without another fence/trigger | Actual concurrent Store |
| RAM-T6 | 03–05, 08 | Race actor/author/retained activator/input/output grant, admission/runtime, counters, new pending request and claim/handoff phase after review; no stale commit or broadened unreviewed impact. A new manager cannot reauthorize unchanged members by borrowing its own grants | Actual Store/controlled worker |
| RAM-T7 | 04–08 | Inject SQL publication failure after each barrier/head/receipt/run/request boundary; full rows, revisions, spend and exclusions match pre-operation snapshot | Actual faulted SQLite |
| RAM-T8 | 06–07 | Leave and trusted global/maintenance/transfer fences include all members/roots, preserve unknowns, never restore old heads; an empty composed set cannot auto-reenter legacy | Actual Store/recovery |
| RAM-T9 | 03, 07 | Committed scoped author/grant/profile/input loss removes all dependencies including unused child selectors in the cause's transaction; unrelated members remain. Returning files/grants cannot auto-select the old member | Actual Store/custody fault |
| RAM-T10 | 07–08 | Removed original receives exact duplicate and later qualified receipt; retain history/spend without new child/trigger/send. Handed-off/unknown legacy domains remain busy through entry/leave/restart | Actual Store/kernel/transport |
| RAM-T11 | 01–02, 08 | Capacity at 1024 originals, integer exhaustion and complete barrier work over its shared bound refuse unchanged; originals recover without producer/current clock; no prefix deletion frees authority | Actual SQLite/boundary |
| RAM-T12 | 01, 07–08 | Restart, backup damage, quarantined restore, ownership transfer and older-binary writable open verify exact history/dependency joins and inactive copied work; no manufactured current authority | Actual retained cohorts/recovery |

These remain planned, contributing to H20-T2/T4/T5/T6/T8/T9. The next owning
journal/snapshot/proof contracts and their independent normal/adverse vectors
must be reviewed before code. Record actual sources, locks, schemas, fixtures,
commands/results and retained artifacts when executed. Software rollback and
restart do not establish power-loss, installed clock or physical qualification.

## Sources and decisions

Inspected Home 644eac3f: Durable.Store.RuleWriter, ScheduleLifecycle,
ExecutionWriter.fence_rule_generation_tx/3, RequestInvalidator, CausalLedger,
Rules.KernelProposal and the provided-set arbitration contract. Inspected
WoTEx 973fb32c WRO.02 removed-definition/Collection contracts. The family
transition preserves the existing broad fence and immutable legacy originals
while giving the new bounded model one exact membership. It deliberately
requires reviewed successor admission rather than silently manufacturing
composed history for the legacy multi-original path.
