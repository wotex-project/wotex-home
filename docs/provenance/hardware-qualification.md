# Hardware qualification ledger

| Target | Purpose | Current status | Mandatory cloud allowed? | Next evidence |
| --- | --- | --- | --- | --- |
| Older EU LIFX bulbs | direct local Light | owned / unqualified | No | exact product/firmware, broadcast discovery, version query, control, WAN-cut |
| Aqara Smoke Detector | autonomous safety sensor + Zigbee Thing | purchased / unqualified | No | exact SKU/fingerprint, coordinator pairing, clusters/reports, safety/restart/battery evidence |
| Zigbee coordinator | operator-controlled radio | not purchased | No | select exact model, macOS serial, firmware pin, Aqara qualification |
| Philips Hue | local bridged Light | candidate | No for normal control | bridge generation/API, local enrollment, event/control WAN-cut |
| Shelly plug | local Switch/Plug | exact model pending | No | model label, firmware/local API |
| Shelly smoke device | local safety candidate | exact model pending | No | model/firmware/local API and autonomous alarm evidence |
| Nerves host | appliance deployment | future | No | exact board/image/radio parity |
| Matter bridge | Apple/Google optional surface | future | No for Home core | upstream bridge/server implementation + ecosystem lab |

## Coordinator selection

The first coordinator should expose a documented host/NCP protocol, work over local USB serial on macOS, permit firmware pinning, and have a credible path to Nerves USB/UART reuse. TI CC2652P7-class coordinators are the current preferred first qualification family; the exact SKU remains a procurement decision until availability and current firmware are checked.

Changing coordinator chipset or firmware creates a new safety-sensor qualification cohort.
