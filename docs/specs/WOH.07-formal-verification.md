# WOH.07 Formal qualification with ex_maude

## Status

Accepted target contract.

## Purpose

ex_maude is a preventive qualification mechanism for automation composition, not the controller of the house.

Home converts deterministic semantic rules/state into the consumer-neutral ex_maude IoT contract.

## Primary boundary: admission

    Draft RuleSet + modeled effects + SafetyInvariants
      -> deterministic encoding
      -> conflict analysis / bounded safety verification
      -> qualification evidence
      -> ADMIT or REJECT

A rejected candidate never becomes active and therefore never reaches physical devices.

The current ExMaude.IoT.detect_conflicts/2 and verify_safety/3 are the foundation. Home preserves their evidence semantics:
- reachable bad state/counterexample -> reject and retain witness;
- policy-prohibited conflict -> reject;
- unverified/timeout/unavailable -> reject when qualification policy requires verification;
- bounded absence of a counterexample is not mislabeled as an unbounded proof.

The active revision records the rule/model/invariant and verification evidence used for admission.

## Runtime defense in depth

Selected safety-sensitive transitions MAY receive an additional state-specific guard/verification before execution. This is defense in depth, not a substitute for admission.

Ordinary direct light switching does not require a Maude search merely because ex_maude is installed.

If ex_maude becomes unavailable, already-admitted ordinary automation may continue under deterministic runtime guards when its policy permits it; new/changed rules requiring qualification cannot be admitted.

Maude models semantic state/rule effects/invariants, never protocol packets. ex_maude remains independent of WoTEx/Home.
