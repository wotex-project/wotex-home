# WOH.07 Formal qualification with ex_maude

## Status

Accepted target contract.

Home uses ex_maude as a formal reasoning dependency; it does not embed Maude syntax into device adapters.

The boundary is:

```text
HomeState + RuleSet + ProposedTransition + SafetyInvariant
 -> deterministic encoding
 -> ex_maude
 -> clean/admissible | conflict(counterexample) | unverified(reason)
```

The current ex_maude `ExMaude.IoT.detect_conflicts/2` and `verify_safety/3` are the foundation. A reachable bad state is a counterexample. A bounded search that finds none is not automatically a proof; `:unverified` remains distinct from verified safety.

Home MUST preserve this distinction:
- conflict/counterexample: block governed transition and retain witness;
- unverified/timeout/unavailable: fail closed where policy requires verification;
- clean conflict scan alone: does not prove arbitrary temporal safety;
- formally established result: records model/rules/snapshot/bound/backend revisions.

Direct ordinary user commands need not model-check every light switch. Formal verification is required where configured for rule admission, changed compositions, safety-governed transitions and the Goatmire demonstration.

Maude models semantic home state and rule effects, never LIFX packets, Zigbee frames or HTTP requests.

The Home adapter should be thin enough that ex_maude remains independently useful and contains no dependency on WoTEx/Home.
