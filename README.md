# Wotex Home

**Local-first, vendor-independent home control built on WoTEx and Elixir/OTP.**

Wotex Home is a headless home-control runtime whose first responsibility is a predictable, safe and autonomous home. Qualified devices are discovered, observed, controlled and automated locally. Normal operation does not require WAN connectivity, a vendor account, a cloud service, AI, formal-verification availability, a desktop UI, or Refpath.

The first development host is macOS + Elixir/OTP. Nerves is a later appliance/reference host using the same domain contracts.

Start with the [WOH specification index](docs/specs/WOH-index.md), [architecture](docs/architecture/system.md), and [implementation plan](docs/plans/implementation.md).

## Product authority

    physical observations / structured requests / schedules
                         |
                         v
                  deterministic Home core
                 /          |            \
         authorization   invariants    automation
                 \          |            /
                   qualified plan
                         |
                    WoTEx Runtime
                         |
               local physical protocols
              /       |       |       \
            LIFX     Hue    Zigbee   Shelly

Optional capabilities strengthen boundaries rather than owning the house:

- ex_maude qualifies automation/rule compositions before admission and can verify selected safety properties. A candidate that fails its configured qualification policy is never activated.
- DistilBERT is an optional local natural-language request adapter. It produces untrusted intent evidence that enters the same deterministic planning/authorization path as other requests.
- Refpath is an optional consumer of already validated Things and policies.

None replaces physical observations, authorization, deterministic runtime guards or the active admitted rule-set.

A smoke detector's autonomous alarm remains authoritative even if Home, its coordinator, WLAN and Internet are unavailable.

Initial qualification targets are existing older EU LIFX bulbs, Philips Hue through the local Bridge API, the purchased Aqara Smoke Detector through an operator-controlled Zigbee coordinator, and exact Shelly devices only after their local cloud-independent path is proven.

Generic transports/protocols belong upstream in WoTEx. Home owns home Thing Models, device-family profiles, canonical state, automation semantics, safety policy, qualification and host composition.

## Status

Specification-first. A target contract, profile description or lab plan is not implementation or hardware qualification.
