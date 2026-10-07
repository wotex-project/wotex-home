# Native setup authority v1

Version: 0.1.1. Accepted mechanism, 2026-10-07.
WOH.08 owns installed custody; WOH.15 owns the Authority boundary. This profile
defines trusted provisioning underneath the separately authenticated native
broker. It adds no ordinary local API route and no device dispatch.

The core returns its validated active controller's deployment ID, owner ID,
authority epoch and current Store revision. IDs are the existing 64-character
lowercase hexadecimal identities. It accepts only an exact current identity
tuple, a fixed role and a 32-byte SHA-256 credential verifier. The native
custodian generates a random 32-byte secret and durably stores it in a private,
non-synchronizing Keychain item **before** asking the core to create its
principal. The secret does not enter this provisioning boundary. Keychain
failure ends setup before a Store write; there is no plaintext fallback.

The fixed roles and ordered permissions are:

| Role | Permissions | Initial Thing grants |
| --- | --- | --- |
| diagnostic | `read` | none |
| operator | `read`, `control:ordinary`, `rule:review`, `rule:manage`, `enroll:review`, `host:maintain`, `profile:manage` | none |
| maintenance | `read`, `host:maintain` | none |
| transfer | `host:transfer` | none |

No role receives `qualify:profile` or `policy:manage`. Transfer custody remains
separate. The current owner's principal ID is
`native-setup-v1:<canonical decimal epoch>:<role>`. A copied/revoked role is
never revived. Changing owners uses a new epoch namespace and a new secret;
copied roles remain historical. Provisioning does not make a new operator the
reviewer of an existing enrollment or expand input/control grants. Those
changes need their own existing or separately accepted authorization paths.

The Store owns one transaction for principal creation and its
`native_principal_provisioned` authority-journal event. The event identifies
that exact principal and consumes one revision. It returns a redacted creation
receipt containing deployment, owner, epoch, role, principal ID and creation
revision. A retry with the same current identity, role, verifier and exact
permission set returns the original creation revision without writing. A
different verifier, revoked principal, substituted permissions or unavailable
original event fails closed; it never rotates or issues another credential.
Thus a crash before creation leaves a Keychain item that can be reconciled,
and a lost committed reply can be resolved using that same item. Losing the
Keychain secret is an explicit custody failure, not permission to mint a
replacement. Secret replacement and target-grant operations require a later
profile with their own durable operation identity.

Reserve this principal prefix from ordinary trusted `provision_principal`,
`rotate_principal_credential` and `grant_target_and_rotate` operations. Explicit
principal/target revocation remains available and is never undone by ensure.
All non-operator native roles retain zero Thing grants; an operator may retain
only the existing bounded grants added through a separately authorized path.
Validate native principal permissions, 32-byte stored verifier, closed name,
one original provision event and at most 260 retained roles at startup and
archive verification. A provision revision must lie in its actual active
ownership epoch, after its preceding acceptance and before a subsequent
retirement. Older-epoch native principals must remain revoked. Reject orphan,
duplicate and generic provisioning events in this reserved namespace. SQLite
rollback must remove both the principal and journal/revision changes.

The inert encoding is a single JSON array with at most eight scalar members,
no objects or nested containers, depth one and at most 4,096 bytes. It uses
exact compact canonical JSON bytes, closed operation names, integer epochs and
revisions in the existing signed-64-bit range, bounded strings and lowercase
hexadecimal verifiers. Boolean/floating substitutes and alternate encodings
are rejected. No decoder creates an atom from a caller value.

The exact records are:

```
["wotex-home.native-setup-authority.v1","identity"]
["wotex-home.native-setup-authority.v1","identity",deployment,owner,epoch,revision]
["wotex-home.native-setup-authority.v1","ensure",deployment,owner,epoch,role,verifier_hex]
["wotex-home.native-setup-authority.v1","ensured",deployment,owner,epoch,role,principal,creation_revision]
```

These are data contracts, not a public listener or proof of a signed client.
The installed broker must use the original signed-peer seal before setup
frames and at sensitive boundaries, finite connection/worker ownership, a
private parent/child channel to this trusted Authority use case and actual
Keychain custody. Apple recommends the SecItem data-protection implementation;
its restricted entitlements require an app-like helper bundle and distribution
provisioning profile. The implementation must choose and document that actual
custody profile before enabling installed setup. No unsigned fixture, optional
environment flag or invented signer fact substitutes for it. See Apple's
[Mac keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
and [distribution entitlements](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

Software evidence must exercise actual Store creation, unchanged retry,
conflicting/revoked custody, original receipt after restart, ownership mismatch,
no target grants, transaction rollback, damaged native history and archive
validation. The ordinary socket must reject native setup operations. Installed
signed-pair success, Keychain locked/denied behavior and fresh-account service
lifecycle remain separate obligations.

The inert codec and trusted Authority/Store use cases are implemented. They
create no credential and open no bootstrap endpoint. The Store reserves the
prefix from generic issuance/rotation, reconciles the current native verifier
and original event, and validates the retained ownership windows at startup and
archive verification. Eight focused cases cover closed independent records,
all four zero-target roles, unchanged retry, restart, identity/verifier
conflicts, revocation, actual journal-trigger rollback, archive/damaged startup
and real ordinary-socket refusal. The existing two-transfer case additionally
retains a native epoch-two role through encrypted export/staging/acceptance,
keeps it revoked and creates fresh epoch-three custody without reviving it.
The full 903-test suite passes with four optional native-backend skips. Native
Keychain storage, private channel delivery and installed setup remain open.
