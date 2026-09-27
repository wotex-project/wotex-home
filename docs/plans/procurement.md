# Procurement and qualification order

## Available equipment

The operator reports that all hardware needed for the build is available. Older EU LIFX bulbs and an Aqara Smoke Detector are known targets, and the Mac is the first host. Exact device, coordinator, Hue, Shelly and Nerves inventory remains to be recorded from local labels and protocol interviews. Availability is not proof of an exact model or supported capability.

## Coordinator qualification

A Zigbee-capable coordinator/NCP is required for the detector's network path. The reported available hardware removes procurement as a planning blocker; the exact coordinator chipset, firmware and host interface still need to be recorded before pairing or qualification. macOS Wi-Fi/Bluetooth cannot supply an IEEE 802.15.4 radio through software. No separate consumer cloud hub is required.

| Candidate family | Host path | Important qualification |
| --- | --- | --- |
| TI CC2652-class, including P7 variants | Z-Stack ZNP/Monitor-Test over serial | exact firmware/API, asynchronous confirmation, backup/counters, macOS USB driver |
| Silicon Labs EFR32 NCP | version-negotiated EZSP over ASH | framing/recovery, SDK/firmware version match, backup/counters, macOS serial |

Start implementation with one documented NCP family, not two partially working backends. TI ZNP is the first engineering candidate, not a claim that every P7 dongle is superior or compatible with the purchased detector. An EFR32 alternative remains valid if its qualified host interface and firmware are a better fit. Open host control, firmware redistribution rights and fully open radio firmware are separate procurement fields. A cloud-independent dongle may still contain vendor-licensed stack firmware.

Require an exact product/revision, antenna/RF region, current firmware source and digest, recovery/flashing procedure, host protocol documentation, macOS USB identity and Nerves reuse plan. No product is approved only because it works with Home Assistant. Do not select a ConBee III for this first detector cohort without resolving the reported alarm-report concern against the exact hardware/firmware.

For Nerves, match the selected USB bridge to a module in the **built** system root filesystem, then verify VID/PID, bound driver and stable serial path on the exact board. The locked Pi 4 system artifact contains CDC ACM, CH341, CP210x, FTDI and PL2303 modules, as recorded by `mix woh.nerves.serial.check`; this does not identify the available coordinator. A Nerves community [Zigbee dongle discussion](https://elixirforum.com/t/any-tips-on-using-nerves-and-a-zigbee-gateway/65027/) raised the driver issue and the reliability work needed for a narrow direct-radio stack. [nervescloud/zigbee](https://github.com/nervescloud/zigbee) is a useful EFR32 implementation reference with a stated ZBT-2 cohort; its TI Z-Stack backend is not implemented there. Evaluate it against the exact available NCP and the separately owned WoTEx Zigbee work before selecting a dependency.

## Qualification before additional procurement

No Pi, LoRa gateway, Aqara hub, mandatory cloud account or combined Zigbee/Thread device is required for the initial macOS path. Add a separate Thread radio only for a selected Thread test; Matter over IP does not itself require Thread. No mains rewiring or custom smoke hardware is part of the first lab.

Use the available hardware against named evidence gaps: independent Hue/local-light comparison, exact Shelly local device, second coordinator interoperability, Nerves appliance and signed mobile/ecosystem testing. If later procurement becomes necessary, check availability and pricing at that time rather than freezing them into a specification.
