# Primary sources and inspection baseline

Reviewed: 2026-10-01. Linked documentation informs design; it does not constitute executed qualification. Mutable pages must be pinned or captured under appropriate source rights when implementation artifacts are selected.

## Repository sources

| Source | Inspected identity / relevant material |
| --- | --- |
| Home | `2eec0b7e36e27d23a324b049649eda632b5d4711`; earlier WOH contracts and catalogue |
| WoTEx | `bb7f4c0074ddd2de2390d0d4337cb1efe680d5a3`; root contracts, Runtime, planned WUD/WZG and Matter controller/server separation |
| ex_maude | `ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb`; `lib/ex_maude/iot.ex` and `priv/maude/iot-rules.maude` |
| Frameshift macOS host | `docs/host/macos.md`, inspected blob `ee5139bdd292d5328564d12a1b3e345a85e6b62a`; authenticated local IPC, native custody and lifecycle precedent |

[ex_maude IoT source](https://github.com/futhr/ex_maude/blob/ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb/lib/ex_maude/iot.ex) distinguishes bounded verification from proof. Its [execution theory](https://github.com/futhr/ex_maude/blob/ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb/priv/maude/iot-rules.maude) is the source for the model-fidelity findings. No runtime changes were inferred from documentation-only additions.

Conjunct/Connect remain the physical-composition and commercial-workflow boundaries established in earlier project design. This update does not claim a live manufacturer integration or independently qualified production pack.

## Technical references

- [SQLite synchronous modes](https://sqlite.org/pragma.html#pragma_synchronous): durability distinctions behind the selected authoritative-store policy.
- [OTP gen_udp](https://www.erlang.org/doc/apps/kernel/gen_udp.html): active receive credits, datagram semantics and truncation caveat.
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice): supported bundled per-user service registration.
- [Nerves rpi4 system changelog](https://nerves-system-rpi4.hexdocs.pm/changelog.html): target-specific rollback/firmware validation behavior, not a generic promise for all boards.
- [LIFX local communication](https://lan.developer.lifx.com/docs/communicating-with-device) and [packet structure](https://lan.developer.lifx.com/docs/packet-contents): local discovery/correlation; no cloud control requirement for the qualified LAN path.
- [Hue v2 API overview](https://developers.meethue.com/new-hue-api/): local resource/event API direction. Exact versioned API/security behavior still needs implementation qualification.
- [Shelly RPC channels](https://shelly-api-docs.shelly.cloud/gen2/General/RPCChannels/) and [notifications](https://shelly-api-docs.shelly.cloud/gen2/General/Notifications/): generation-specific request/response versus notification paths.
- [TI ZNP interface, reference guide 3.2.0](https://software-dl.ti.com/simplelink/esd/simplelink_cc26x2_sdk/2.30.00.34/exports/docs/zstack/html/zigbee/znp_interface.html): NCP/host responsibility split. This reference is not the selected production firmware revision.
- [Silicon Labs NCP overview 9.1.0](https://docs.silabs.com/zigbee/9.1.0/zigbee-coprocessors-overview/) and [ASH overview](https://docs.silabs.com/zigbee/latest/uart-gateway-protocol-reference/01-overview): an alternative backend and its distinct framing/recovery contract.
- [Bumblebee text classification](https://bumblebee.hexdocs.pm/Bumblebee.Text.html#text_classification/3): local serving mechanism, not a ready-made home intent checkpoint.

## Third-party implementation evidence

The [Zigbee2MQTT JY-GZ-01AQ profile](https://www.zigbee2mqtt.io/devices/JY-GZ-01AQ.html) records related detector fingerprints, exposed quantities and firmware/coordinator warnings. It is primary evidence of that implementation's supported mapping and reported caveats, not an Aqara endorsement of our stack. It must not select the user's exact retail SKU or justify a battery/safety claim without the unit's manual and physical evidence.

## Unverified claims deliberately excluded

No ten-year battery guarantee for the purchased/configured detector; no universally open NCP firmware claim; no Matter bridge implementation claim from controller tests; no Apple GPU/ANE promise from a backend name; no certification, vendor-free factory provisioning or current price/availability assertion. These require their own exact sources and tests.

## Additional source checks on 2026-10-01

- [Aqara official Smart Smoke Detector manual](https://cdn.aqara.com/cdn/website/mainland/static/docs/Smoke-Detector_User-manual.pdf), model JY-GZ-03AQ, confirms independent photoelectric alarm and distinguishes fire, linkage, fault, low-battery and self-test signals. It also documents wireless silencing. Home continues to exclude hush, linkage and OTA mutation; this manual does not identify the owned retail unit or approve a third-party coordinator.
- [TI SWRA671 coordinator cloning report](https://www.ti.com/lit/an/swra671/swra671.pdf), June 2020, Z-Stack 3.6.0/SDK 3.4, documents network/trust-center keys and TX/RX security counters among required nonvolatile state. Copying only Home SQLite cannot constitute radio recovery. This is a historical exact SDK reference, not the selected NCP firmware.
- [LIFX product registry](https://github.com/LIFX/products/blob/master/products.json) identifies vendor 1/product 22 as Color 1000. The runtime still requires its separately pinned local artifact; upstream names/features do not qualify device effects.
- [Shelly component documentation](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Shelly/) and [Switch methods](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Switch/) preserve the device-generation/component distinction. A model name alone cannot select a switch or authorize a load.
- Signify's public v2 overview remains available, but the detailed API reference and HTTPS guidance were unavailable to this research client. [OpenHue's own API specification](https://github.com/openhue/openhue-api) is implementation evidence that may inform a bounded adapter; it is not manufacturer qualification.
