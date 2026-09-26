# WOH.04 State, reconciliation and automation

## Status

Accepted target contract.

Home owns canonical observations, desired state, rule state and Action-effect evidence. Every observation retains Thing/profile/protocol provenance and observation time.

State distinguishes known, stale and unknown. A sleepy Zigbee device is not unavailable merely because it is quiet.

Each enrolled Thing is supervised independently. Reconciliation uses bounded retries, distinguishes transport failure from rejection, preserves identity across addressing changes, prevents duplicate effects after restart/replay, and records unknown outcomes when physical effect cannot be established.

Rules are deterministic data with trigger, conditions, effects, priority/safety class, provenance and revision. False and unknown are distinct.

Rule changes create new revisions. Governed compositions are qualified under WOH.07 before activation.

Safety invariants may constrain ordinary automation. Example: active smoke safety mode may require evacuation lighting despite a conflicting night rule. Precedence is explicit model/policy data.

Schedules and automations execute locally while WAN is absent.
