# WOH.09 — Nerves appliance parity and recovery

Version: 0.2.4. Status: accepted target, partial implementation; no board is qualified by this document.

## Shared domain, explicit host

**H09-01.** The same Home state, profiles, rule compiler and command policy run on macOS and Nerves. Networking, persistence placement, clock, credential custody, native binaries and radio adapters are host ports. Start embedded qualification with a supported commodity target and the same USB Zigbee NCP used on macOS. Pi 5 is not an architectural requirement.

A later direct-UART/SPI design is a new physical cohort. Zigbee and Thread use separately qualified radios by default. IEEE 802.15.4 capability alone is not simultaneous Zigbee/Thread support; Matter over Ethernet/Wi-Fi does not require Thread.

`native/nerves` is the first development image, targeting Raspberry Pi 4 with locked `nerves_system_rpi4` 2.0.4, OTP 28 and the shared Home source as a path dependency. It boots the existing Store and private Unix socket under `/data/wotex-home`; the image does not add dispatch, network management, an NCP or a local intent runtime. An ARM cross-build and Nerves executable-format check succeeded on macOS. This is packaging evidence only; an exact board, storage and power cohort still needs every H09 acceptance case. The release step removes the development checkout's macOS and x86 Maude executables and C-node bridge from the ARM image. There is no qualified ARM Maude executable, so proof-required transitions remain unavailable.

`python3 bin/check_nerves_image.py <release-tree> <firmware.fw>` now checks the cross-built release tree and image file with bounded reads: AArch64 ELF closure, no Mach-O, no foreign or unqualified Maude executable, and no node flag in the packaged VM arguments. It emits a firmware hash and labels its result `cross_build_packaging_only`. It does not inspect the internal firmware partition layout, prove the image boots, or validate the board's network, storage, update and power-loss behavior.

Before attaching a USB coordinator, inventory the selected system image's serial modules with `bin/check_nerves_serial_modules.py` and require the driver for the coordinator's recorded USB identity. The locked Raspberry Pi 4 system artifact includes CDC ACM, CH341, CP210x, FTDI and PL2303 modules; this is image evidence, not proof that a particular dongle enumerates or its driver binds on a board. The lab must record VID/PID, interface, actual bound driver and stable device path after cold boot and reconnect. A changed system artifact or coordinator USB bridge reopens this gate. A missing driver requires a separately pinned custom system; a source `defconfig` entry alone is insufficient without the module in the built root filesystem.

## Boot and availability

**H09-02.** Dispatch starts only after store integrity, active artifact identity, authority ownership and required device credentials are admitted. WAN/time-server failure does not disable ordinary local manual control. Certificate validity and wall-clock schedules require explicit clock confidence; do not turn off TLS verification to get past a bad clock.

Driver crashes have isolated bounded restarts. Loss of a coordinator never silently forms a new network. A hardware watchdog checks meaningful host progress, not merely that a process exists. Optional inference/verification cannot consume all memory or postpone critical observation indefinitely.

## Durable partitions and updates

**H09-03.** Keep a read-only firmware image and an explicitly managed durable data area. Select a target with tested dual-slot/recovery behavior and require health validation before marking a new image good. [Nerves target changelogs](https://nerves-system-rpi4.hexdocs.pm/changelog.html) illustrate that automatic rollback depends on the selected system/layout and validation procedure; it is not implied by the word Nerves.

The selected 2.0.x Raspberry Pi 4 system has a changed storage layout and requires marking a tested image valid. The development image deliberately does not call `Nerves.Runtime.validate_firmware/0`; a successful cross-build or Store start alone is not enough. A board lab must capture active/next slots, exercise a rejected update and a validated update, and prove preserved `/data` state and fenced authority. The release cookie in one cloned image is shared, even though this profile starts no Erlang distribution or SSH listener. Any remote maintenance profile needs per-unit credential provisioning before it opens a listener.

Use `Nerves.Runtime.firmware_slots/0` and `firmware_validation_status/0` in that lab. The latter's `:unknown` result must not be treated as validated; `firmware_valid?/0` loses that distinction. Nerves's optional `StartupGuard` validates after OTP applications start, which is too weak as Home's full acceptance condition: validation must also confirm Store integrity, compatible data and profile revisions, fenced authority, required local paths and the board's recovery policy. Failure must leave the tentative slot unvalidated and test its actual revert. The 2.0 partition migration is one-way without reflashing, so migration from a pre-2.0 image needs a separate storage/backup procedure.

The development firmware includes `WotexHome.Firmware.BoardSnapshot.capture/0` for a read-only console observation of active/next slots, explicit validation status and current Home Store health. The snapshot has no update or validation method and cannot establish boot success, storage power-cut survival or Zigbee continuity by itself. Retain it with the image/system hashes and before/after physical lab observations outside Git.

Signed firmware authentication, hardware secure boot, data-at-rest protection and anti-rollback are distinct claims. Record exactly which the board/boot chain provides. There is no mandatory hosted update service. Offline signed update and operator-controlled recovery must remain possible.

**H09-04.** Storage migrations use an expand/contract or equivalent rollback-compatible plan. Restoring an older executable does not authorize restoring stale Zigbee security counters. Before update, quiesce commands and take a consistent backup of database and required network state. A failed update cannot duplicate in-flight actions on the fallback image.

## Model and native packaging

Qualify the Maude executable, licensing/distribution obligations, model closure and resource limits on the exact ARM/Linux target. DistilBERT requires measured cold/warm latency, peak memory, idle power and thermal behavior. No blanket promise that a small board supports the full demonstration profile. A headless appliance may omit optional inference while retaining deterministic operation; omission must not bypass a proof-required transition.

## Acceptance

H09-T1: macOS/Nerves semantic corpus parity. H09-T2: WAN-free cold start and clock uncertainty. H09-T3: actual storage power cuts and rollback validation, including an `:unknown` validation status. H09-T4: image/data migration across success and failed boot. H09-T5: selected USB bridge module is present in the built system artifact; the exact dongle enumerates, binds and recovers without network reset on the board. H09-T6: native worker exhaustion leaves the controller responsive. H09-T7: backup restore cannot create dual authority or counter rollback. Report exact board, boot chain, system image and artifacts.
