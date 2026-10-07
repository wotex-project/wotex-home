# macOS signed setup peer v1

Version: 0.1.0. Accepted native mechanism before implementation, 2026-10-07.
WOH.08 owns installed identity and credential brokerage. This gate applies to
the future private native setup/broker channel. It does not replace ordinary
same-user plus bearer authorization, open a bootstrap route, access Keychain or
establish an installed lifecycle by itself.

The app and agent have fixed signing identifiers `org.wotex.home` and
`org.wotex.home.agent`. The native setup gate recognizes only the opposite member
of this pair. It derives its ten-character uppercase alphanumeric Team ID from
its own currently valid Security-framework code object; no request, environment
setting, file, archive or default supplies one. Both self and connected peer must
satisfy the Developer ID requirement: Apple generic anchor, exact identifier,
Developer ID intermediate extension `1.2.840.113635.100.6.2.6`, Developer ID
application leaf extension `1.2.840.113635.100.6.1.13` and exact leaf subject OU
equal to that Team ID. Ad-hoc, unsigned, Apple Development, another identifier
or another team cannot enter setup.

Both native processes require the hardened-runtime signature flag. Neither may
enable debugger/get-task-allow, disabled library validation, unsigned executable
memory, JIT, DYLD environment injection or disabled executable-page protection.
Present forbidden entitlement values must be Boolean false; integer substitutes
or malformed values fail closed. Absence means no exception. This restriction
applies to the native setup pair, not a separately reviewed OTP/helper runtime.

For each connected AF_UNIX stream, require a non-root same effective/real user,
retrieve exactly the kernel's 32-byte `LOCAL_PEERTOKEN` and use
`kSecGuestAttributeAudit` with `SecCodeCopyGuestWithAttributes`. Never identify a
process using a caller PID or pathname. Dynamic `SecCodeCheckValidity` must pass
the peer's exact requirement before any setup frame or secret exchange. A
private seal retains that exact audit token and role; it contains no credential,
Keychain value, SQLite handle or caller-supplied signing fact. Recheck self,
same-user peer, exact token and dynamic code validity at the next sensitive
boundary. Exec/replacement, unavailable code metadata or changed context rejects
the connection. Errors are bounded categories and never print signing objects,
tokens, request bytes or credentials.

The fixed requirement generator and entitlement screening are inert pure values.
Only actual kernel/Security checks create a private connected-peer seal; tests
cannot turn invented facts into one. Software checks must compile under the
existing Swift 6/macOS 15 warnings-as-errors policy, verify independent rejection
vectors and exercise real socket audit-token capture and unsigned-peer refusal.
Actual Developer ID pair success, changed/revoked signing identity, installed
background registration and locked/denied Keychain behavior remain separate
installed-artifact obligations. No missing signing identity is replaced with a
development bypass.

The public SDK's `sys/un.h` defines `LOCAL_PEERTOKEN`; Security's `SecCode.h`
defines audit-token guest lookup and signing-information flags. Apple's
[dynamic code validation](https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:))
and [requirement reference](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
define the selected APIs and Developer ID requirement syntax. The native gate
uses those public interfaces; it adds the specific closed Home peer policy.
