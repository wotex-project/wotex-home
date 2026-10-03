---
title: "Portable Profiles Without a Second Home Authority"
type: research
status: reconciled
terminal_state: source_analysis
version: "0.1.1"
created: "2026-10-03"
source_revision: "6c00eacc05e0cff01cd104daa07be6e4fca84bdb"
source_commit: "4f89a46daaba6e5d2b6fe97ee9890a97f4745595"
---

# Portable Profiles Without a Second Home Authority

This incoming memo is preserved as a baseline source. Its decisions are consumed
in [the consolidated research](extension-consolidation.md),
[ADR 0010](../decisions/0010-data-first-profile-admission.md),
[WOH.18](../specs/WOH.18-portable-profile-admission.md) and the
[implementation plan](../plans/portable-profile-admission.md). The source audit
now traces actual profile/rule writers and the optional WIT preview. The original
memo below inspected README/working policy only; it supplies no executed-test
or physical evidence. Its proposed programme no longer owns the build order.

## Decision

Validate independently delivered, immutable device profiles and bounded automation definitions through Home's existing authority and durable Store. **Do not introduce a general-purpose third-party executable plugin host as a default Home requirement.** The inspected evidence establishes a profile/control boundary, not demand for arbitrary downloaded applications.

An executable parser or protocol helper is a separate candidate only when an actual device integration cannot be expressed safely with the existing declaration/transport contracts. That candidate must justify its extra runtime, update and security burden. Home must remain useful without a cloud, generic agent engine or working internet connection.

This research is not authorization to enable physical dispatch, install a runtime, weaken qualification, or replace the existing application. It records a bounded design and open validation gates.

## Evidence, scope and existing owners

Baseline `6c00eacc05e0cff01cd104daa07be6e4fca84bdb`. Reviewed: the repository working contract and README through the development/host sections. These sources describe implementation and intended behavior together; this memo does not certify their physical or runtime claims by rerunning tests.

The working contract gives `WotexHome.Authority` ownership of application use cases and a single `Durable.Store` ownership of SQLite, revisions, transactions and host locks. Device workers do not receive the Store connection or bearer credentials. README describes host-held capture evidence, immutable compiled profiles, separate enrollment and physical qualification, guarded LIFX dispatch and correlated readback. Physical dispatch remains disabled by default [S1][S2].

Home is one OTP application, not a collection of independently deployed Home business modules. The macOS service and Raspberry Pi 4 Nerves profile share semantics but have distinct host qualification. A Pi 5 result from another project is not Home appliance evidence.

## The actual value proposition

A new qualified profile should not require changing household authority or recompiling unrelated product logic. An updated rule should have an inspectable semantic diff and be admitted against current facts. Offline profile custody can make provenance and reproducibility better than a mutable list of vendor modules.

The expected benefit is bounded configuration portability and safer update evidence. It is **not** a claim that a plugin marketplace, WASI engine or universal capability router would improve Home today. Existing protocol libraries remain reusable dependencies; their presence in Mix is not itself a defect.

| Contribution | Proposed path | Authority retained |
|---|---|---|
| Device identification/mapping profile | Signed or otherwise locally trusted immutable data | Enrollment and qualification stay with Home |
| Automation definition | Existing bounded declaration and admission | Current rule and physical-effect guards stay active |
| Transport implementation | Consumer-selected WoTEx binding | Home decides targets, credentials and permitted Actions |
| Untrusted vendor parser | Optional isolated helper after a concrete need and conformance proof | Output is evidence only |
| AI intent interpretation | Bounded proposal through the same command gate | No grant or direct physical dispatch |

## Proposed profile lifecycle

```text
fetch/import bytes -> quarantine and integrity check
  -> validate exact profile schema and provenance
  -> compare against enrolled Thing and observed firmware
  -> show semantic/permission changes
  -> operator review where required
  -> commit selected profile revision through Home authority
  -> recheck current qualification before each physical effect
```

A catalogue update must never silently widen an existing controller credential. Home's documented enrollment path replaces a credential when later target grants change; retain that distinction rather than treating a new profile version as consent to new actions [S2].

Bind a prepared change to the expected Thing/profile/rule/store revisions. Recheck after any external preparation and inside the owning commit. Stale capture or changed authorization refuses instead of updating by name. Do not introduce another active-profile database or writer.

A rollback selects a previously retained, currently eligible profile through a new authorized decision. It does not restore revoked credentials, old grants or unknown physical state. Retain historical profile bytes required to interpret old receipts.

## Security and physical effects

Profile matching is evidence about format or device support, not authentication, enrollment or physical qualification. A valid signature identifies approved bytes under a trust policy; it is not proof that a smoke sensor is safe or a specific firmware is compatible.

