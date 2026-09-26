# WOH.04 State, reconciliation and automation

## Status

Accepted target contract.

## Goal

Home automation is safe by construction and safe by admission. Runtime execution is not the place to discover that a newly installed rule-set contains an obvious conflict or reachable prohibited composition.

## Canonical state

Home owns canonical observations, desired state, rule state and Action-effect evidence. State distinguishes known, stale and unknown. A sleepy Zigbee device is not unavailable merely because it is quiet.

## Reconciliation

Each Thing is supervised independently. Reconciliation uses bounded retries, preserves identity across addressing changes, prevents duplicate effects after restart/replay, and records unknown outcomes when physical effect cannot be established.

Reconciliation MUST NOT create oscillation by repeatedly forcing desired state against a higher-priority physical or safety condition. Desired-state ownership and precedence are explicit.

## Automation admission

Rules are deterministic versioned data. False and unknown are distinct.

A candidate rule-set follows:

    draft
      -> schema/static validation
      -> deterministic composition checks
      -> required formal qualification
      -> admitted immutable revision
      -> atomic activation

Only an admitted revision may become active. Editing creates a new draft; it never mutates the active revision.

Counterexamples prohibited by policy block admission. Unverified blocks admission whenever policy requires an established result. The previous admitted revision remains active.

## Runtime

Runtime executes only admitted rules plus direct authorized requests. It does not intentionally activate conflicting rules to observe failure.

Runtime guards still enforce safety invariants because environment/device state can change after admission. A failed guard blocks the Action and records evidence; it does not ask AI for an alternative.

## Safety precedence

Safety invariants constrain ordinary automation. An active smoke safety mode may require evacuation lighting despite a night-mode desired state. Precedence is explicit policy/model data.

Schedules and automations execute locally while WAN is absent.
