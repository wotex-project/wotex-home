# Wotex Home

**Local-first home control built on WoTEx, Elixir/OTP and open physical protocols.**

Wotex Home is a headless-first home-control vertical. The home remains useful when the WAN is disconnected: qualified devices are discovered, observed, controlled and automated locally, credentials remain operator-owned, and no vendor cloud is required for normal operation.

The first development and Goatmire PoC host is macOS + Elixir/OTP. Nerves is a later appliance/reference host using the same domain and protocol contracts.

Start with the [WOH specification index](docs/specs/WOH-index.md), [architecture](docs/architecture/system.md), and [implementation plan](docs/plans/implementation.md).

## Authority chain

```text
local UI / structured request / natural language
                    |
                    v
               wotex-home
          deterministic authority
             /             \
  DistilBERT candidate     ex_maude
  (untrusted evidence)     verification
             \             /
              authorized plan
                    |
               WoTEx Runtime
                    |
       local physical protocols
        /       |       |       \
      LIFX     Hue    Zigbee   Shelly
```

DistilBERT never grants physical authority. A smoke detector's autonomous alarm remains authoritative even if this software, its coordinator, WLAN and Internet are unavailable.

Initial targets are existing older EU LIFX bulbs, Philips Hue through the local Bridge API, the purchased Aqara Smoke Detector through an operator-controlled Zigbee coordinator, and exact Shelly devices only after their local cloud-independent path is qualified.

Generic transports/protocols belong upstream in WoTEx. Home owns home Thing Models, device-family profiles, reconciliation, automations, safety policy, intent interpretation, verification composition and host products.

Refpath is optional and is never required for normal control, safety, verification or local inference.

## Status

Specification-first. A target contract, profile description or lab plan is not implementation or hardware qualification.
