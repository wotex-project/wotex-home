# Native MQTT setup and Keychain bootstrap

Version: 0.1.3. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 native setup/lifecycle, WOH.16 private delivery, WOH.18 source custody.
Implementation: NM-01/02/03 software implemented; NM-04 preparation/import/publication
UI planned. Evidence: [focused software checks](../provenance/native-mqtt-bootstrap-2026-10.md);
positive installed signing/Keychain and physical qualification missing.

## Result and separation

The native Setup surface can validate/publish explicit private authoring and
MQTT source files, import one supplied broker credential into a dedicated
non-synchronizing Keychain account, and start the normal fixed Core child with
that credential over its original anonymous pipes. No broker password enters
argv, environment, a source file, Store/profile backup, public API or UI status.
This extends [private source installation](private-mqtt-installation-v1.md);
existing none/password-file modes and unsigned development behavior remain.
Home operator-role bearers and MQTT username/password custody are distinct.

There is no arbitrary Keychain query, executable, eval, group, HTTP route or
credential-delivery socket operation. Public WPF and MQTT own decoding; Store
still owns profile trust/current target/grants/observations. Loading a source
or Keychain item grants no target or physical authority. Installed signing and
positive Keychain/account isolation require real signed artifacts; fixtures
cannot manufacture a signed access seal or successful installed evidence.

## Inputs and native custody

**NM-01 — Exact source scope.** Add the JSON authentication string keychain to
the existing closed MQTT connection grammar. It requires verified TLS. No
credential selector/path/account is accepted in JSON. The Keychain account is
mqtt.<sha256> where sha256 is lower hex64 of the exact sealed raw MQTT source
file, including endpoints, CA/name policy, capture and channel policy. A changed
byte selects a different account; old credentials are never guessed or migrated.
The native app publishes only into its fixed canonical private Home root, and
the agent uses that same root. Authoring policy remains an independent sealed
startup witness. None/password modes retain their existing exact behavior.

