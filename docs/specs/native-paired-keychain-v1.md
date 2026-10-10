# Native paired Keychain custody v1

Version: 0.1.2. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: actual TLS delivery, signed-app/SecItem and original-seal selected factory present; inert policy and unsigned refusal pass locally; installed SecItem and workflow evidence pending.

This composes the existing [verified bootstrap](controller-tls-bootstrap-v1.md)
with [public associations](native-controller-associations-v1.md). It changes no
ordinary API, Store schema, local setup role or private broker group. Public
files, decoded responses and pure correspondence cannot authorize importing a
bearer into Keychain.

## Actual pairing delivery

Only a production entry that calls the actual bounded TLS bootstrap can create
an in-memory pairing delivery. Validate the proposed association label before
sending. A successful delivery requires the exact original request/context,
invited trust/controller, approved access, paired principal namespace and
32-byte bearer distinct from the bootstrap secret. Derive its public record
with the frozen binding/verifier codec. A refusal retains its typed original
context/reason and creates no delivery. Invalid correspondence after a possible
send remains unknown; do not rebootstrap or mint another request automatically.

Delivery construction is private to this entry, with no initializer taking a
decoded record, fixture, raw key or caller assertion of successful TLS. The
delivery expires five seconds after verified response delivery, measured by a
continuous monotonic clock; the original certificate-clock lease must also
remain current. Cancellation refuses delivery/use. Recheck immediately before
and after sensitive custody work. The private bearer has no Codable, file,
description, debug or reflection carrier. Public metadata is exposed separately.
This seal proves that one exchange passed its actual validation; it is neither
current remote authorization nor physical qualification.

## Owning app and item policy

The owning process is the installed native app `org.wotex.home`, separately
from the existing `org.wotex.home.agent` local broker. Derive its current signing
facts from `SecCodeCopySelf`, not a supplied path/team/entitlement dictionary.
Require the existing Developer ID/hardened-runtime policy, matching exact app
identifier and team, and the same forbidden debug/JIT/library-validation
entitlements. Its executable must be the actual outer app's
`Contents/MacOS/WotexHome`. Reuse the protected-installation checks: non-root
same-account process, canonical root-owned app/ancestors, no user/group-writable
or ACL-granted mutation, strict nested static signature validation and a bounded
bundle walk. Retain the actual executable code identity, app path, team and
private group in a nonserializable five-second access seal. Repeat those actual
checks before and after SecItem boundaries; changed signing/installation refuses.

The fixed private group is `TEAM.org.wotex.home`, derived from the actual app's
`com.apple.application-identifier`. If `keychain-access-groups` is present, it
must be exactly that single group. No agent/shared group is admitted. Pure query
or entitlement screening creates no access seal. Distribution signing and
provisioning-profile authorization are installed prerequisites, following
Apple's [Keychain implementation guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
and [distribution entitlement guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

Use only the actual SecItem data-protection Keychain, generic password class,
service `org.wotex.home.paired-controller.v1` and complete association ID account.
Items are non-synchronizing and `WhenUnlockedThisDeviceOnly`. Use a fresh
`LAContext` with interaction disabled and invalidate it after each call. No
caller chooses a service/group/account, fallback implementation or backend.
The original association verifier must match the exact 32-byte item data.

## Publication and recovery

Serialize custody operations with a nonblocking in-process lock. Import accepts
only the actual unexpired pairing delivery. If an exact existing item is found,
require identical bytes and verifier. Otherwise use `SecItemAdd`, with no update,
overwrite or delete. Duplicate-item races are resolved by an actual reread and
exact-byte comparison. Return a private credential only after an actual read
under repeated current app/seal checks. It has no public/raw initializer,
serialized/debug/reflection representation or manual/local fallback.
Credential delivery repeats its original access seal's actual signing,
installation and deadline checks; a cached value cannot extend that lease.
The [selected factory](native-paired-session-v1.md) may pass an actual original
process-access seal to existing-item recovery after its fixed account snapshot
check. This overload repeats the same actual SecItem/signing checks and never
obtains a replacement access lease. A caller cannot construct that access seal
from raw signing facts or an injected backend.

Read-only original recovery accepts a fully validated public association and
retrieves that exact existing account under actual current app custody. Missing,
wrong-sized or mismatching items are custody conflicts; recovery never creates
or replaces an item and never sends an API request. A recovered bearer is only
credential custody. Subsequent use still requires fresh TLS and authenticated
deployment/owner/epoch/principal/grant validation by the selected owner.

Errors remain closed: capacity, expired, locked, denied, unavailable,
custody conflict and unknown publication. If add may have succeeded but a final
read, deadline or custody check fails, retain an unknown publication outcome.
A known SecItem failure is reported only after current custody/deadline checks.
No raw OS error, key or private identity is logged. Keychain failure cannot
select manual/local credentials or start a local controller.

The product pairing workflow must publish the public association only after
matching Keychain custody succeeds. Failed public CAS retains its candidate
and original Keychain account; it cannot delete the item, retry bootstrap or
overwrite another row. Window composition and restart recovery for an
unpublished pairing candidate are separate successors. Loading metadata alone
never imports a key. Pending v1–v4 and their local/manual custody remain unchanged;
remote mutation requires its separately versioned original association record.

## Required evidence

Independent inert queries must check exact class, service/account/group,
data-protection selection, non-syncing/accessibility and interaction policy.
Include invalid records/verifier substitutions and app/agent/team/group
separation. The actual unsigned/ad-hoc process must fail the signing gate;
tests cannot invent an access seal, use an injected successful SecItem backend
or touch the operator's actual Keychain to produce a fixture pass.

Exercise actual TLS delivery against a real isolated Authority: exact public
binding/verifier, no key/bootstrap disclosure, typed consumed refusal, original
clock/expiry/cancellation guards and metadata edits preserving original custody.
Keep existing bootstrap/ordinary API and local broker policy regressions.
Compilation, inert dictionaries and unsigned refusal do not establish real
SecItem success. Installed signed app/profile success, locked/denied and
duplicate-item behavior, fresh-account restart and macOS 15 interoperability
remain explicit environment-specific gates. No check qualifies a physical device.

## Development evidence

`mix woh.native.paired.keychain.policy.smoke` compiles the production custody,
signing and delivery sources with Swift 6 warnings as errors. Nine independent
public association vectors check the exact inert dictionaries and verifier
bounds; label metadata shares its original account. App/agent/team/group
separation, malformed bindings, interactive-context refusal and the closed
OSStatus policy are checked without opening Keychain. Actual `SecCodeCopySelf`
screening and production existing-item entry refuse the unsigned fixture before
SecItem. No injected backend or fixture-created seal establishes success.

The 35-case native TLS fixture now uses the actual delivery entry for real
Authority pairing and consumed replay. It checks original binding/verifier,
metadata edits, private reflection, cancellation and actual five-second expiry.
An independently decoded generic principal cannot become a delivery. These
checks pass on Swift 6.4/macOS 27 targeting macOS 15. They do not establish
successful installed SecItem add/read, locked/denied/race behavior or signed
app/profile custody. Window/menu-bar composition, public publication after
Keychain success and versioned remote pending originals remain successors.
