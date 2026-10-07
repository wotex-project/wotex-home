# Native credential broker v1

Version: 0.1.2. Accepted host mechanism with wire/pipe evidence, 2026-10-07.
WOH.08 owns installed native identity, custody and lifecycle. This broker joins
[signed setup peers](macos-signed-peer-v1.md), the
[private core channel](native-core-channel-v1.md) and
[fixed native roles](native-setup-authority-v1.md). It grants no Thing access,
qualifies no hardware and provides no signing/decryption or arbitrary child
execution operation.

## Native ownership

The per-user agent remains `org.wotex.home.agent` and the app remains
`org.wotex.home`. The agent is an app-like helper at
`Contents/Library/LoginItems/WotexHomeAgent.app`, with its executable at
`Contents/MacOS/WotexHomeAgent` inside that helper. The existing LaunchAgent
label and explicit `SMAppService.agent(plistName:)` registration remain; its
`BundleProgram` is the full path relative to the outer app. The helper's
Info.plist identifies that exact agent and macOS 15 minimum. Its distribution
profile belongs inside the helper's Contents. This is a selected Home layout,
not a switch to login-item registration or a privileged daemon.

Before installed brokerage, the actual agent and outer app must satisfy their
exact Developer ID requirements and hardened native policy. Validate the outer
bundle's static resource/nested-code seal and fixed bundled OTP executable
before launching it. A changed/missing/unavailable seal prevents brokerage.
Installed signing/provisioning is not synthesized by an unsigned build. The
unsigned development profile may retain its normal foreground/manual-custody
host path, with no broker listener or native credential delivery.

The native parent starts one fixed core child and owns both anonymous pipe
endpoints. Its child environment is constructed explicitly: a fixed system
utility PATH, the actual OS user's home, a fixed UTF-8 locale, the private data
directory and `RELEASE_DISTRIBUTION=none`. It does not inherit Erlang/Elixir,
release-root/VM-argument, loader, credential or arbitrary Home overrides. An
explicit selected capture-interface preference may supply the existing
read-only LIFX option after closed name validation; absent means no LAN probing.
It does not enable physical dispatch. No request chooses an executable, eval
expression, environment variable or command argument.

The pipe client serializes one request without an unbounded wait queue, pins
its original descriptors/child and validates exact closed replies. It uses
nonblocking reads/writes and the caller's original monotonic deadline. Child
death, changed pipe identity, malformed or late reply ends that private session.
No new child or named Store is substituted within a request. Closing the
parent's input supplies EOF; termination has a finite graceful period followed
by child termination/reaping. Failed custody cannot leave an unowned child.

The setup socket is `ipc/native-setup.sock` under the same actual private Home
directory: directory 0700, socket 0600, same non-root OS user. Pin owned path
and socket identities; refuse symlink/non-socket or unknown replacement rather
than deleting it. Cleanup removes only the socket created by this broker.
Backlog is four; own at most four accepted sockets including at most two active
validation/custody workers. No unbounded worker/request queue. Each accepted
connection has one original five-second monotonic deadline and one operation.
Validate the actual signed peer before reading a frame, then repeat the original
peer seal before Keychain access, core provisioning and secret publication.
The earlier of accepted-connection and peer-seal deadlines always applies.
Timeout shuts down the socket while keeping an active worker's descriptor
owned until reaped. A blocked OS Security/Keychain call retains its finite
worker slot; another connection never creates an unlimited replacement pool.

## Keychain and reconciliation

Only the agent owns persisted broker secrets. Use SecItem with
`kSecUseDataProtectionKeychain=true`, generic-password class, explicit
non-synchronization, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
`kSecUseAuthenticationUIFail`. Derive the access group from actual valid self
signing metadata: `<self Team ID>.org.wotex.home.agent`. Require that exact
`com.apple.application-identifier`; an optional `keychain-access-groups` value
may contain only that exact group. A request/file/environment supplies no group
or signing fact. Do not use a broad shared Team group or legacy ACL fallback.

