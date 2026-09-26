# WOH.08 macOS host and native shell

## Status

Accepted target contract.

The first real host is macOS. Elixir/OTP owns Home semantics, device integrations, registry, automation, DistilBERT serving and ex_maude supervision.

A native Swift/SwiftUI shell follows the proven Frameshift host pattern and owns only Apple-native concerns:
- app lifecycle and menu-bar/window UI;
- local-network permission UX;
- Bonjour/Network.framework where native discovery is advantageous;
- Keychain access;
- notifications;
- signed application lifecycle.

Vendor protocol details MUST NOT leak into Swift.

## IPC

The native shell communicates with the Elixir core through a narrow authenticated local IPC/API. The contract exposes semantic snapshots/events and commands, not LIFX/Hue/Zigbee packets.

The core may run as a supervised child process/service during development and as a packaged companion in an installed application. Lifecycle and crash recovery are explicit.

The Zigbee USB serial device belongs to the Elixir protocol side, not Swift merely because Swift owns Bonjour.

## Discovery

Native Bonjour records are introductions, not authenticated device identity. Rich semantic admission occurs in the Elixir core.

## Credentials

Swift/Keychain may custody host secrets, but the Elixir core receives only per-operation material or opaque references according to the host credential port. Secrets are not serialized into TDs or UI state.

## PoC

The Goatmire PoC MUST be runnable without the native shell from Elixir/CLI so presentation UI cannot become a semantic dependency.
