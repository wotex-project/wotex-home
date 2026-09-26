# WOH.09 Nerves appliance host

## Status

Accepted target contract.

Nerves is the reference embedded deployment foundation after the macOS PoC. The same pure Elixir/OTP Home core and protocol ports move to Nerves; host adapters change.

The first Nerves qualification SHOULD use commodity supported hardware before custom PCB work. A Pi 5 may be a qualification target but is not an architectural requirement.

Required appliance properties:
- boot/use without WAN;
- Ethernet/WLAN recovery;
- watchdog/supervision recovery;
- durable local state across power loss/update;
- Zigbee coordinator network state backup/restore;
- signed update strategy;
- local mDNS/discovery;
- protected credential custody;
- explicit hardware/radio/firmware identity.

The first Zigbee path SHOULD reuse the same USB coordinator as macOS to isolate host migration. A later manufactured carrier may use direct UART/SPI only behind the same generic radio/coordinator behaviour.

DistilBERT requires target-specific memory/latency/thermal qualification. ex_maude requires a qualified Maude executable for the exact Linux/ARM target; absence cannot silently bypass a required verification gate.

Zigbee and Thread SHOULD use separately qualified radios unless executable evidence proves a combined design is stable for the selected hardware/firmware.
