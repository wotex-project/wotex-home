# WOH.10 Matter bridge and external ecosystems

## Status

Accepted target contract.

Apple Home/Siri and Google Home are optional request/control surfaces. They are never Home authority.

The desired architecture is a Matter bridge/server exposing qualified Home Things as bridged Matter endpoints:

```text
Apple Home / compatible Google controller
              |
            Matter
              |
      Home Matter bridge
              |
       policy/authority
              |
            WoTEx
              |
   LIFX / Hue / Zigbee / Shelly
```

The current WoTEx Matter package is controller/consumer-side. It MUST NOT be claimed to provide bridge/server/accessory support until upstream specifications and executable evidence add that role.

A future upstream Matter exposed-host contract owns connectedhomeip server/bridge mechanics, fabric state, commissioning, endpoint lifecycle and generic Matter device-type mapping. Home owns which Home Thing may be exported and its policy.

Structured Matter commands bypass DistilBERT and enter deterministic authorization/policy directly.

Legacy Google cloud/local-home integrations that require cloud synchronization/account linking are not foundation dependencies.

Home remains fully functional when Apple/Google ecosystems are unavailable.
