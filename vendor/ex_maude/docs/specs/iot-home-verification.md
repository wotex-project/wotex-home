# IoT verification scope and evidence contract

Version: 0.2.0-target. Existing APIs remain unchanged. Additive bundled-model
receipt functions are implemented; positive proof profiles remain a target.

## Current behavior

The baseline is the source at `ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb`, particularly `lib/ex_maude/iot.ex` and `priv/maude/iot-rules.maude`.

| Operation | Supported interpretation | Not established |
| --- | --- | --- |
| `detect_conflicts/2` | Findings from the four selected bundled equational checks | General safety or temporal completeness |
| `verify_safety/3` | Reachable matching bad-state solution, otherwise unverified/error | A positive proof from bounded absence |
| `verify_liveness/3` | Terminal-state deadlock check under the configured bound | Freedom from livelock or general eventual progress |

**EMI-01.** Preserve legacy return shapes. `{:ok, []}` in a conflict scan means no selected check matched. `{:ok, :unverified}` is not safe, accepted or established. A counterexample remains a structured finding rather than generic prose. Input/encoding/module failures remain errors. Callers decide policy; the library never grants actuation permission.

## Model fidelity

**EMI-02.** The bundled execution model has a specific semantics. `holdsFor` treats missing predicates as false and applies ordinary boolean negation. The `fire` rule does not implement priority arbitration. `applyOne(invoke(...))` preserves state. Model actions do not describe network delay, device failure, unknown observations, wall-clock timers or arbitrary consumer effects.

These facts must remain visible to users of the model. A consumer with different semantics must use an explicit compatible translation, reject unsupported constructs, or provide a separate reviewed theory. Do not silently change this model to emulate one application's runtime. A future semantics change requires a new profile/version and regression coverage.

**EMI-03.** Pairwise cascade findings identify potential dependencies; they are not automatically reachable loops or infinite executions. Search solutions contain the evidence actually returned. A terminal-state solution is not a fabricated multi-step trace. Liveness/cycle claims require the appropriate transition semantics, environment/fairness assumptions and witness format.

## Additive receipts

The implemented bundled-model Port receipt API is described in [verification
receipts](verification-receipts.md). It attributes a run to snapshotted inputs,
model closure, execution and bounds without changing the underlying proof
scope. It executes the check directly rather than wrapping a legacy result.
No wrapper may synthesize a more precise completion reason from a legacy
result that has already discarded it.

**EMI-04.** Bounded no-counterexample, timeout, output truncation, queue exhaustion, unavailable backend and unsupported model remain distinct where the executed API can observe them. A compatibility wrapper records `legacy_unverified` when it cannot. Raw API success and consumer admission are different axes.

## Positive evidence

**EMI-05.** An exhaustive finite-state or temporal model-checking profile would need its own contract: state-domain closure, transition completeness, exact model/checker version, completion evidence, fairness assumptions and witness verification. It is not added by calling an existing bounded search with a larger depth or by observing an empty solution list. Until such a profile is implemented and qualified, the library does not advertise that positive result for these APIs.

## Safety and isolation

Consumer-supplied models and raw commands are powerful trusted input. Do not accept arbitrary model text or include paths from devices or natural-language services. A host should isolate pools for incompatible models, use immutable source closures, retire uncertain workers and bound native resources. Timeout alone is not an OS memory sandbox. ExMaude starts no controller, Thing runtime or application safety policy.

## Acceptance

EMI-T1: legacy shapes and findings remain compatible. EMI-T2: timeout/bounded absence cannot become established. EMI-T3: tests demonstrate the current priority, missing-value and invoke semantics. EMI-T4: pairwise, reachability, deadlock and cycle evidence are not conflated. EMI-T5: unsupported consumer semantics fail explicitly. EMI-T6: any future positive profile has independently reviewed completeness and counterexample tests.