Treat a parser's values as bounded observations. It cannot select an endpoint, return a new permission grant or write canonical household state. An optional helper receives only the minimal captured input; no radio session, host filesystem, SQLite connection, broad environment or bearer is passed.

Protocol acknowledgement, observed state and physical success remain separate. A timeout or helper crash after a command cannot prove that the device did nothing. Never replay an uncertain physical command solely because a new helper or runtime instance started. Reconcile through the existing correlated observation/receipt path.

Smoke detection and sirens must continue independently of Home. A new composition mechanism cannot turn Home into a certified safety system or make an optional software service part of the detector's safety dependency.

For any future executable helper, independently enforce CPU, memory, input/output length, temporary storage and process lifetime. A caller timeout is not proof of native termination. OS processes need actual sandbox policy, not just supervision [E2]. Unsupported host isolation fails closed; do not run the same artifact with wider permissions on macOS for convenience.

## Local-first and host constraints

An admitted profile and its relevant trust material must be available locally. Existing ordinary control continues under the documented offline policy. Updating trusted metadata while disconnected needs an explicit freshness/recovery rule; absence of a network is not permission to disable verification.

Nerves firmware delivery and operator-installed artifacts are separate release surfaces. The appliance owner must decide whether executable code may change independently of firmware. This paper does not assume such support. Data profile replacement can still be useful without dynamic executable loading.

Keep host service lifecycle, private custody, restart and backup/recovery in the existing native and release owners. Closing a UI does not become a mechanism to stop a physical worker, and an application update cannot ignore a retained ambiguous command.

## Symmetry and limits

The reusable pattern is exact artifact identity, explicit owner admission, scoped invocation and reproducible evidence. Device profile admission can share those conventions with other systems while remaining completely independent of their runtimes.

The physical control gate is deliberately asymmetric with pure computation. A deterministic transform may be safely rerun; a transmitted device command may not. Preserve this as a negative cross-boundary fixture. Do not infer that common packaging permits a common effect policy.

## Work programme and falsifiers

P0: classify one existing immutable compiled profile and one rule revision as data, code or host configuration. Trace the actual source entry points before implementation; the present review is not an exhaustive code audit.

P1: implement/qualify data-only import and selection only if current source does not already provide them. Exercise review, stale revisions, duplicate identity, offline operation and retained historical receipts. Keep physical dispatch disabled.

P2: consider an isolated decoder only for a named required device/format that the existing bounded path cannot handle. Compare against a conventional reviewed binding release. If it adds no meaningful independent-delivery benefit, reject the runtime addition.

| Gate | Owner | Acceptance requirement |
|---|---|---|
| ENG-PROFILE | Profile/qualification owner | Duplicate labels with different bytes conflict; old captures cannot admit changed device semantics |
| ACT-GRANT | Authority/Store | New profile or target cannot widen an old credential; revoked grants remain revoked after rollback |
| ACT-LOCAL | Native host owners | Profile/rule use works with network disabled and no optional engine installed |
| ACT-RECEIPT | Command owner | ACK-only, timeout and contradictory readback remain correctly distinguished |
| ACT-RULE | Automation owner | Unknown facts do not become true and profile replacement cannot bypass runtime guards |
| ACT-HOST | macOS and Nerves owners | Independent lifecycle/recovery evidence on each target; simulated host proof not physical qualification |
| ENG-HELPER | Optional helper owner | No ambient I/O, authority or Store access; timeout requires observed stop or explicit uncertainty |

Required evidence is a pinned fixture set, exact source/toolchain/host revisions, refusal cases and actual command results. No paid services or physical operations are authorized by this research. No benchmark or conformance suite was run while writing it.

## Sources and promotion

- S1: [Working contract](../../AGENTS.md) at the pinned source revision.
- S2: [README](../../README.md), especially authority, enrollment, command outcomes, offline control and host boundaries.
- Existing owner destinations: [automation](../specs/WOH.04-state-automation.md), [verification](../specs/WOH.07-formal-verification.md), [hardware qualification](../specs/WOH.11-hardware-qualification.md), [release/recovery](../specs/WOH.16-release-recovery.md). Their tests and exact implementation must be inspected before promotion.
- E1: [W3C Thing Description 1.1](https://www.w3.org/TR/wot-thing-description11/).
- E2: [OTP port semantics](https://www.erlang.org/doc/system/ports.html).

Standards are supporting evidence, not implementation proof. The decision can change if a named integration demonstrates independent executable update requirements that bounded profiles cannot satisfy. Until then, keep Home a local authority with selectively replaceable inputs, not another generic plugin platform.
