# WOH.11 Hardware qualification and labs

## Status

Accepted target contract.

A device family is supported only after an operator-controlled local path is demonstrated with exact hardware/firmware evidence.

Evidence classes: fixture, simulator, integration, hardware, field.

## Initial matrix

- Old EU LIFX bulb: direct local UDP discovery/control and capability query.
- Purchased Aqara Smoke Detector: direct pairing to our coordinator, interview, reports, smoke/self-test safety evidence, battery/reporting soak and WAN-cut.
- Hue Bridge/light: local enrollment/control/eventing with WAN absent.
- Shelly: exact model/firmware local path only.
- Universal Light: equivalent Light semantics across at least LIFX and Hue.
- macOS host: installed/local Elixir host plus USB coordinator.
- Nerves host: later parity/recovery lane.
- Matter bridge: future ecosystem export lane.

## WAN-cut gate

Before a reference release, block WAN/public DNS before host startup and prove local discovery, control, observations, automation, DistilBERT local behavior, ex_maude policy behavior and restart recovery. No required packet may target a vendor cloud.

## Safety qualification

A smoke detector's physical alarm remains independently testable. Network integration cannot be called qualified merely because pairing succeeds.

## Coordinator qualification

Record coordinator model/chipset, hardware revision, firmware version/digest, Zigbee channel/network configuration and detector firmware. Changing radio/firmware creates a new qualification cohort.

The first purchase target is a documented open coordinator suitable for macOS serial use and later Nerves reuse; the exact SKU is selected by the hardware ledger rather than embedded into the architecture.
