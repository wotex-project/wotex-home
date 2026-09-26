# Procurement and qualification order

## Existing equipment

Older EU LIFX bulbs are owned. An Aqara Smoke Detector was purchased without an Aqara hub. The Mac is the first host. Other photographed electronics remain useful lab fixtures; possession is not proof of exact model or protocol support. Do not mark Hue hardware or a specific Shelly plug/smoke model as owned without confirmation.

## First missing component

A Zigbee-capable coordinator/NCP is required for the detector's network path. macOS Wi-Fi/Bluetooth cannot supply an IEEE 802.15.4 radio through software. No separate consumer cloud hub is required.

| Candidate family | Host path | Important qualification |
| --- | --- | --- |
| TI CC2652-class, including P7 variants | Z-Stack ZNP/Monitor-Test over serial | exact firmware/API, asynchronous confirmation, backup/counters, macOS USB driver |
| Silicon Labs EFR32 NCP | version-negotiated EZSP over ASH | framing/recovery, SDK/firmware version match, backup/counters, macOS serial |

Start implementation with one documented NCP family, not two partially working backends. TI ZNP is the first engineering candidate, not a claim that every P7 dongle is superior or compatible with the purchased detector. An EFR32 alternative remains valid if its qualified host interface and firmware are a better fit. Open host control, firmware redistribution rights and fully open radio firmware are separate procurement fields. A cloud-independent dongle may still contain vendor-licensed stack firmware.

Require an exact product/revision, antenna/RF region, current firmware source and digest, recovery/flashing procedure, host protocol documentation, macOS USB identity and Nerves reuse plan. No product is approved only because it works with Home Assistant. Do not select a ConBee III for this first detector cohort without resolving the reported alarm-report concern against the exact hardware/firmware.

## Avoid premature purchases

No Pi, LoRa gateway, Aqara hub, mandatory cloud account or combined Zigbee/Thread device is required for the initial macOS path. Add a separate Thread radio only for a selected Thread test; Matter over IP does not itself require Thread. No mains rewiring or custom smoke hardware is part of the first lab.

Buy later hardware against a named evidence gap: independent Hue/local-light comparison, exact Shelly local device, second coordinator interoperability, Nerves appliance and signed mobile/ecosystem testing. Availability and pricing are rechecked at purchase time rather than frozen into a specification.
