# WOH specification index

WOH.00–WOH.13 are target contracts at 0.2.x; WOH.14–WOH.16 cover durability, API/authority and release/recovery at 0.1.x. Exact versions and implementation/evidence status live in the catalogue. No runtime implementation is implied by a target contract.

| Contract | Responsibility |
| --- | --- |
| [WOH.00](WOH.00-foundation.md) | Local authority and product scope |
| [WOH.01](WOH.01-home-semantics.md) | Home Things, units and capability differences |
| [WOH.02](WOH.02-discovery-profiles.md) | Discovery, enrollment and profile admission |
| [WOH.03](WOH.03-local-integrations.md) | LIFX, Hue, Shelly and Aqara local mappings |
| [WOH.04](WOH.04-state-automation.md) | Rule admission, arbitration and runtime prevention |
| [WOH.05](WOH.05-safety-security.md) | Safety boundaries, credentials and threat model |
| [WOH.06](WOH.06-local-intent.md) | Trained local intent classification and uncertainty |
| [WOH.07](WOH.07-formal-verification.md) | Proof scope, model fidelity and qualification |
| [WOH.08](WOH.08-macos-host.md) | Native UI, background host and local IPC |
| [WOH.09](WOH.09-nerves-host.md) | Appliance parity, boot, storage and updates |
| [WOH.10](WOH.10-matter-bridge.md) | Optional ecosystem export and multi-controller requests |
| [WOH.11](WOH.11-hardware-qualification.md) | Per-capability hardware and field evidence |
| [WOH.12](WOH.12-manufacturable-hub.md) | Manufacturing composition and provisioning |
| [WOH.13](WOH.13-goatmire-poc.md) | Isolated prevention demonstration |
| [WOH.14](WOH.14-durable-execution.md) | Store, outbox, idempotency and uncertain effects |
| [WOH.15](WOH.15-local-api-authority.md) | Headless API, streams and controller handover |
| [WOH.16](WOH.16-release-recovery.md) | Release identity, updates, backups and diagnostics |

Each contract has stable requirement/case IDs. Their implementation and evidence axes are recorded in [catalogue.yaml](catalogue.yaml). Source changes and test execution must update those axes separately from a prose revision.
