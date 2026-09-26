# Build readiness review — 26 September 2026

The WOH contracts describe a coherent target, but they are not a completed safety case or an executable delivery plan. This review separates decisions that can be made in the core now from external and physical gates. No acceptance case is passed by this document.

## Gaps closed before implementation

| Gap | Decision | Gate |
| --- | --- | --- |
| `epoch` meant both controller ownership and rule activation | Authority epoch changes only on an explicit fenced handover or recovery. Active rule generation changes on activation. Every queued intent binds both and the expected resource revision. | An old queued intent cannot dispatch after either change; ordinary rule activation does not make an otherwise valid API session claim a new controller. |
| The common gate had no executable boundary | All mutating entry points submit one typed command envelope. The gate checks authenticated principal, current authority, exact capability, risk, fresh facts, resource revision and semantic value before any effect intent exists. | Tests send equivalent requests from each available entry point and inspect zero driver calls for denials. |
| Capability and observation shape was implicit | Stable Thing IDs and capability keys are opaque bounded strings. Capabilities declare operation, value type/unit, risk, profile revision and evidence. Observations declare quality, trust, source epoch/sequence and receive time; missing or stale data remains unknown. | Schema/property tests reject unknown fields, invalid units, nonfinite values and false promotion of stale evidence. |
| The first build slice depended on not-yet-available radio, model and native UI work | Implement a dependency-free pure core first. Add persistence and the headless authority before enabling a physical driver. A scripted peer is a test environment, never hardware qualification. | Pure tests pass; no public API advertises hardware control until the durable writer and guarded dispatch path exist. |
| Restricted admission lacked a positive executable basis | The restricted rule profile stays inactive until its grammar, structural argument, compiler correspondence and mutation tests are implemented. A negative ex_maude finding may reject a draft, but bounded absence cannot admit it. | H04/H07 cases pass with actual receipts before any automation can activate. |
| Receipt and evidence state was too coarse | Catalogue status remains a summary. An implementation must link each requirement/case to an executable test and environment-specific receipt. Hardware, field and certification claims cannot be inferred from fixture results. | Release manifest lists unresolved cases with environment and exact cohort. |

## Dependency order

1. WOH.00, WOH.01 and the read-only parts of WOH.02 establish types and authority vocabulary.
2. WOH.05 policy and WOH.14 durable writer make mutation admission possible. WOH.15 supplies the single API and dispatch boundary.
3. WOH.04 and WOH.07 add rules only after structural qualification, runtime guards and activation fencing are executable.
4. WOH.03 adds a local LIFX path through the guarded writer; WOH.11 qualifies it on the exact owned bulb. Zigbee/Aqara is a separate upstream and hardware gate.
5. WOH.08, WOH.06 and WOH.13 add the installed Mac host and demonstration once the core path exists. WOH.16 makes release and recovery claims. WOH.09, WOH.10 and WOH.12 retain separate target, upstream and product gates.

The numerical spec IDs identify contracts, not a safe implementation order. No stub driver, mock checker or documentation checkbox satisfies a physical or formal acceptance case.

## Open external gates

- WoTEx reusable datagram and Zigbee contracts need pinned implementation revisions and conformance tests before Home claims those protocols.
- The detector SKU/fingerprint, selected coordinator and manufacturer safe-test procedure need physical evidence.
- The positive basis for composed automation, a trained local intent artifact, native macOS distribution, Nerves board/native binaries, Matter server role and manufactured hardware remain separate work.
- SQLite storage behavior, credential custody and cross-host fencing require host tests. A local unit test cannot establish power-loss durability or isolation of an old controller.

## First executable milestone

The initial core exposes validated semantic data and read-only discovery/profile decisions. It has no socket, radio, credential or automatic admission path. Its passing tests establish only the named pure contracts. The next milestone adds policy, durable state and one guarded headless command path before the LIFX adapter can transmit.
