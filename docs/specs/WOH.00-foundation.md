# WOH.00 Scope and local-first foundation

## Status

Accepted target contract. No implementation claim.

Wotex Home is a generic home-control consumer of WoTEx. Its reusable core is Elixir/OTP and MUST be headless. macOS and Nerves are host compositions, not semantic forks.

## Local-first invariants

- Normal observation, control and automation of a qualified device MUST NOT require WAN connectivity.
- The runtime MUST boot into useful local operation while WAN and public DNS are unavailable.
- Device telemetry remains local by default; any external destination is explicit operator configuration.
- Mandatory manufacturer cloud/account/cloud-only decoding or control is a hard failure for a reference profile.
- Vendor cloud MAY be optional but cannot become identity truth, state authority, discovery prerequisite or safety dependency.
- Local credentials and network keys remain under operator custody.
- Loss/restart of WLAN, router, bridge, coordinator or device is explicit and recoverable without replacing logical Thing identity.
- Generic protocol mechanics belong in WoTEx.
- Refpath is optional and removing it cannot change deterministic control, safety, local inference or formal verification.

A transport success proves an exchange, not physical effect. Canonical home observations and desired state belong to Home. Physical-device observations outrank statistical inference.

The first development host is macOS + Elixir/OTP. Core modules MUST NOT depend on Swift, AppKit, Nerves APIs, Raspberry Pi hardware or a particular coordinator.
