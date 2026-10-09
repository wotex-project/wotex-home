# Complete-set whole-Thing arbitration v1

Version: 0.1.0. Implemented pure proposal dependency, 2026-10-09. WOH.04 owns
arbitration; WOH.07 owns subsequent admission correspondence; WOH.14 owns
causal reservation and durable effects.

The shared `Rules.Arbitration` resolves a complete set of zero through 64
equal-authority automation proposals before a batch cutoff. The existing
credential-free rule sandbox consumes this boundary while preserving its
proposal, conflict, suppression, cooldown and causal-budget results. The
[autonomous scheduler](local-scheduler-v1.md) will need it before composing
multiple active schedules. Current durable temporal guards still refuse that
active set; this component creates no admission or execution authority.

## Closed proposal data

One proposal is an exact seven-field internal map: `rule_id`, `target_id`,
`capability_key`, `value`, `root_id`, `depth` and `ownership_ms`. The four IDs
use the existing bounded Home ID grammar. Depth is integer 1–32; ownership is
integer 1–86,400,000 ms. Value is an exact valid Home `Value` struct with no
extra members. Duplicate rule/source IDs, unknown or missing fields, invalid
values, improper lists and more than 64 proposals refuse as one set. No atom
is constructed from input. This is an internal proposal shape, not a new
network encoding or public route.

The caller must derive candidates from the complete current admitted set after
the required permission, predicate, safety, override, temporal and no-op checks.
Input completeness is an owning-caller obligation: a list alone cannot prove
that an active conflicting source was omitted. Future Store composition must
bind the full active-set snapshot and repeat it before publication/handoff.
The pure boundary does not authenticate IDs or certify proposed values.

## Domain and representative

Every capability of one Thing shares its effect domain. Equality requires both
the exact capability key and complete typed value. Any incompatible pair in
the domain blocks every member, irrespective of arrival order or batch position.
Conflict output retains the target and all sorted original rule/source IDs.

A compatible domain selects the lexically first rule/source ID as its stable
proposal representative. All original member maps are retained in the group,
including distinct causal roots, depths and ownership intervals. Equivalent
members remain explicitly identified in the suppression result. Metadata is
neither combined into a new root nor borrowed from the representative for the
others. Subsequent durable composition must establish each contributor's actual
author/basis and account for every original receipt and causal reservation.
This component grants no ownership lease.

Groups sort by target ID; representative proposals sort by rule/source ID.
These orders express equivalent-effect representation and independent-domain
capacity policy, never a winner between incompatible same-domain effects.

## Arbitration before capacity

`batch/2` accepts an integer limit of 1–16, default 16. It resolves all input
domains first, then selects at most that many compatible groups in representative
ID order. Remaining compatible groups are returned as capacity-blocked with
their complete original members. The original full arbitration result remains
available. Conflicting groups consume no selected slot and cannot become
eligible by hiding another member after the cutoff.

Capacity-blocked data is no queue or retry grant. The owning scheduler's missed
policy remains skip, with terminal accounting and watermark retention required
before a durable multi-schedule runner exists. Safety-response capacity,
multi-root coalesced receipts, composed admission, complete active-set/current
guard joins and physical timing remain separately owned obligations.

## Provided-set correspondence receipt

`ArbitrationBasis` checks the actual supplied set against a separate all-pairs
reference before issuing a receipt. The exact internal fields are `result`,
`profile`, `scope`, `limit`, `input_digest`, `outcome_digest`, `runtime_digest`,
`obligations` and `basis_digest`. Result is `basis_complete`, profile is
`whole-thing-arbitration-v1`, and scope is `provided_proposal_set_only`.
Limit is integer 1–16. The four digests are SHA-256 commitments; the basis
commitment covers every other receipt field. Obligations name closed bounded
input, whole-Thing conflicts, preserved equivalent originals, arbitration
before cutoff, deterministic independent-domain capacity and no control
authority. Exact ordered obligation membership is mandatory.

Input commitment includes the limit and all original proposal maps sorted by
rule/source ID, including complete typed values and causal/ownership metadata.
Outcome commitment includes the complete arbitration and selected/blocked
groups. Domain-separated deterministic ETF is an internal commitment under
the pinned OTP cohort; this does not introduce a network encoding.
The complete Home runtime is independently inventoried before and after the
comparison. Loaded/file drift or a runtime change refuses. Current reuse
repeats the actual input/reference comparison and both runtime checks; retained
receipt bytes cannot seed a positive result. Syntax validation alone grants
no current correspondence.

The reference validates input independently and builds an all-pairs conflict
relation followed by a representative scan. It imports no production arbiter,
Store writer, transport or credential code. A provided-set receipt cannot prove
that its caller included every active source, cannot bind missing current
authority/fact/clock inputs, and cannot satisfy composed admission by relabeling
its scope. Those owning joins remain required before durable use.

## Evidence

The independent test reference constructs an all-pairs incompatibility relation
and scans representatives, using neither production grouping nor effect
deduplication. All 512 three-source assignments over two Things and four
power/level effects are compared in all six input permutations. Limits 1, 2
and 16 are compared separately: 3,072 resolution and 9,216 batch comparisons.
Additional cases cover empty/64-member sets, full member/root/ownership
preservation, coupled-capability conflicts, a conflicting seventeenth member,
duplicate sources, malformed/forged input and closed bounds. A real sandbox
step verifies the shared boundary sees that late conflict and spends only
the remaining fifteen proposal effects under its existing causal budget.

Executable receipt checks cover empty and complete 64-member inputs, changed
inputs/metadata/batch limits, closed receipt syntax and stale commitments.
Two isolated runtime mutations retain matching loaded/file artifacts after
warming a receipt: truncating to the batch prefix before arbitration and
rewriting every original ownership interval. Both refuse actual provided-set
correspondence rather than qualifying the changed matching runtime.

These checks establish bounded pure correspondence. They do not supply a
composed autonomous-admission receipt, durable multi-root accounting,
installed-clock/minimum-window qualification or physical control.
