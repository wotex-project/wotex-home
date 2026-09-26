# WOH.03 — Local integration contracts

Version: 0.2.3. Status: accepted target. Each implementation advertises only its qualified subset.

## LIFX LAN adapter

**H03-01.** Use the documented local binary protocol, with UDP broadcast `GetService` on port 56700 as the older-bulb discovery baseline. mDNS is an optional firmware-dependent path. Select interfaces explicitly, then use bounded unicast for enrolled devices. Record product, vendor and firmware responses and a pinned product-capability registry; unknown products do not inherit colour or temperature ranges from a similar SKU.

The first Home codec subset encodes the 36-byte little-endian frame, broadcast `GetService`, unicast `GetVersion`/`GetPower`, and absolute `SetLightPower`. It decodes only selected service, version, power, light-state and acknowledgement responses with exact payload sizes. A bounded in-boot ledger correlates unicast replies by source, target and sequence; it rotates source when the sequence wraps and expires unanswered requests. This is correlation, not device authentication or durable command completion. A pure finite-window collector now converts matching StateService datagrams into untrusted candidates and retains endpoint collisions. Discovery still needs the interface-scoped upstream UDP owner. LIFX's [packet contents](https://lan.developer.lifx.com/docs/packet-contents) and [communication guide](https://lan.developer.lifx.com/docs/communicating-with-device) specify `tagged=1` for broadcast discovery; an inconsistent example in the query page does not change this baseline.

The adapter validates frame length/header, target, source and sequence against a live request ledger. Sequence reuse must account for delayed replies and wrap; correlation is not authentication. Keep finite per-device inflight work and retries, and rate-limit below the documented device ceiling. Generic WoTEx UDP supplies datagrams only; Home owns LIFX framing, acknowledgements, state requests and HSBK conversion.

Before this path can claim local control, the pinned upstream datagram owner must define interface and endpoint ownership, receive credit and queue bounds, overflow and truncation reporting, socket shutdown and address churn behavior. UDP send acceptance is not delivery or device acknowledgement. Home qualification tests the selected upstream revision with malformed, delayed and oversized datagrams.

Brightness-only changes requiring read-modify-write serialize through the light's effect domain and require sufficiently fresh state. A stale read cannot overwrite a newer colour request. Prefer absolute settings over toggles. ACK, returned state and transition completion are distinct. Duplicate or unsolicited state cannot complete the wrong operation. Reference: [communication](https://lan.developer.lifx.com/docs/communicating-with-device), [packet structure](https://lan.developer.lifx.com/docs/packet-contents).

## Hue Bridge adapter

**H03-02.** Prefer locally enrolled Bridge v2 resources and the local event stream. Discovery is local mDNS or an operator-configured address, not a cloud lookup. Bridge credentials are stored in local custody and resolved per request. Validate the bridge TLS identity using a qualified trust/pinning strategy; never globally disable certificate verification.

A bounded initial resource snapshot plus event deltas builds the projection. After reconnect or an uncertain gap, resnapshot; the stream is not assumed to be a replayable event log. Devices, light resources, rooms, zones and grouped-light resources are separate identities. Only qualified members participate in optimized group writes. Legacy bridge/API support is an isolated explicit profile with its own security and feature limitations, not an invisible downgrade. No cloud API is used for normal operation. Reference: [Hue v2 overview](https://developers.meethue.com/new-hue-api/).

## Shelly adapters

**H03-03.** Detect exact generation/model/firmware; do not apply Gen2 RPC to Gen1 endpoints. For Gen2+, HTTP is request/response and does not carry notifications. Use an explicitly owned WebSocket or operator-controlled MQTT path for notifications where supported; reconnect requires a fresh status baseline. RPC request IDs and source fields are correlation, not permissions. Digest authentication does not encrypt HTTP traffic.

Gen1 CoIoT, MQTT and HTTP are independent qualified paths. A WebSocket is not SSE, and neither JSON-RPC envelopes nor vendor component semantics belong in a generic HTTP binding. Generic WebSocket support is an explicit reusable transport dependency if required; do not claim it already exists in WoTEx. Reference: [RPC channels](https://shelly-api-docs.shelly.cloud/gen2/General/RPCChannels/) and [notifications](https://shelly-api-docs.shelly.cloud/gen2/General/Notifications/).

## Aqara smoke profile

**H03-04.** Pair through an operator-owned Zigbee NCP coordinator and the generic WoTEx Zigbee boundary. Do not require an Aqara hub or the Zigbee2MQTT runtime. The NCP still runs chipset firmware; independence from a cloud does not make that firmware open source.

Interview the actual detector before mapping standard or manufacturer attributes. Distinguish smoke, self-test, manually activated buzzer, health and battery. Unsupported writes are absent. Preserve optical-density units exactly; do not treat an optical dB/m quantity as radio power dBm. Sleepy reports have model-specific expected intervals, not aggressive polling.

The [third-party implementation reference](https://www.zigbee2mqtt.io/devices/JY-GZ-01AQ.html) lists related model fingerprints and reports coordinator/firmware caveats. These are qualification risks, not proof that the purchased unit is defective or compatible. Automatic OTA and remote hush are disabled. Detector linking is not claimed to work independently of the coordinator merely because a linkage attribute exists.

## Shared evidence

H03-T1: exact wire fixtures and malformed/truncated/reordered replies. H03-T2: WAN blocked before boot, with no cloud credentials. H03-T3: read-back, partial scene, timeout and unknown-effect cases. H03-T4: credential/correlation crossover between devices is rejected. H03-T5: sleepy, restarted and physically replaced devices. H03-T6: a real device from each claimed cohort; a software converter alone is insufficient.
