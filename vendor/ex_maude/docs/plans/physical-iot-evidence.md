# IoT verification improvement plan

Version: 0.2.0-target. The bundled-model receipt path and focused regressions
have been implemented; a positive-proof profile remains future work.

## Implementation status

The additive `*_with_receipt` IoT APIs use a new isolated Port worker for every
run. They snapshot the bundled model, executable, and prelude, record semantic
and execution identities, bound output and witness data, and keep the legacy
return shapes intact. `test/ex_maude/iot_receipt_test.exs` covers priority,
missing predicates, invocation, cascade versus reachability, terminal-state
evidence, deterministic identity, witness omission, overflow, timeout, and
telemetry privacy. The isolated path has no pool queue or worker replacement
within a run; broader shared-pool atomic loading and custom model closures
are still outside this profile.

The current `IOT-EXEC` model only introduces state values from a finite rule
set and initial state, so a separate finite-state completion profile may be
feasible. It would first need a reviewed closure argument, exhaustive checker
completion evidence, explicit assumptions about unmodeled device/environment
behavior, and independent witness checking. No positive safety or liveness
claim follows from the existing bounded searches.

Read [model scope](../specs/iot-home-verification.md) and [receipts](../specs/verification-receipts.md) before changing public behavior.

## 1. Preserve and demonstrate the present semantics

Add focused regressions for priority not being an execution arbiter, two-valued missing predicates, invocation without modeled effects, and the difference between pairwise cascade, reachable bad state and terminal-state deadlock. Keep tests descriptive of the actual model; do not silently make a consumer's different semantics the new global default.

Pin generic finite rule/world fixtures with independent expected results. Include a prohibited composition as an input to verification, never as a controller that operates hardware. No consumer package dependency is needed.

## 2. Add attribution without changing proof meaning

Implement a versioned receipt value and an additive wrapper or execution operation after reviewing its exact public API. Bind the effective input, model closure, worker epoch and budgets. Preserve legacy returns. Distinguish timing metadata from deterministic semantic identity.

Capture new completion detail at the layer that still has it. A wrapper around an already-collapsed `:unverified` cannot recover missing detail and must not fabricate it.

## 3. Model loading and cancellation evidence

Exercise concurrent first load, partial pool-wide load failure, changed files under the same path, replacement workers, queue timeout, native timeout, output ceilings and parser failure. Isolate immutable model profiles rather than mutating a live shared model namespace while checks run. Establish worker disposition before reuse.

## 4. Evaluate a separate positive-proof profile

Do not advertise positive safety/liveness from the existing bounded APIs. A new finite-state/temporal profile first needs a declared semantic language, finite-state closure where applicable, environment/fairness assumptions, exhaustive completion reporting and independently checked witnesses. Explore feasibility without changing existing behavior. Unsupported proof obligations remain unsupported.

## 5. Acceptance and release

Map tests to EMI/EMR cases. Run unit/parser tests first, then explicitly selected Maude integration tests using a pinned executable. Measure bounds without broad benchmark claims. Publish source/compatibility changes only after the normal release process. The bundled receipt implementation is available in source; positive verification remains unimplemented.
