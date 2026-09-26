# WOH.02 Device discovery, profiles and capability evidence

## Status

Accepted target contract.

```text
local discovery observation
 -> bounded protocol evidence
 -> candidate profile
 -> optional bounded probe/interview
 -> exact profile resolution
 -> capability evidence
 -> Thing Model
 -> validated TD
 -> Home registry
```

Discovery is local: UDP broadcast/mDNS, Zigbee join/interview, Hue local discovery, local HTTP, BLE or configured endpoint.

A versioned profile declares family/model match evidence, firmware/protocol constraints, identity strategy, discovery paths, capabilities, decoder/encoder revision, safety class, local-control proof and qualification status.

Transient IP, Zigbee network addresses and BLE private addresses are not durable identity. Public Thing IDs are pseudonymous by default.

Unknown/ambiguous devices remain candidates. An LLM cannot establish device identity or capability truth.

For the purchased Aqara detector, first pairing MUST record manufacturer/model identifier, IEEE address privately, endpoints, clusters, versions, power source, coordinator model/firmware and detector firmware where exposed before selecting an exact profile. A third-party JY-GZ-01AQ profile is interoperability evidence, not proof of the retail unit's identity.

Evidence states are `research`, `fixture`, `integration`, `hardware_qualified`, and `field`.
