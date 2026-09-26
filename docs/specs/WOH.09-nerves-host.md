# WOH.09 — Nerves appliance parity and recovery

Version: 0.2.0. Status: accepted target; no board is qualified by this document.

## Shared domain, explicit host

**H09-01.** The same Home state, profiles, rule compiler and command policy run on macOS and Nerves. Networking, persistence placement, clock, credential custody, native binaries and radio adapters are host ports. Start embedded qualification with a supported commodity target and the same USB Zigbee NCP used on macOS. Pi 5 is not an architectural requirement.

A later direct-UART/SPI design is a new physical cohort. Zigbee and Thread use separately qualified radios by default. IEEE 802.15.4 capability alone is not simultaneous Zigbee/Thread support; Matter over Ethernet/Wi-Fi does not require Thread.

## Boot and availability

**H09-02.** Dispatch starts only after store integrity, active artifact identity, authority ownership and required device credentials are admitted. WAN/time-server failure does not disable ordinary local manual control. Certificate validity and wall-clock schedules require explicit clock confidence; do not turn off TLS verification to get past a bad clock.

Driver crashes have isolated bounded restarts. Loss of a coordinator never silently forms a new network. A hardware watchdog checks meaningful host progress, not merely that a process exists. Optional inference/verification cannot consume all memory or postpone critical observation indefinitely.

## Durable partitions and updates

**H09-03.** Keep a read-only firmware image and an explicitly managed durable data area. Select a target with tested dual-slot/recovery behavior and require health validation before marking a new image good. [Nerves target changelogs](https://nerves-system-rpi4.hexdocs.pm/changelog.html) illustrate that automatic rollback depends on the selected system/layout and validation procedure; it is not implied by the word Nerves.

Signed firmware authentication, hardware secure boot, data-at-rest protection and anti-rollback are distinct claims. Record exactly which the board/boot chain provides. There is no mandatory hosted update service. Offline signed update and operator-controlled recovery must remain possible.

**H09-04.** Storage migrations use an expand/contract or equivalent rollback-compatible plan. Restoring an older executable does not authorize restoring stale Zigbee security counters. Before update, quiesce commands and take a consistent backup of database and required network state. A failed update cannot duplicate in-flight actions on the fallback image.

## Model and native packaging

Qualify the Maude executable, licensing/distribution obligations, model closure and resource limits on the exact ARM/Linux target. DistilBERT requires measured cold/warm latency, peak memory, idle power and thermal behavior. No blanket promise that a small board supports the full demonstration profile. A headless appliance may omit optional inference while retaining deterministic operation; omission must not bypass a proof-required transition.

## Acceptance

H09-T1: macOS/Nerves semantic corpus parity. H09-T2: WAN-free cold start and clock uncertainty. H09-T3: actual storage power cuts and rollback validation. H09-T4: image/data migration across success and failed boot. H09-T5: USB/NCP recovery without network reset. H09-T6: native worker exhaustion leaves the controller responsive. H09-T7: backup restore cannot create dual authority or counter rollback. Report exact board, boot chain, system image and artifacts.
