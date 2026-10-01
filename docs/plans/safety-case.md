# Safety case and acceptance obligations

Version: 0.1.4. This is the structure of an engineering argument, not a certification or completed proof.

Case IDs refer to the accepted [WOH contracts](../specs/WOH-index.md). A listed fixture or package check covers only the stated subset; every full claim below remains open.

| Claim | Required cases | Falsifying test | Current evidence and next gate |
| --- | --- | --- | --- |
| Prohibited draft never controls hardware | H00-T4, H04-T1, H07-T8, H15-T1 | A mutating driver spy records any call from a rejected draft | Draft rejection and held-request fixtures exist. There is no admitted rule runner or physical driver path to spy on yet. |
| Active rules preserve declared constraints | H04-T2, H04-T5, H07-T1, H07-T4, H07-T5 | Priority inversion, stale fact, unknown negation or omitted guard survives a mutation test | Closed source-bound IR drives the sandbox and binds the v3 one-rule proposal basis. Truth tables, 1,620 state cases and a mixed trace check independent correspondence; negative native projection omissions are explicit. Full composed proof, durable activation, current invariant provenance and guarded handoff remain open. |
| Reconciliation does not oscillate indefinitely | H04-T3, H04-T4, H14-T2 | Repeated conflicting updates exceed the admitted causal or effect budget | The pure sandbox bounds draft roots. The Store now retains non-refundable single-effect explicit-request roots and whole-Thing handoff-rate history; neither establishes rule-event lineage, reversal circuit breakers, physical dwell or admitted automation. |
| Restart does not blindly repeat effects | H14-T1, H14-T2, H14-T6 | A crash after handoff causes an unqualified toggle or pulse retry | Synthetic ledger restart marks unsettled work unknown. A real transport handoff and crash-point run remain open. |
| Local operation does not depend on WAN | H00-T1, H09-T2, H08-T6 | A cold WAN-cut run blocks on download, login or public DNS | Isolated release assembly and packaging checks pass. Installed macOS and Pi 4 cold WAN-cut runs remain open. |
| Smoke alarm remains autonomous | H05-T2, H05-T5, H03-T6 | The detector loses its prescribed standalone behavior when the host is absent | Baseline command denial is exercised without hardware. Manufacturer-prescribed standalone and radio-loss tests remain open. |
| A second controller cannot silently become writer | H00-T3, H15-T5, H16-T3 | A restored or partitioned peer issues effects concurrently | Same-host Store locking exists. Cross-host isolation, radio counter continuity and transfer are unproved. |
| Formal evidence is accurately scoped | H07-T2, H07-T3, H07-T7 | Bounded no-finding or timeout is displayed as proof | Negative Maude findings and scoped pure-basis receipts exist. Positive composed-rule proof and worker resource isolation remain open. |
| Replayed or old-boot reports never become fresh rule facts | H04-T5, H14-T1, H15-T1 | Duplicate receipt metadata renews age, restart reuses an old monotonic clock, or corrupt current data bypasses its journal | Store-owned receipt clocks and authenticated bounded fact reads have replay, exact expiry, restart, migration, corruption and encrypted-staging tests. This is accepted receipt age, not source authentication or an admitted invariant policy. |
| A report identifies the real tested cohort | H11-T1, H11-T2, H11-T5 | Changed firmware inherits passed capability status automatically | Cohort and signed-claim fixtures exist. Exact physical identity, reviewed artifacts and release readiness remain open. |

## Limits

Home cannot prevent a compromised physical device, a user operating another vendor controller or an unmodeled environment from violating an assumption. It must detect and disclose the limits of its authority. Unauthenticated local protocols cannot be made cryptographically trusted by attaching a WoT description.

A separate threat model covers unauthorized requests. Safety invariants cover allowed requests and faults; neither substitutes for the other. Liveness, security, physical reliability and legal certification are separate claims.

## Required evidence practice

Each release evidence record links the claim and case IDs above to model/compiler versions, test procedure, environment, cohort and retained result. A claim advances only when every required case has the right kind of evidence; a new entry point or cohort reopens affected cases. Failing, blocked and not-run cases stay visible. Unit and simulated results cannot satisfy standalone detector or physical radio obligations. A reviewer checks the expected result independently of the implementation where feasible. No automatic support badge is generated from this prose.
