# WOH.07 — Proof obligations, admission and model fidelity

Version: 0.2.15. Status: accepted target. This contract does not claim a completed verifier.

## What the present library proves

The inspected `ExMaude.IoT.detect_conflicts/2` evaluates four checks in its bundled equational model. An empty list means those checks did not match, not that every home invariant holds. `verify_safety/3` returns a reachable bad-state solution or `:unverified`; bounded absence is not a positive safety proof. `verify_liveness/3` searches for terminal states missing a goal and explicitly does not prove freedom from livelock.

The inspected `IOT-EXEC` theory also has material differences from the target Home language: absent predicates fall through to false, negation is two-valued, `invoke` has no modeled effect, and the firing rule does not arbitrate on rule priority. Pairwise cascade detection is not a proof of a reachable infinite loop. These are scope limits of that model, not evidence that the Home runtime may drop unknown-state, authority or timing semantics.

Baseline source: [IoT API](https://github.com/futhr/ex_maude/blob/ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb/lib/ex_maude/iot.ex) and [execution theory](https://github.com/futhr/ex_maude/blob/ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb/priv/maude/iot-rules.maude).

The pinned ex_maude Git commit `dc41e3331c025ce77ddcaf87883425c997d69af8` includes isolated IoT receipt runs and a generic isolated bounded-search API with explicit completion, depth truncation and worker-loss outcomes. The latter accepts exact caller-supplied model bytes and is not a complete Home positive model or proof. Home's integration compiles its source-bound IR into an explicitly negative, unconditional explicit-request Boolean state-conflict projection. A real finding rejects a draft; an empty completed result remains inconclusive. Edge triggers and conditional predicates are unsupported. Source revision, explicit-event identity, timing, ownership, causal budgets, current authority, runtime gates, effect-domain arbitration and dispatch uncertainty are named model omissions, not checked properties. Complete source/IR commitments identify the original semantics even when the negative projection is unchanged. Its [source provenance](../provenance/ex-maude-source.md) pins the dependency for this tree; portable builds still require native dependency and clean-machine qualification.

The translation also revalidates rule structs before compilation. An invalid forged struct returns `invalid_rule_set`; a valid Home rule outside the narrow model returns `unsupported_model_semantics`.

The Home candidate-review result now records rule and Thing-registry digests, a review profile and any negative checker receipt. A counterexample may reject; a completed bounded run with no finding only yields `pending_positive_basis` or `pending_composed_proof`. The local API returns only the decision, reason, profile, digests and store watermark, after a second credential/revision check. The internal checker receipt is not exposed or persisted by that route. These digests identify the screened inputs, not a proof or activation authority.

## Result vocabulary

**H07-01.** Keep four axes separate: input validity, findings, execution completion and admission decision. A finding is a conflict, reachability witness, deadlock witness or qualified cycle witness. Completion distinguishes completed bounded search, truncated output, timeout, unavailable backend, unsupported model and an error. Admission is Home's decision, never an alias for `{:ok, ...}`.

No public adapter invents `:safe` from the existing `:unverified` return. A legacy result that merges timeout and bounded absence is recorded as `legacy_unverified`; a caller cannot manufacture a more precise reason after the fact. A digest receipt is attribution, not a proof.

## Two explicit admission profiles

**H07-02 — Restricted rules.** A small rule language can be admitted through separately specified structural arguments: finite inputs, no rule-to-rule feedback, one arbitrated writer per effect, bounded timers, bounded retries and mandatory runtime invariants. The receipt names those exact obligations and their evidence. It does not claim Maude established temporal safety. The positive proof and compiler tests for this profile are implementation work, not a blanket exception called 'low risk'.

No restricted rule becomes active until its closed grammar, structural argument, compiler/runtime correspondence and guard mutation tests have executable receipts. A negative checker finding can reject a draft. A bounded search with no finding cannot fill any missing positive obligation.

The first positive component is an executable `explicit-boolean-light-v3` proposal basis. It accepts one closed, ordinary Boolean Light-power rule with an explicit trigger, literal-true predicate, zero cooldown and causal budget one. It rejects other triggers, predicates, effects, extra writers and forged declarations; it compares the actual IR-driven sandbox with a separate one-effect reference over its finite input cases and repeated-root bound. It also compares the pure safety/override gate and sandbox together across safety decisions, lease lifetime and authority epoch, request matching and desired-value no-ops; a blocked root must remain usable after expiry. The closed digest-bearing receipt binds exact rule and Thing bytes, compiler profile, canonical source and complete IR identities, plus every compiled module in the packaged Home application manifest retained from v2. Its `proposal_generation_only` scope does not prove device state, the provenance of current safety decisions or leases, durable activation or physical effect. Candidate review remains pending and no rule becomes active on this result alone. Older basis versions are not current qualification and their historical digest commitments are not rewritten.

Current-basis checking repeats the actual correspondence checks and compares the complete receipt; closed shape alone is not current qualification. One internal artifact reader serves both this Home-only scope and the separate Home/UDP LIFX scope. It preserves caller-specific digest domains and checks retained BEAM files against loaded module code, refusing retained old code. OTP's [BEAM code checksum](https://www.erlang.org/doc/apps/stdlib/beam_lib.html#md5/1) is used only for consistency; full retained artifacts are still SHA-256 bound. The inventory is not native-library attestation, a hostile-host defence or a live-upgrade barrier. Unknown application metadata and a changed runtime fail closed instead of falling back to the old smaller scope.

The candidate-review service can now include this receipt after its negative screen and current credential/revision check. It serializes only the scoped basis fields, not executable rule authority or a Maude witness. A rejected conflict cannot gain a basis from this path, and verifier loss still cannot turn a pending review into admission.

**H07-03 — Composed rules.** Feedback, multiple interacting writers, safety-sensitive compositions or temporal claims require a supported semantic model and sufficient evidence for the declared property. The existing bounded API is useful for finding counterexamples but does not supply a general positive-admission path. Until an exhaustive finite-state or other justified proof profile exists, candidates requiring it remain inactive. Do not quietly reduce the requirement to 'no counterexample within depth 50'.

## Compilation and state-space scope

**H07-04.** Home owns a closed intermediate representation and its model compiler. Compile the same precedence, three-valued facts, causal bounds, timer behavior, command uncertainty and capability restrictions used by the runtime. Unsupported constructs are rejected. `invoke` requires declared effects and failure/unknown outcomes; it is never accepted as a no-op for convenience.

The current Home compiler implements a closed source-bound IR for the supported grammar. The sandbox and negative model projection consume the same compiled entries. Executable correspondence covers complete three-valued truth tables, exact typed/threshold comparisons, reported-edge versus synthetic-ACK origins, malformed/forged programs, 1,620 finite state cases and a sequential mixed-event trace preserving accepted cooldown/root history. The reference uses independent AST evaluation and independently computed state transitions, not the IR machine. This supplies current grammar/compiler correspondence evidence, not a faithful composed temporal model, current invariant provenance or an admission/activation receipt.

A model enumerates allowed environmental changes, stale/missing observations and failed device effects. It records variable domains, numeric abstraction, clock abstraction, fairness assumptions and queue bounds. Restricting environmental transitions merely to make a proof pass is prohibited. Abstract counterexamples are checked against the concrete model; a spurious abstraction witness is not presented as a physical incident.

**H07-05.** Receipts bind exact source rules, IR/compiler, model closure, invariants, assumptions, capability/profile revisions, checker/binary and effective budgets. Deterministic semantic identity is separate from timestamps and performance measurements. Cache reuse requires the full identity to match. Revoked profiles, changed model dependencies and expired assumptions invalidate the relevant admission.

## Isolation and execution

**H07-06.** Use a bounded caller-owned Port pool with preloaded, digest-addressed trusted models. Do not accept arbitrary Maude source, include paths or shell arguments from natural language, a device or a remote tool. Loading new models into a shared mutable pool is not treated as an atomic switch. A timed-out or uncertain worker is retired before reuse.

A qualification deadline covers queueing, model admission, native execution, parsing and receipt creation. Verification cannot starve protocol observation or additive safety response. Native memory/process limits are host-profile requirements; a BEAM timeout alone is not a memory sandbox.

The local draft-review socket permits at most two simultaneous checker calls and immediately returns `review_capacity` when both are occupied. The socket supervisor monitors each reviewing worker, releasing its slot when the worker exits, including a crash. This bounds concurrent Home review calls, but it is not a memory limit for the Maude process or a complete qualification deadline.

## Runtime guards and availability

**H07-07.** Guard every dispatch against current safety facts, authority epoch, permissions and supported capabilities. No per-click model search is required for ordinary manual control. Verifier loss blocks new proof-required admission and transitions needing fresh proof; it does not invalidate all still-applicable admitted rules. Autonomous alarms never wait for Maude.

## Evidence gates

H07-T1: unsupported priority/unknown/invoke/timer semantics fail compilation rather than disappear. H07-T2: the legacy API's inconclusive result can never authorize a proof-required candidate. H07-T3: model/compiler changes invalidate cached receipts. H07-T4: planner and model replay agree on generated finite traces. H07-T5: mutation tests kill omitted safety guards and precedence inversions. H07-T6: a lasso or repeated state is labelled a cycle only under the checked fairness/environment assumptions. H07-T7: timeout, pool replacement and model-load races cannot reuse stale evidence. H07-T8: a rejected draft results in zero physical calls.

## Scoped executable admission argument

`home-explicit-light-admission-v1` now packages and independently rechecks the `explicit-boolean-light-v3` finite correspondence basis with a closed mandatory guard list, exact declaration/resource pins and invariant-policy identity. Its runtime scope is one unconditional explicit Boolean ordinary-Light effect, ownership 1 ms, zero cooldown and one causal effect. Durable invocation uses the compiled source-bound effect; queue/claim/handoff recheck the complete current artifact and Store-owned invariant/lease inputs. Integration cases exercise grant revocation, policy replacement, overrides at every boundary, generation changes, immutable retries, crash/restart, corrupt origins and encrypted recovery.

This is a positive argument for the explicitly bounded software subset permitted by H07, separate from ex_maude's negative checker. It supplies no native/OS or physical evidence, scheduler semantics, composed reachability result, arbitrary ownership timing or feedback lineage proof. Broader source grammar can still be reviewed as a draft without becoming executable.
