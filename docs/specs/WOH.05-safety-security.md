# WOH.05 — Safety boundaries and local-network security

Version: 0.2.2. Status: accepted target; no life-safety certification claim.

## Independent safety

**H05-01.** A smoke detector's certified standalone detection and acoustic warning must remain independent of Home, the Mac, inference, verification, coordinator, WLAN and WAN. Home adds observations and bounded convenience responses. Lighting controlled by Home is not certified emergency lighting. Do not invent HVAC, door-lock, heater or evacuation control policies merely because an actuator is reachable.

Real smoke, self-test, manual buzzer activation, radio loss and simulated smoke are different facts. A test indication is never silently converted into a real emergency. Missing reports do not clear a prior smoke alarm. Alarm clearance requires exact profile evidence or an explicitly audited operator workflow; an acknowledgement in the UI only acknowledges the notification.

**H05-02.** The baseline smoke profile is read-only. Remote hush, mute, linkage configuration, alarm actuation and OTA are absent from public command surfaces until each is separately reviewed and physically qualified. A later maintenance profile requires authenticated human presence, explicit confirmation, expiry and audit. No natural-language intent, automation or Refpath tool may acquire these privileges. A self-test demonstrates only the functions the manufacturer says it exercises; it is not proof of radio reporting or smoke-chamber sensitivity.

The executable baseline checks an enrolled read-only SmokeDetector through the local socket: a typed `smoke_state=clear` request receives a durable `read_only_capability` rejection, and an undeclared `hush` operation receives `unsupported_capability`, with no held outbox row. The narrow local grammar abstains on a hush phrase. This is input-surface denial evidence for the implemented subset; it does not test a real detector, Matter/Refpath facade or future maintenance profile.

## Threat model

Assume hostile LAN clients, spoofed UDP/mDNS packets, compromised devices, malformed USB/NCP frames, rogue Zigbee join attempts, malicious TD URLs, stolen local credentials and stale backup restoration. A compromised OS administrator and a malicious radio firmware are outside software isolation guarantees and must be disclosed. Local-only is a routing property, not a security proof.

**H05-03.** Separate operator identity from device identity and protocol authentication. LIFX and some local device APIs do not cryptographically authenticate observations. Preserve `unauthenticated_local` trust instead of upgrading it because a MAC address or product ID matched. Zigbee addresses are private identifiers, not secret credentials. Join windows are bounded, install-code/link-key capability is discovered, and unsupported secure enrollment is visible.

## Command risk

**H05-04.** Risk depends on the load and installation, not the word 'plug'. An unknown load, heater, refrigeration circuit or medical device cannot inherit a lamp's automation policy. Ordinary, sensitive and safety-privileged operations have explicit permission and freshness requirements. Group/scene membership must be rechecked when it changes; it cannot smuggle a restricted actuator into an ordinary command.

## Credentials and network scope

**H05-05.** Keys remain in local custody: macOS Keychain or a qualified Nerves store. TDs, discovery records, receipts, fixtures and operational logs carry opaque references, not secrets. Do not persist raw-command hashes as privacy protection for a small guessable vocabulary; use scoped keyed digests when retained correlation is necessary.

Authorize the actual resolved peer/interface and credential audience on every connection. Reject redirects or DNS/address changes that would send credentials to a different authority. A local discovery URL is not permission to fetch arbitrary endpoints. Use bounded local discovery on selected interfaces; no whole-LAN attack-style probing.

Device networks should be separated from administration where the operator can do so. VLANs do not add cryptographic authentication to legacy protocols. Remote access is an explicit operator-controlled VPN plus application authorization. It is disabled by default and does not expose distributed Erlang, raw device UDP or unrestricted serial access.

The initial pure LIFX discovery window requires an explicitly selected IPv4 interface/prefix and rejects response source addresses outside that scope. A same-subnet packet remains untrusted; IP and LIFX target matching are correlation, not authentication. A future socket owner must bind to the selected interface and enforce this scope on received datagrams.

## Updates and audit

**H05-06.** App, model, rule, profile, coordinator and device firmware revisions are separate changes with separate rollback and requalification. Never automatically flash a smoke detector, reset a coordinator network or downgrade firmware to work around an integration failure. Backups contain key/counter continuity requirements, not merely database rows.

Critical audit is local durable data; best-effort metrics cannot replace it. Hash chaining can expose some accidental changes but is not tamper-proof against an administrator who can rewrite the chain. External anchoring is optional and cannot be required for operation.

## Acceptance

H05-T1: every input surface denies smoke mute and unknown-load commands under the baseline policy. H05-T2: simulation/test reports remain distinct from real smoke. H05-T3: secret and identity canaries never appear in exported data. H05-T4: spoofed discovery, redirects and credential-audience changes fail before secret transmission. H05-T5: disconnect host/coordinator and perform only manufacturer-prescribed detector checks. H05-T6: corrupted or stale credentials/backups do not silently re-pair devices.
