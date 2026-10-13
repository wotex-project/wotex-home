# Device schedule ownership v1

Version: 0.1.0. Updated: 2026-10-13.
Owner: WOH.04 timing policy and WOH.03 device mapping; WOH.20 H20-07/H20-T9.
Status: accepted target. Implementation: planned. Evidence: missing.

## Result and terms

A timer has an execution owner: controller, device or external ecosystem.
Ownership names where execution happens, not permission to edit that timer.
Home must distinguish a currently verified timer from an operator-reported or
stale timetable. A copied app screenshot supplies an attributed proposal,
never a device-read claim.

A Home override/suspension affects only Home-owned work. A motor's internal
timer can still move it while Home is suspended. Timer editing is a separate
qualified operation from movement, and its absence must be visible.

## Timer inventory

Each record binds enrolled Thing, timer identity where available, owner,
source/provenance, observation time/quality, selected profile generation,
schedule basis and supported read/edit/disable/confirm operations. Unknown
fields stay unknown. A device clock/zone and its confidence are independent
of the Home clock. A label match does not prove two timers are the same.
Private identifiers and credentials stay in enrollment custody.

## Migration transitions

The first supported migration moves a known timetable to Home with the
existing effect guards. It is explicitly non-atomic across two owners.

| State / event | Required basis | Result |
| --- | --- | --- |
| Prepare | Reviewed timetable and exact enrolled target; current schedule author/grants | Create an inactive Home revision and durable migration original |
| Request disable | Exact timer/edit capability and separately authorized operation, or explicit manual instruction | Retain its own receipt; Home schedule remains inactive |
| Confirm disabled | Qualified fresh timer read, or explicit operator attestation labelled with its weaker scope | Retain confirmation and source limits; no physical-success inference |
| Activate | Confirmation matches current target/timer/profile and Home revision; current admission, author and clock | Atomically activate the Home generation and migration outcome |
| Any unknown/stale/failed result | Missing read/edit/confirmation, lost reply or changed basis | Hold migration; disclose which owner may still execute |
| Cancel | Current authorized original | Prevent new Home work; do not re-enable the device timer automatically |

Operator attestation can support a deliberately reviewed manual migration policy;
it cannot masquerade as device verification. The initial policy requires an
explicit acknowledgement of uncertain external execution before activation;
otherwise refuse. Profile replacement or unknown disable outcome removes any
automatic eligibility. There is no default “enable both” recovery.

Logical retries recover each original receipt. Restart retains migration state
and requires fresh current-basis checks before activation. Unknown device edits
are reconciled without blind resend. Backup/transfer retain history under
WOH.14/16 but restore neither live confirmation nor active scheduling authority.
Completion means the staged policy was satisfied, not an atomic timer transfer.

## Acceptance and entry

Independent traces inject loss/crash/stale generation at every row above and
assert no unreviewed dual activation. A stopped Home schedule still shows an
external timer as potentially active. Missing timer-edit support presents manual
guidance only. Real hardware tests separately establish actual disable/readback,
clock behavior and coexistence with the manufacturer's app.

Before implementation freeze inventory/migration schemas, confirmation policy,
original-operation routes, Store journal/integrity/backup joins and native owner
labels. No CMD-03 timer command is inferred from the existence of app timers.