The fixed Keychain service is org.wotex.home.mqtt.v1. Use the data-protection
generic-password implementation, synchronizable=false, accessibility
WhenUnlockedThisDeviceOnly, a noninteractive operation-local LAContext, and the
dedicated exact access group <actual Team ID>.org.wotex.home.mqtt.v1. Both app
and agent require actual valid fixed Developer ID self metadata, hardened policy
and that explicit entitlement alongside their preexisting exact own-role group
(needed for Home's separate operator custody). The explicit access-group array
contains exactly those two distinct groups, in either order; no additional,
duplicate or broad Team group is accepted. Legacy operations without MQTT may
retain their existing own-role-only entitlement. Actual-self checks mint the
private access seal; inert metadata fixtures cannot mint one. Repeat current
actual-self/group/bundle identities before and after every SecItem operation.

The stored value is the canonical private credential document from MI-02:
format, username and password_base64, at most 8192 bytes. Username is UTF-8
1..128 without U+0000; decoded password is binary 1..4096, canonical padded
base64. App import is explicit, add-only and rereads the item; identical existing
bytes succeed, different/malformed bytes refuse custody_conflict. Agent startup
is read-only. Missing, locked, denied or unavailable custody fails closed; no
prompt, generation, plaintext-file fallback, update/delete or second account.
Secret wrappers redact description/debugDescription/reflection.

## Parent-to-Core bootstrap

**NM-02 — One bounded initial exchange.** Only the installed, protected signed
agent supplies the fixed nonsecret child flag WOTEX_HOME_NATIVE_MQTT_BOOTSTRAP=1
through NativeCoreEnvironment. Existing pipe identity, executable/bundle seal,
same actual child and close/reap checks remain. Development does not set it.
The flag enables a startup protocol; it is not signing evidence or a secret.
Only the original trusted native parent is authorized to answer its private pipe.

Before Store/socket acquisition, the child starts required dependencies and
selects/reconstructs the exact authoring/MQTT source. For keychain mode it
requests only that source's raw digest. For absent/none/password policy it sends
none and requires the corresponding none reply; the native parent performs no
Keychain operation. Four-byte unsigned big-endian frames contain exactly:

```
["wotex-home.native-mqtt-bootstrap@1","none"]
["wotex-home.native-mqtt-bootstrap@1","credential",source_sha256]
["wotex-home.native-mqtt-bootstrap@1","credential",source_sha256,username,password_base64]
```

The request is 1..4096 bytes, reply 1..8192 bytes, flat canonical compact JSON,
UTF-8, exactly two/three/five members as shown. No Boolean/float/unknown/nested/
duplicate/trailing representation or altered digest. This larger ceiling applies
only to this one bootstrap reply; ordinary core/broker frames stay at 4096.
Use one original five-second monotonic exchange deadline, bounded reads/writes,
original anonymous descriptors and no retry/replacement child after failure.
The parent obtains the item from the actual Keychain gate only for a valid
credential request, then sends the canonical response and drops its temporary
secret. Keychain locks/denial/missing item terminate startup without a raw error.

**NM-03 — One transient credential capability.** The child validates the reply
against the exact selected source digest/seal and creates one linked private
credential owner. Its unforgeable reference binds that source witness and the
native-parent Core process. The owner holds the decoded pair only until the
publisher's one resolution or a maximum 30 seconds, whichever comes first.
Public status/OTP diagnostics redact its state/messages/reasons. Check operations
validate the reference without consuming or exposing the secret; resolution
consumes exactly once. Wrong reference, expiry or owner loss refuses. There is
no durable second journal or global credential/application-env cache.

Pass that native capability through the Application start arguments to Host,
never OS environment or ordinary API fields. Host's MQTT loader rechecks the
same sealed source/authoring and complete prepared basis before resources and
attachment. Only a capability for that exact raw digest/seal is accepted.
Ordinary Application startup with keychain policy but no native capability
refuses mqtt_native_credential_required before Store/socket. Existing none and
password-file modes ignore an unused capability and never choose Keychain.

Actual EMQTT/TLS still sends CONNECT credentials only after verified chain/name
and disables session reuse/tickets. Publisher/source/report/Store loss remains
terminal. A full new Host/native parent needs fresh sealed policy and a new
bootstrap; a Store-child restart cannot reuse the consumed capability or reconnect.
Closing the parent channel stops/reaps only its own Core and private owner.

## Native setup interaction

**NM-04 — Explicit preparation and publication.** Setup shows a local MQTT
section, unavailable for a selected remote controller. The operator selects
private mode-0400 source documents through file panels; private descriptor/seal
checks precede use. Validate against the actual bundled producer through a fixed
foreground entry before presenting a prepared digest/channel/authentication
summary. No file/profile-supplied executable or module is launched. The app's
actual protected signed bundle gate derives the fixed bundled release path.
No arbitrary environment is inherited, and foreground diagnostics are bounded
and sanitize raw input/foreign error text.

Publication is an explicit second action against that exact prepared source
and the same local selection/root. Authoring and MQTT publication use the MI-05
immutable writers, not Swift copies of the WPF compiler or file codec. The
foreground entry starts required dependencies, no Host, and holds the existing
same-host advisory gate while publishing to refuse an active Store. It does not
open home.sqlite, register a service, select a target or contact a broker.
Identical publication returns the same safe summary; a different destination
requires explicit stopped-host owner replacement and refuses overwrite here.

For keychain mode, Import Broker Credential reads a separately selected private
credential document only after the source is prepared and unchanged. Show no
password/digest of secret. Recheck source, local selection and actual signing
gate immediately before import. Import persists the exact source-scoped item,
then source publication becomes available. Clear temporary secret content after
success/failure. Repeated clicks cannot queue concurrent child/Keychain work.

Changing file/controller/session selection or losing source/bundle identity
invalidates preparation; a late completion cannot publish for a new selection.
All actions share the application's busy/session-change fencing. A cancelled
file panel has no effect. A lost publication reply is uncertain: retain exact
prepared source and permit only identical retry, which uses immutable file
lookup first. Never silently restart a Host or fall back to password-file/manual
custody. Explain that starting/restarting the background controller creates a
new source epoch and current target reselection is still required.

**NM-05 — Closed foreground protocol and original publication.** The app's
actual-self protected-bundle gate derives only
Contents/Resources/WotexHomeRelease/bin/wotex_home. Launch arguments are exactly
eval and WotexHome.NativeSetup.MQTTProvisioning.main(); no selected document
chooses arguments, environment or code. Pin the actual app/bundle identity for
preparation and recheck it before/after each later action. The fixed actual
OS-user private Home root is the only destination. Root creation is an explicit
setup action; neither Host nor home.sqlite is opened by the foreground entry.
Start only locked required dependencies and route Logger to stderr.

One original 15-second monotonic deadline covers launch, request, producer work
and reply. Four-byte big-endian frames contain 1..4096 bytes of canonical compact
UTF-8 JSON. One request and response only; no retry/replacement child after
failure. Paths are absolute canonical UTF-8, 1..1024 bytes, no NUL, checked through
PrivateFile's mode-0400 single-link/ancestor/descriptor witness. Paths travel
only on the original private pipes, never in status or diagnostics. Records are:

```
["wotex-home.native-mqtt-provision@1","prepare",authoring_path,source_path]
["wotex-home.native-mqtt-provision@1","publish",authoring_path,source_path,authoring_sha256,source_sha256,basis_sha256,root_sha256]
["wotex-home.native-mqtt-provision@1","prepared",authoring_sha256,source_sha256,basis_sha256,root_sha256,channels,authentication]
["wotex-home.native-mqtt-provision@1","published",authoring_sha256,source_sha256,basis_sha256,root_sha256,channels,authentication]
["wotex-home.native-mqtt-provision@1","error",reason]
```

Digests are lower hex64. Channels is integer 1..32; authentication is exactly
none/password/keychain. Reject nesting, unknown/extra members, Boolean/float,
noncanonical/trailing encodings and mismatched original replies. Only selected
file digests/channel count/authentication are presentation data; opaque basis
and root digests remain private correspondence. Root digest is SHA-256 of
deterministic Erlang external-term bytes of the tuple containing the binary
tag wotex-home.native-mqtt-root@1 and PrivateFile.directory_witness(root).
Basis digest uses the tuple of binary tag wotex-home.native-mqtt-basis@1,
root_sha256, authoring_seal, source_seal, authoring_sha256 and source_sha256.
These internal same-release witnesses are not public producer identities or
authority grants and cannot be used across an app/release replacement.

Preparation reconstructs both actual installed-producer contracts from the
selected documents, rechecks every original witness and refuses a different
existing destination before offering import. It writes no policy, acquires no
Host gate, starts no Host and contacts no broker. Password mode requires the
existing separately provisioned password-file custody at publication; no
conversion to Keychain or alternate account is available.

Publication first rechecks the root witness, acquires HostLock for the exact
fixed home.sqlite path (creating only its separate owner sidecar), then checks
installed authoring/source files before rereading caller sources. If both are
sealed, match the original raw hashes and reconstruct the same producer summary,
return that original published result even if caller files disappeared. This
is confirmation, not permission to publish changed sources. Otherwise both
destinations must be absent or identical, and source seals/hashes, root and the
complete rebuilt summary must still match the prepared original. Recheck before
each MI-05 immutable writer; publish authoring first, MQTT last. The two files
are not one transaction. Failure after publication begins may leave inert
authoring policy installed; never delete another publication or claim rollback.
Return native_mqtt_publication_uncertain and retain the original for explicit
identical retry. No automatic retry, overwrite or restart. Release the gate and
perform bounded child cleanup on success/failure.

Foreground errors are exactly invalid_native_mqtt_provisioning,
native_mqtt_source_changed, native_mqtt_publication_conflict,
native_mqtt_host_running, native_mqtt_publication_uncertain and
native_mqtt_provisioning_unavailable. Before a possible write, a valid closed
error is a definite refusal. Lost/late/malformed reply after publication may
have started is uncertain. An uncertain original cannot be replaced by a new
file/controller selection; permit only its identical local retry. Source drift
or destination conflict during that retry retains uncertainty for explicit
stopped-host owner reconciliation. Changing selection invalidates ordinary
preparation; a late completion never becomes preparation for another selection.
All actions share the process-wide busy/session guards.

## Failures and acceptance

Elixir fixed additional errors: mqtt_native_credential_required,
mqtt_native_credential_unavailable and invalid_native_mqtt_bootstrap. Existing
private-file/publisher/producer errors retain their fixed owning atoms. Native
UI maps signing, custody, conflict, unavailable, expired and uncertain failures
to bounded messages; raw foreign terms, secrets, source bodies and paths are
never logged. A failed signed/protected installation cannot become development.

| Case | Requirements | Independent stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NM-T1 | 01/02 | Literal request/reply vectors, boundaries/alternate encodings/digest changes; old ordinary frame ceilings remain. Leak, widened parser or changed original fails. | Pure/pipe |
| NM-T2 | 02/03 | Actual Core/Host/SQLite/TLS through controlled parent pipe; keychain policy without capability, changed source, consumed/expired/owner-lost capability and parent EOF fail closed; no persisted credential or reconnect. | Process/socket |
| NM-T3 | 01 | Inert query/group policy plus actual unsigned refusal before SecItem. Real signed app/agent, locked/denied/missing/conflicting item and account isolation are separately required. | Pure/unsigned; signed pending until executed |
| NM-T4 | 04/05 | Native preparation/import/publication state machine, invalidated selection/late reply/concurrent click, exact uncertain retry, partial authoring publication, changed seals/root and active Store refusal. Render/inspect UI; actual selected private documents and producer validate. | Swift/foreground/filesystem |
| NM-T5 | 02/04/05 | Protected bundle/current peer/child pipe drift, fixed executable/environment, bootstrap/foreground deadlines and shutdown/reap. Unknown result never becomes installed success. | Process; installed lifecycle separate |

Freeze literal bootstrap vectors before code. Full-suite/Dialyzer, assembled
signed release, fresh-account registration, positive Keychain/profile ownership
and physical device/sample-age qualification remain milestone evidence. None
can be inferred from compilation, inert policy, scripted parents or unsigned UI.
