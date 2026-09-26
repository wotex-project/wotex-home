# WOH.07 — Proof obligations, admission and model fidelity

Version: 0.2.0. Status: accepted target. This contract does not claim a completed verifier.

## What the present library proves

The inspected `ExMaude.IoT.detect_conflicts/2` evaluates four checks in its bundled equational model. An empty list means those checks did not match, not that every home invariant holds. `verify_safety/3` returns a reachable bad-state solution or `:unverified`; bounded absence is not a positive safety proof. `verify_liveness/3` searches for terminal states missing a goal and explicitly does not prove freedom from livelock.

The inspected `IOT-EXEC` theory also has material differences from the target Home language: absent predicates fall through to false, negation is two-valued, `invoke` has no modeled effect, and the firing rule does not arbitrate on rule priority. Pairwise cascade detection is not a proof of a reachable infinite loop. These are scope limits of that model, not evidence that the Home runtime may drop unknown-state, authority or timing semantics.

Baseline source: [IoT API](https://github.com/futhr/ex_maude/blob/ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb/lib/ex_maude/iot.ex) and [execution theory](https://github.com/futhr/ex_maude/blob/ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb/priv/maude/iot-rules.maude).

## Result vocabulary

**H07-01.** Keep four axes separate: input validity, findings, execution completion and admission decision. A finding is a conflict, reachability witness, deadlock witness or qualified cycle witness. Completion distinguishes completed bounded search, truncated output, timeout, unavailable backend, unsupported model and an error. Admission is Home's decision, never an alias for `{:ok, ...}`.

No public adapter invents `:safe` from the existing `:unverified` return. A legacy result that merges timeout and bounded absence is recorded as `legacy_unverified`; a caller cannot manufacture a more precise reason after the fact. A digest receipt is attribution, not a proof.

## Two explicit admission profiles

**H07-02 — Restricted rules.** A small rule language can be admitted through separately specified structural arguments: finite inputs, no rule-to-rule feedback, one arbitrated writer per effect, bounded timers, bounded retries and mandatory runtime invariants. The receipt names those exact obligations and their evidence. It does not claim Maude established temporal safety. The positive proof and compiler tests for this profile are implementation work, not a blanket exception called 'low risk'.

**H07-03 — Composed rules.** Feedback, multiple interacting writers, safety-sensitive compositions or temporal claims require a supported semantic model and sufficient evidence for the declared property. The existing bounded API is useful for finding counterexamples but does not supply a general positive-admission path. Until an exhaustive finite-state or other justified proof profile exists, candidates requiring it remain inactive. Do not quietly reduce the requirement to 'no counterexample within depth 50'.

## Compilation and state-space scope

**H07-04.** Home owns a closed intermediate representation and its model compiler. Compile the same precedence, three-valued facts, causal bounds, timer behavior, command uncertainty and capability restrictions used by the runtime. Unsupported constructs are rejected. `invoke` requires declared effects and failure/unknown outcomes; it is never accepted as a no-op for convenience.

A model enumerates allowed environmental changes, stale/missing observations and failed device effects. It records variable domains, numeric abstraction, clock abstraction, fairness assumptions and queue bounds. Restricting environmental transitions merely to make a proof pass is prohibited. Abstract counterexamples are checked against the concrete model; a spurious abstraction witness is not presented as a physical incident.

**H07-05.** Receipts bind exact source rules, IR/compiler, model closure, invariants, assumptions, capability/profile revisions, checker/binary and effective budgets. Deterministic semantic identity is separate from timestamps and performance measurements. Cache reuse requires the full identity to match. Revoked profiles, changed model dependencies and expired assumptions invalidate the relevant admission.

## Isolation and execution

**H07-06.** Use a bounded caller-owned Port pool with preloaded, digest-addressed trusted models. Do not accept arbitrary Maude source, include paths or shell arguments from natural language, a device or a remote tool. Loading new models into a shared mutable pool is not treated as an atomic switch. A timed-out or uncertain worker is retired before reuse.

A qualification deadline covers queueing, model admission, native execution, parsing and receipt creation. Verification cannot starve protocol observation or additive safety response. Native memory/process limits are host-profile requirements; a BEAM timeout alone is not a memory sandbox.

## Runtime guards and availability

**H07-07.** Guard every dispatch against current safety facts, authority epoch, permissions and supported capabilities. No per-click model search is required for ordinary manual control. Verifier loss blocks new proof-required admission and transitions needing fresh proof; it does not invalidate all still-applicable admitted rules. Autonomous alarms never wait for Maude.

## Evidence gates

H07-T1: unsupported priority/unknown/invoke/timer semantics fail compilation rather than disappear. H07-T2: the legacy API's inconclusive result can never authorize a proof-required candidate. H07-T3: model/compiler changes invalidate cached receipts. H07-T4: planner and model replay agree on generated finite traces. H07-T5: mutation tests kill omitted safety guards and precedence inversions. H07-T6: a lasso or repeated state is labelled a cycle only under the checked fairness/environment assumptions. H07-T7: timeout, pool replacement and model-load races cannot reuse stale evidence. H07-T8: a rejected draft results in zero physical calls.
