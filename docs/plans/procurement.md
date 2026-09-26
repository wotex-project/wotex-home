# Hardware procurement

## Already owned/purchased

- older EU LIFX bulbs;
- Aqara Smoke Detector, exact SKU still to record;
- existing home-bench electronics described by the WoTEx Lab inventory.

## Required next purchase

**One open Zigbee coordinator** suitable for direct local macOS host control and later Nerves reuse.

Selection gate:
- documented host/NCP protocol;
- local USB serial operation on macOS;
- firmware can be pinned/reflashed;
- no vendor cloud or mandatory daemon;
- good Zigbee coordinator support;
- exact hardware/firmware identity available;
- credible Nerves USB/UART path.

The current preferred first chipset family is TI CC2652P7. Check current Swedish/EU availability before selecting the exact product. The purchase does not make the Aqara profile qualified; pairing/interview/safety evidence does.

## Optional later

- Hue Bridge + bulb if not already available;
- exact Shelly plug/safety device that passes local-only qualification;
- separate Thread RCP for Matter-over-Thread;
- Nerves reference board;
- second coordinator for cross-chip interoperability.

## Do not buy as architecture dependencies

- Aqara hub;
- cloud-only smart-home gateways;
- Home Assistant appliance;
- Zigbee2MQTT host appliance;
- Pi merely to make the macOS PoC work;
- combined Zigbee/Thread radio solely to reduce BOM before qualification.
