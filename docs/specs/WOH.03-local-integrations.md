# WOH.03 Local device integrations

## Status

Accepted target contract.

## LIFX

Older EU LIFX bulbs are the first direct-WLAN Light target. Required path: local LAN protocol; UDP broadcast GetService discovery as compatibility baseline; mDNS only as optional acceleration; product/version/firmware queries before capability materialisation; HSBK/power/transition conversion behind neutral Light semantics; explicit correlation, finite retry/rate budgets; and post-command observation before claiming physical state. No LIFX cloud is required.

Generic datagrams come from upstream WoTEx; Home owns LIFX packet semantics.

## Philips Hue

Use the local Hue Bridge API: local mDNS or stored address, explicit local enrollment/credential, local resource enumeration and event/update mechanism, then capability mapping into Home Things. Internet bridge discovery is not part of the required path.

## Shelly

Admit only exact SKU/firmware combinations with a documented local path. Cloud-only capabilities are omitted. Generic HTTP/MQTT/WebSocket mechanics remain upstream.

## Aqara Smoke Detector

```text
detector -> Zigbee -> operator coordinator -> wotex-zigbee -> Home SmokeDetector
```

No Aqara hub is required by Home. The detector's own smoke detection/siren remain autonomous. Home consumes additive observations and may trigger additive safety responses. Sleepy-device reporting is event-driven; aggressive polling that harms battery life is prohibited.
