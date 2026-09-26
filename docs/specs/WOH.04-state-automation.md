# WOH.04 — Automation admission and runtime prevention

Version: 0.2.7. Status: accepted target.

## Rule language

**H04-01.** Rules are closed, versioned data, not user-supplied Elixir, scripts or Maude programs. A rule names stable IDs for its inputs and effect targets, trigger kind, predicates, desired effects, authority class, ownership duration, timing constraints, causal budget and source revision. Limits are checked before compilation. Unknown fields and unsupported operators are rejected. No atom is created from a device or user string.

Triggers distinguish a rising/falling edge, a sampled level, a deadline and an explicit request. A level remaining true does not create a new event on every reconciliation pass. Predicates use true/false/unknown with an explicit missing/stale policy. Negating unknown remains unknown. Thresholds use declared units and numeric representations; neither model compilation nor execution silently rounds across a threshold.

The first executable draft subset accepts explicit requests and rising/falling edges; equality, exact integer greater-than thresholds, negation, conjunction and disjunction; one absolute effect; and an `unknown_policy` of `block`. The parser bounds nesting, node count, ownership, cooldown and causal budget. Sampled levels, deadlines, hysteresis and broader effect forms stay unsupported until their scheduler and proof semantics are defined. The restricted structural analyzer accepts only ordinary-risk readable inputs and writable effects, one writer per whole-Thing effect domain, and no effect-to-input feedback. Its result is a screening result, never an admission or positive proof.

Analyzer, draft sandbox and verifier translation now revalidate the complete rule/predicate shape when handed an Elixir struct. A forged struct cannot bypass the closed parser's identifier, depth, comparison or budget limits. Direct structural analysis also revalidates each referenced Thing declaration before accepting its read or write operations. The sandbox rechecks trigger-event and state shapes before evaluation. These checks do not create an admitted runtime.

## Ownership and precedence

**H04-02.** Each effect domain has one arbiter. A domain includes coupled attributes, such as a light's power, colour and level, rather than assuming concurrent writes to separate properties are harmless. Non-overridable safety constraints filter all proposals first. Among permitted proposals, explicit operator override leases take precedence over convenience automation. Equal-authority incompatible proposals produce a conflict; arrival order is not the tie-breaker. Stable ordering is allowed only for equivalent effects or a documented policy.

A rule changing Home mode cannot implicitly acquire higher authority. A manual override has an explicit expiry and restart behavior. Observing an external change does not prove an authenticated human requested it: the profile decides whether to suspend reconciliation, report a conflict or ask the operator. Home must not fight another controller indefinitely.

## Candidate lifecycle

**H04-03.** The lifecycle is `draft -> validated -> analysed -> qualified -> admitted -> active -> retired`. Rejected and inconclusive revisions are immutable outcomes. Edits create successors. Candidate evaluation has no transport credentials, actuator handles, active scheduler registration or production event subscription with mutation authority.

The candidate review combines structural screening and the narrow negative Maude check into a digest-bound result. It reports `rejected`, `pending_positive_basis` or `pending_composed_proof`; no result is `admitted` or `active`. A known Boolean state conflict rejects even if the multi-writer rule set would otherwise need composed proof. A no-finding result and unsupported model semantics remain pending. The local API authenticates a `rule:review` principal, binds its granted active Thing declarations and rechecks the store revision and credential after screening. Reviews are ephemeral; persistence, positive proof and activation are still open.

Admission validates schema, capabilities, dependency closure, writer conflicts, bounds and required proof obligations. A dependency graph detects potential cycles; an acyclic graph alone does not prove temporal or physical safety. Cyclic automations are rejected unless a supported qualification profile establishes the relevant termination/boundedness property. A reviewer cannot relabel an inconclusive search as a proof.

**H04-04.** The admitted artifact binds the rule bytes, compiler, semantic model, policy, invariants, capability/profile revisions and proof receipts. It states whether the proof covers a current snapshot or an explicitly bounded environment. A state-specific check is not a license for arbitrary future inputs. Unsupported semantics are blockers, not omitted model fields.

## Activation without a race

**H04-05.** Activation uses an expected current revision and authority epoch. The dispatcher pauses admission of old-revision work, reaches a bounded barrier, and reports operations already handed to a device as in-flight/unknown. One transaction advances the active pointer and a separate active-rule generation and cancels undispatched old intents. Activation does not change the controller authority epoch, which identifies fenced ownership under WOH.15. Workers re-check active-rule generation, authority epoch, resource revision, current capabilities and guards immediately before handing off bytes.

The barrier cannot recall an old UDP packet or Zigbee command. The activation result must disclose outstanding effects and reconcile their observations; it must not claim atomic change across physical devices. A stale qualification snapshot causes rejection or requalification. Rollback is a newly checked activation of prior rule content, not replay of old commands or unconditional restoration of old database files.

## Runtime prevention

**H04-06.** Runtime guards remain mandatory after formal admission. Enforce per-effect serialization, debounce, hysteresis, minimum on/off dwell, bounded cooldown, causal depth, per-root effect count, per-device rate and finite retry budgets. Defaults are profile data and must have boundary tests. A no-op desired state does not emit another command. Synthetic acknowledgements cannot create fresh physical trigger facts.

Carry a causal root through rule-generated events. When a protocol cannot return that lineage, compare the bounded expected-effect ledger and observed values; do not invent correlation. Repeated reversals trip a circuit breaker for the offending automation/effect domain. A safety response has a separately budgeted route and cannot be starved by convenience traffic, but it is still bounded.

The first credential-free draft sandbox evaluates explicit requests and reported Boolean edges against three-valued facts. Synthetic acknowledgements cannot fire reported edges. It suppresses unknown predicates, repeated desired values, cooldown hits and exhausted causal roots; conflicting whole-Thing proposals yield no winner, and equivalent effects coalesce deterministically. When one event proposes more effects than the smallest applicable root budget allows, it suppresses the entire batch. It has no scheduler, persisted active pointer, override arbiter, device ledger or driver credential and cannot be used as the admitted runtime.

## Failure policy

Verifier failure blocks new proof-required admission, not valid existing operation. Device loss makes observations stale/unknown; it does not assert a safe physical state. A full or unhealthy durable store refuses new ordinary durable mutations. An explicitly pre-admitted, bounded best-effort safety response may run in a declared degraded mode without inventing a durable receipt. Smoke detection and acoustic warning do not depend on this route.

## Required evidence

H04-T1: a conflicting draft produces zero driver calls and leaves the active digest unchanged. H04-T2: race activation with queued and in-flight commands; stale undispatched work never sends. H04-T3: cyclic/no-op/restoration rules cannot exceed the causal budget. H04-T4: manual override, expiry, restart and external-controller interference. H04-T5: unknown and stale sensor values never become false through negation. H04-T6: verifier loss preserves only rules whose admission assumptions still hold. H04-T7: smoke-priority events remain responsive under ordinary queue saturation. Property tests compare planner and execution semantics.
