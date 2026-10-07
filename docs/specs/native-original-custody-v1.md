# Original native credential recovery v1

Version: 0.1.0. Accepted mechanism, 2026-10-07. WOH.08 owns this read-only
extension of [native custody](native-credential-broker-v1.md). It supports
retained client operations without turning recovery into role setup.

An original reference contains the existing deployment ID, owner ID, authority
epoch, fixed native role, original principal creation revision and the
credential's SHA-256 verifier. IDs/verifier are 64 lowercase hexadecimal
characters, epoch and creation revision are positive signed 64-bit integers,
and role is one of the four existing v1 roles. Principal ID is derived as
`native-setup-v1:<epoch>:<role>`; a caller cannot supply another principal.
The reference contains no credential bytes or target grant. It confers no
authority by itself and is not an OS signing, Keychain or controller seal.

The signed app explicitly requests recovery from the same protected agent,
private socket and original five-second peer/frame deadline used for setup.
The closed broker request is the canonical flat array
`[format,"recover",deployment,owner,epoch,role,verifier,creation_revision]`,
where format remains `wotex-home.native-credential-broker.v1`. Existing status
and credential requests retain their exact encodings. All original same-user,
Developer ID, hardened runtime, audit-token, installation and bounded-worker
checks remain mandatory before any frame, secret or Core work.

Before opening custody, the agent obtains current identity from its original
Core child and compares deployment, owner and epoch with the reference. An
ownership mismatch refuses recovery without reading or creating a Keychain
item or ensuring a principal. Current Store revision must be at least the
original creation revision; later unrelated writes do not change identity.

Recovery reads only the existing non-syncing, ThisDeviceOnly Data Protection
Keychain item for that exact native role/account and actual signed access group.
It retains the original peer/deadline checks before and after every Security
call and uses noninteractive access. Missing, locked, denied, malformed or
verifier-mismatching custody refuses. Recovery has no random generation,
SecItemAdd, update, delete, legacy/manual fallback or new account selection.

The private Core read uses the canonical flat array
`[format,"existing",deployment,owner,epoch,role,verifier,creation_revision]`,
where format remains `wotex-home.native-setup-authority.v1`. Its successful
response is `[format,"found",deployment,owner,epoch,role,principal,revision]`
with the original creation revision. Both fit the existing eight-scalar,
4,096-byte closed codec. The trusted parent bridge invokes only
`Authority.existing_native_principal`; no ordinary socket route exposes it.

The Store repeats complete ownership/native-history validation, matches the
original active owner/epoch, fixed principal, original credential hash, exact
v1 permission set and unique original provisioning journal revision. Missing,
revoked, conflicting or different-creation custody fails closed. This read
borrows the Store connection synchronously, opens no transaction and creates
no principal, journal event, revision or schema change. Source retirement and
recovery quarantine refuse it.

After that original read, the agent repeats current Core scope and original
signed peer/deadline checks before returning the existing nine-field credential
response. The client requires every original receipt field and verifier to
match its reference. It holds the recovered bytes in private memory for the
original operation; recovery does not select a general session, import into
manual custody, renew review/freshness, resend a request or generate an ID.
Missing custody leaves the original unresolved. Existing explicit setup remains
a separate operation with its own authorized reconciliation behavior.

Required software evidence includes canonical cross-language vectors and
malformed/extra fields; actual Store reads across restart; absent, revoked,
wrong verifier, changed creation revision and changed owner/epoch refusals with
unchanged revision/journal; actual parent-channel lookup; private client/broker
unsigned refusal before frame/Core/Keychain work; inert original-reference and
response comparisons. The actual app/helper must compile. No fixture may invent
signed authentication or successful SecItem access. Installed signed recovery,
locked/denied Keychain behavior and account lifecycle remain host qualification.
