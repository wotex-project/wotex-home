# WOH.08 — Native macOS control surface and background host

Version: 0.2.0. Status: accepted target.

## Process ownership

**H08-01.** SwiftUI owns windows/menu bar, accessibility, native permissions, Keychain integration and notifications. The Elixir/OTP release owns Home state, driver connections, scheduling, admission and execution. Vendor packet formats and rule evaluation never enter Swift.

Frameshift supplies a useful authenticated IPC and native-shell precedent, but its app-owned lifetime is not Home's default. Closing a window must not stop automations. The installed Home profile uses an operator-enabled bundled per-user LaunchAgent managed through [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). A foreground CLI/demo profile remains available and explicitly ends when its process exits. Do not install a privileged root daemon just to keep the UI closed.

**H08-02.** The UI reports background registration, approval-required, running, stopped and degraded states separately. 'Quit UI' and 'Stop controller' are distinct operations. Uninstall/disable background service is explicit and leaves a clear account of the home's resulting availability. A second process cannot take the same authority/store/radio lock.

## IPC and credentials

**H08-03.** The local baseline is versioned length-framed JSON over a per-user Unix domain socket. Use an application-owned directory with mode 0700 and socket mode 0600, reject symlink/non-socket replacement, verify the peer UID where supported and authenticate sessions. Bootstrap secrets are ephemeral, not in process arguments, URLs or logs. Local path possession alone is insufficient authorization.

Apply WOH.15 limits before allocation. Distinguish request correlation from idempotency and physical outcome. Reconnection obtains a current snapshot and operation status rather than resending mutations with new IDs. Events use bounded credit and explicit resnapshot gaps.

**H08-04.** Keychain access must outlive the presentation window. A small native credential broker may belong to the registered host or an authenticated XPC helper. It receives narrow operations and checks peer identity; it is not an arbitrary signing/decryption oracle. Secret bytes stay ephemeral at the network boundary where the protocol requires them. Keychain locked/denied is a typed capability failure, never a fallback plaintext file.

## macOS is not an always-on appliance

**H08-05.** Sleep, logout, service revocation, Keychain lock and USB removal have documented availability effects. A per-user agent does not run after logout; a sleeping Mac does not process Zigbee reports. Optional power assertions require user consent and visible energy impact. They are not an absolute uptime guarantee. After wake, reconcile pending outcomes, report observation gaps and rebuild timers using clock confidence.

The detector's standalone siren remains independent. UI labels must never imply the Mac substitutes for a certified safety hub.

## Local networking and USB

**H08-06.** Declare local-network/Bonjour usage for the actual packaged process that owns the connection; test permission denial and restored permission in the installed artifact. Native discovery supplies untrusted introductions to the core. Network permission UX does not authorize a discovered peer.

The Elixir protocol host owns serial access through an explicitly selected adapter. Match USB identity and operator selection, not a guessed `/dev` suffix. On reconnect, verify NCP identity/version before restoring network use. Neither Home Assistant nor Zigbee2MQTT is a runtime requirement; a documented NCP firmware is still required.

## Packaging and acceptance

H08-T1: a fresh non-developer account can install a signed/notarized artifact containing the selected OTP/native dependencies. H08-T2: background enable/disable/approval and UI/core crash independence. H08-T3: sleep/wake/logout/Keychain denial/USB reconnect. H08-T4: authenticated IPC rejects replayed, oversized, wrong-version and wrong-principal operations. H08-T5: updates retain data, service registration and credentials without a second controller. H08-T6: model and Maude artifacts are preinstalled and no first-run WAN fetch is required. H08-T7: native UI and CLI observe identical receipts.
