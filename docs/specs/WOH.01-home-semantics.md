# WOH.01 Home semantic model

## Status

Accepted target contract.

Home models semantic capabilities, not brands. Device profiles select only affordances proven by hardware evidence.

## Core Thing Models

**Light:** power; optional brightness, hue, saturation and colorTemperature; reachable; optional atomic setState; stateChanged/becameUnavailable Events.

**Switch/Plug:** power; optional activePower, voltage, current and energy; optional overload/temperature Events.

**MotionSensor:** motion; optional battery, illuminance and health; motionDetected and optional motionCleared.

**SmokeDetector:** smoke; optional smokeDensity, battery, voltage and health; smokeDetected, optional smokeCleared and low-battery/health Events. selfTest is privileged when qualified. silence/manual alarm are safety-privileged and disabled by default.

**EnvironmentalSensor:** reusable evidence-backed temperature, humidity, pressure and related Properties.

**Bridge/Gateway:** represents a bridge only where useful; child Things remain independent semantic Things.

**Room/Group/Scene/HomeMode:** Home-domain composition values. Vendor scenes are adapter inputs, not universal scene semantics.

## Desired versus observed

Home distinguishes desired state, command accepted, physical state observed, stale and unknown. A successful write is never automatically promoted to physical truth.

Missing capability is not failure. A white-only bulb is a valid Light without colour affordances.
