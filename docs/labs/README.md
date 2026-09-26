# Home lab catalogue

Lab procedures describe work to execute, not passed tests. The [hardware ledger](../provenance/hardware-qualification.md) records current possession and unknowns; WOH.11 defines per-capability evidence.

| Lab | Primary obligation |
| --- | --- |
| [Old EU LIFX](lifx-old-eu.md) | Direct local discovery/control and state confirmation |
| [Aqara smoke](aqara-smoke.md) | Exact-device direct Zigbee and independent safety/report evidence |
| [Hue local bridge](hue-local.md) | Local enrollment/resources/events |
| [Shelly local devices](shelly-local.md) | Exact-generation local APIs and load policy |
| [Universal Light](universal-light.md) | Unchanged semantic consumer across independent protocols |
| [WAN cut](wan-cut.md) | Offline cold boot and interruption recovery |
| [macOS host](macos-host.md) | Background service, native custody and lifecycle |
| [Nerves host](nerves-host.md) | Appliance parity and real recovery |

Admission, activation-race, crash-point, fault-injection and rejected-draft tests are mandatory even before hardware is attached; see the [safety case](../plans/safety-case.md) and each spec's required case IDs. The full Goatmire profile adds real local DistilBERT and ex_maude but never gives rejected fixtures production credentials.

For a new lab record exact model/firmware/profile, host image, source identity, network path, power source, prerequisites, step, expected result, raw/private evidence location, redaction and explicit pass/fail/blocked/not-run status. Do not copy a result from another chipset or quietly replace a failed physical run with a simulator.