The fixed service is `org.wotex.home.native-setup.v1`. The account is the exact
current `deployment.owner.epoch.role` tuple obtained from the pinned core. Each
value is exactly 32 random bytes. Search only that service/account/access group,
non-synchronizing class and data-protection implementation. A missing item is
created once, then reread and compared. Duplicate creation rereads the original
item; it never overwrites it. Malformed, locked, denied or unavailable custody
is a typed failure and performs no provisioning/secret publication.

Persist Keychain custody before sending only its SHA-256 verifier to the core.
Verify the returned original creation receipt against the exact requested
owner/epoch/role/principal. Recheck current core ownership and the signed peer
before returning the secret to the app. Lost/late replies are reconciled from
that same item on a fresh authenticated connection. Owner change selects a new
account and epoch principal; old items/principals are never silently revived.
Losing/revoking custody is an explicit failure. This profile adds no secret
rotation, target-grant or imported-receiving-principal delegation operation.

The app holds the returned secret only for its selected local session and
passes it at the existing authorized network boundary. It neither writes a
plaintext file nor copies it into the legacy manual-import item. Native setup
is an explicit action, not automatic authority merely from registering a
background service. Health/registration and role availability remain distinct.

## Closed socket records

Use four-byte unsigned big-endian length and a compact canonical JSON array,
body 1–4,096 bytes, depth one, at most nine scalar members and strings at most
128 bytes. Validate bounds before parsing. Reject objects/nested arrays,
Boolean/floating numeric substitutes, alternate encodings and trailing bytes.
No caller value becomes an atom or execution name. The exact records are:

```
["wotex-home.native-credential-broker.v1","status"]
["wotex-home.native-credential-broker.v1","credential",role]
["wotex-home.native-credential-broker.v1","status",deployment,owner,epoch,store_revision]
["wotex-home.native-credential-broker.v1","credential",deployment,owner,epoch,role,principal,creation_revision,credential_base64url]
["wotex-home.native-credential-broker.v1","error",reason]
```

Role is one of the four fixed roles. Credential encoding is canonical unpadded
43-character base64url of exactly 32 bytes. Errors are only `setup_unavailable`,
`capacity`, `peer_refused`, `expired`, `keychain_locked`, `keychain_denied`,
`keychain_unavailable`, `custody_conflict`, `owner_changed`, `invalid_request`
or `outcome_unknown`. Pre-authentication failure closes without a frame. No
signing object, request, token, verifier, credential or raw exception is logged.
Private secret/seal values have redacted descriptions/reflection.

Independent Swift/pure records and real unsigned socket rejection must precede
installation. Pipe fixtures must use the actual core and test changed reply
identity, failure/deadline, original retry and child cleanup. Software Keychain
query/error fixtures are inert and cannot create an authenticated peer seal or
claim successful installed custody. Actual signed app/agent pair, authorized
distribution profiles, locked/denied/private Keychain isolation, changed bundle
seal, fresh-account registration/disable/restart and local-network permission
remain installed-artifact obligations. Record physical tests separately.

Apple documents the selected [data-protection implementation](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains),
[app-like profile-bearing helper](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
and [relative BundleProgram service layout](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).

Implemented wire evidence: `NativeSetupWire.swift` has closed core requests and
replies, broker requests, status, credential and typed error records. It checks
the original owner/epoch/role/principal receipt, exact integer/string bounds,
canonical bytes and canonical 32-byte credential encoding. Private credential
records redact descriptions and reflection. The independent
`mix woh.native.setup.wire.smoke` fixture checks literal bytes, original receipt
revisions, mismatched identities/roles, malformed encodings and bounded parser
rejection. These inert records open no socket or Keychain and establish no
signed identity, custody success or installed brokerage.

The native pipe owner is implemented and checked against the actual core and
adversarial child processes by `mix woh.native.core.pipe.smoke`, as recorded in
the owning channel contract. This establishes bounded transport/lifetime and
original receipt reconciliation; it does not validate the installed bundle,
register the agent, create a Keychain item or open the setup listener.
