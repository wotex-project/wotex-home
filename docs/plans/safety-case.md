# Safety case and acceptance obligations

Version: 0.1.0. This is the structure of an engineering argument, not a certification or completed proof.

| Claim | Required argument | Falsifying test |
| --- | --- | --- |
| Prohibited draft never controls hardware | Candidate isolation and guarded atomic activation | Mutating driver spy records any call from rejected draft |
| Active rules preserve declared constraints | Model/compiler fidelity plus dispatch-time guards | Priority inversion, stale fact, unknown negation or missing guard mutation survives |
| Reconciliation does not oscillate indefinitely | Effect ownership, causal/rate/dwell bounds | Repeated conflicting updates exceed the admitted budget |
| Restart does not blindly repeat effects | Durable operation identity and unknown-outcome handling | Crash after handoff causes an unqualified toggle/pulse retry |
| Local operation does not depend on WAN | All runtime artifacts and credentials local | Cold WAN-cut run blocks on download/login/public DNS |
| Smoke alarm remains autonomous | Manufacturer standalone function, no software dependence | Detector loses its prescribed local behavior when host is absent |
| A second controller cannot silently become writer | Ownership and verified handover/isolation | Restored or partitioned peer issues effects concurrently |
| Formal evidence is accurately scoped | Exact input/model closure and completion semantics | Bounded no-finding/timeout displayed as proof |
| A report identifies the real tested cohort | Immutable source/hardware/firmware identity | Changed firmware inherits passed capability status automatically |

## Limits

Home cannot prevent a compromised physical device, a user operating another vendor controller or an unmodeled environment from violating an assumption. It must detect and disclose the limits of its authority. Unauthenticated local protocols cannot be made cryptographically trusted by attaching a WoT description.

A separate threat model covers unauthorized requests. Safety invariants cover allowed requests and faults; neither substitutes for the other. Liveness, security, physical reliability and legal certification are separate claims.

## Required evidence practice

Each claim links to the WOH requirement/case IDs, model/compiler versions, test procedure and retained result. Failing, blocked and not-run cases stay visible. Unit and simulated results cannot satisfy standalone detector or physical radio obligations. A reviewer checks the expected result independently of the implementation where feasible. No automatic support badge is generated from this prose.
