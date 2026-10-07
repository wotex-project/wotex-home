# macOS development bundle

From a clean Home source tree, assemble and inventory the production OTP
release, then run `mix woh.macos.app.assemble [RELEASE_PATH]` from the repository root.
Omitting the path selects `_build/prod/rel/wotex_home`. For the fresh build
produced by `elixir bin/build.exs --dependency-env test`, pass the printed
release path directly; assembly verifies that its inventory matches the current
source commit before replacing the development app.
For local LIFX metadata testing, run `mix woh.lifx.registry.fetch`
before building the release; the fetched registry remains outside Git.
The result is `_build/macos/WotexHome.app`. XcodeGen also creates an ignored
`WotexHome.xcodeproj` for further native development. The assembly script uses
the installed Command Line Tools Swift compiler and produces an unsigned,
arm64 development bundle.
Each scripted Swift compilation uses a private temporary module cache rather
than requiring write access to a global Clang cache. Compiler cache files are
removed with the build scope and are not included in the app inventory.
The assembly writes an unsigned file inventory for the complete app bundle.
Run `mix woh.macos.app.inventory verify _build/macos/WotexHome.app`
to check the outer bundle and its embedded OTP release inventory.
It also writes a file-level SPDX 2.3 JSON document for the full bundle;
run `mix woh.macos.app.spdx verify _build/macos/WotexHome.app` to check it.

The SwiftUI window uses `SMAppService.agent(plistName:)` to register or remove
the bundled per-user agent. Its status shows registration eligibility, not
verified controller health. The agent derives its private Application Support
directory from the OS user record and owns the bundled OTP child through its
original private pipes. It installs signal ownership before launch and retains
a stop request during startup. Closing the window is independent of the
registered agent. No registration or signing is performed by assembly.
The helper is an app-like bundle at
`Contents/Library/LoginItems/WotexHomeAgent.app`; the unchanged LaunchAgent label
uses that full relative BundleProgram and a ten-second failure throttle. Inner
identifier, executable, package type, minimum OS and source revision are checked
by the app inventory, with the helper covered by native/SPDX checks.
Actual ad-hoc self metadata selects the development entry, with manual ordinary
custody and no setup listener. A signed installation must pass the protected
bundle/private-group gate before brokerage; failure cannot become development.
Both entries construct the closed environment and terminate/reap their original
child. Profiles, signing, notarization and protected installation remain separate
from unsigned assembly.

The window can import a trusted local operator credential into a non-syncing
generic-password Keychain item and read authenticated health, scoped Thing
catalogue and current-observation views at one Store watermark.
It can also look up one scoped durable operation receipt by authority epoch and
operation ID; an unknown outcome remains visibly uncertain.
An enrollment operator can look up a review reference and see whether its
binding is current, superseded or revoked. This lookup cannot enroll a device.
It displays current operator overrides for granted Things with Store-timed
remaining life. A control credential can issue a 15-minute lease, keep its
operation ID for status lookup after an uncertain reply, and revoke its own
current lease. These controls do not run an automation or change a device.
For an authorized writable Light, Stage On and Stage Off submit a typed power
request through the same local API. The window retains the generated operation
ID for status lookup and displays the durable receipt. A held receipt records
staging, not a device effect; the development host still has dispatch disabled.
The operation view can cancel held or still-queued work by its original ID.
If cancellation is uncertain, look up that ID before taking further action;
claimed or handed-off work cannot be recalled from this control.
The rule policy view reads the current generation and active, inactive or
suspended state. An authorized rule manager can suspend the current policy
using the displayed Store revision and authority epoch. The view retains the
operation ID for an uncertain response and can look up an original admission or
activation receipt. Activation counts describe the barrier at commit time;
they do not claim to recall a packet already handed off. The explicit-rule panel
edits one absolute Light power action. Screening, admission, activation,
invocation and suspension each require a separate reviewed confirmation.
An invocation returns an ordinary staged request ID for receipt lookup; it
does not establish a device effect. Draft edits invalidate a prepared decision.
It verifies the private socket path and same-user peer before sending the
credential. The host checks the caller's kernel peer UID before reading a frame.
The native socket client uses one monotonic five-second deadline across
connect, send and receive; a slow response cannot reset that deadline.
The returned counters describe the Store, not physical device
health. Run `mix woh.native.health.smoke` to check the native frame and
response handling against an independent socket peer. Run
`mix woh.native.snapshot.smoke` and
`mix woh.native.read.view.smoke` for independent paging fixtures.
The read-only `thing-current THING_ID` CLI uses the
[current Thing inspection](../../docs/specs/thing-current-v1.md) route. It retains
complete declaration and original report provenance, separates stored from
current values and derives freshness from the Store's own receipt clock.
Missing, synthetic, expired, prior-boot or unavailable-profile evidence stays
unknown. This read does not probe a device or qualify control.
Run `mix woh.native.receipt.smoke` for receipt lookup and cancel fixtures.
Run `mix woh.native.enrollment.smoke` for the scoped enrollment status fixture.
Run `mix woh.native.power.submit.smoke` for the typed mutation fixture.
Run `mix woh.native.overrides.smoke` for the scoped override fixture. Run
`mix woh.native.override.mutations.smoke` for issue/status/revoke fixtures.
Run `mix woh.native.rule.smoke` for closed rule status, suspension and
principal-private operation lookup fixtures, including malformed responses.
Run `mix woh.native.rule.operation.wire.smoke` for the separately closed explicit
rule input codec, independent cross-language digest and complete source vectors.
It cannot review, admit, activate or invoke a rule by decoding an input.
Run `mix woh.native.rule.client.smoke` for fifty-four independent current-source, preview,
recorded-review, admission, activation, invocation and complete-original lookup
SDK cases. Result identity and digest checks leave missing or malformed results
unconfirmed; these socket fixtures create no device or installed custody.
The shared pending journal now supports the separately versioned
[v3 explicit-rule records](../../docs/specs/native-pending-custody-v3.md).
`mix woh.native.pending.codec.smoke` covers exact rule inputs and unchanged older
records. `mix woh.native.pending.storage.smoke` covers v2-to-v3 publication and
a competing process race without discarding existing power/access originals.
The existing fixed file/lock paths remain one journal; load sends no request.
The read-only `rule-current` CLI and native SDK return the exact retained explicit
source under current management permissions and target grant. Explicit refresh
lets the native panel review retained active policy after restart before a
separate invocation decision. The separate `rule-original-status
ORIGINAL_FILE` CLI verifies a private canonical input file before original lookup.
Run `mix woh.native.rule.panel.smoke` for twenty-two actual private-Store
model/shared-recovery workflows. They cover all four original operation kinds,
lost and unsent replies, missing results, later revocation, definite first
refusal, edited drafts, changed custody/controller, publication failure and
three-process recovery followed by invocation of the retained active source.
Publication verifies the original credential bytes and full controller identity
before mutation. Recovery always uses the retained source rather than an edited
draft. Window load performs no lookup, retry or mutation. The task renders
`_build/native/rule-panel-preview.png` and its `-unconfirmed.png` companion;
these ordinary private fixtures open no Keychain and qualify no signed host or
physical device.
Run `mix woh.native.maintenance.smoke` for authenticated maintenance status,
begin/end, closed receipt validation and a lost response followed by exact retry.
Run `mix woh.native.maintenance.panel.smoke` for twenty-four actual private-Store
model/shared-recovery journal workflows: begin/end original lookup/retry after lost replies or unsent
requests, repeated refusal after revocation, changed status credentials and
definite first refusal. Publication precedes the exact mutation and durable
removal precedes unblocking new work; two windows share the original guard.
The task renders `_build/native/maintenance-panel-preview.png`. It uses ordinary
temporary custody supplied on stdin and opens no Keychain or hardware driver.
Run `mix woh.native.profiles.smoke` for all nine closed profile routes, exact
operation hashes, identity/diff/status fields, malformed results and lost-reply
recovery. The live CLI parity task also compares profile import, approvals,
revocation, catalogue/target reads, original receipts and collection.
Run `mix woh.native.setup.peer.smoke` for the closed Developer ID requirement,
hardened-runtime entitlement checks, real kernel socket audit-token capture and
unsigned setup refusal. The private seal expires at its original five-second
deadline. Both native build commands include this gate. The actual agent opens
setup only after its separate signed/protected installation checks; unsigned
development opens no setup listener. Signed pair success and Keychain custody need
the installed checks in [the peer contract](../../docs/specs/macos-signed-peer-v1.md).
The trusted core now supports [owner-scoped native setup roles](../../docs/specs/native-setup-authority-v1.md):
four fixed roles, no initial Thing grants, verifier-only provisioning and the
original creation receipt on unchanged retry. The ordinary socket rejects these
operations. The private channel, custodian and agent composition are implemented;
explicit app setup presentation is implemented; signed installed evidence remains separate. Manual
development credential import remains available.
The [private core channel](../../docs/specs/native-core-channel-v1.md) is now
implemented with the fixed release entry `eval WotexHome.NativeSetup.CoreHost.main()`.
It owns binary stdin/stdout, pins the original Store, bounds every frame and
decision, keeps diagnostics on stderr and stops its own Host on pipe loss.
Real child-pipe checks cover original receipt recovery across restart, oversized
and dripped frames, EOF and lock/socket release. The agent now owns those pipes;
signed installed Keychain delivery still needs its own evidence.
Run `mix woh.native.setup.wire.smoke` for independent canonical core and broker
records, original receipt identity checks and malformed/bounded parser cases.
These inert fixtures open no Keychain and authenticate no peer. The
[credential broker contract](../../docs/specs/native-credential-broker-v1.md)
keeps installed agent custody and delivery separate from wire evidence.
Run `mix woh.native.core.pipe.smoke` for the native child owner against an actual
Home core and adversarial pipe children. It checks exact original receipts after
restart, private Host socket cleanup, excluded environment overrides and
bounded failure/capacity cases. It also checks actual native-parent SIGTERM and
SIGKILL loss, Host cleanup and no development provisioning. It opens no setup
listener or Keychain item; installed launchd lifecycle remains a separate check.
Run `mix woh.native.keychain.policy.smoke` for inert private-group queries,
noninteractive authentication context, epoch account separation and typed errors.
It performs no SecItem operation or account change. The actual agent-only
custodian requires an OS-derived signing seal; installed profile authorization,
locked/denied behavior and isolation still require signed-artifact checks.
Run `mix woh.native.broker.socket.smoke` for actual private socket ownership,
bounded framing/deadline checks, replacement/cleanup refusal and unsigned setup
rejection before core calls. Its separate inert transport cases authenticate no
peer. It performs no SecItem operation and cannot qualify installed brokerage.
The app broker client is implemented with the original signed peer/deadline and
closed replies. The same socket fixture checks its unsigned refusal for status
and all four roles, no request bytes, listener survival after disconnect and
kernel peer identity retained through reply/EOF. Actual signed app delivery and
installed session delivery remains a separate check.
The [native Core peer boundary](../../docs/specs/native-core-peer-v1.md) is
implemented for every native ordinary API request. A read-only signed endpoint
lease attests the agent's original Core child; its kernel token must match the
app's connected ordinary socket before any credential frame. The app retains
and rechecks that broker connection through the response under the original
request deadline. Setup and existing recovery register an immutable required
guard; selecting manual custody cannot downgrade a known native hash.
The wire fixture checks endpoint records and malformed tokens/scopes. The Core
pipe fixture checks actual child correlation, restart token change and a
same-user replacement endpoint receiving no data. The broker socket fixture
checks unsigned endpoint refusal and missing/failing native guards with no
ordinary bearer bytes. These checks open no Keychain and do not qualify signed
delivery.
Original native custody recovery is implemented as a separate signed request
under [its closed contract](../../docs/specs/native-original-custody-v1.md).
It reads an existing exact role item and creation receipt without ensuring a
principal or creating a Keychain item. The wire fixture checks literal recovery
records and original verifier/receipt/scope matching. The Core pipe fixture
checks read-only lookup across an actual child restart, and the socket fixture
checks unsigned recovery refusal before request bytes/Core/Keychain work.
Recovery does not select a session or resend an operation. Persistent pending
operation composition and actual signed delivery retain their own obligations.
The [Home session panel](../../docs/specs/native-session-presentation-v1.md)
explicitly selects Diagnostic, Operator, Maintenance or Transfer custody.
Check Setup does not select a role. The selected native secret stays in memory;
End Session leaves no credential selected, and Use Manual Credential explicitly
chooses the existing manual item. No native secret is written to that item.
Device grants remain a separate required step. Session metadata uses the
original creation receipt; a fresh setup status supplies the current revision.
Health, maintenance and profile models are shared across windows. Busy or
unresolved work blocks selection/import/end; role changes clear scoped views.
Health mutations retain a bounded original credential and exact typed request
for lookup or Retry Original. Missing receipts and failed retries retain it.
Run `mix woh.native.session.panel.smoke` for memory transitions, actual unsigned
refusal and `_build/native/session-panel-preview.png`; it opens no Keychain.
Run `mix woh.native.session.operations.smoke` for thirty-four actual private-Store
model/shared-recovery lost-reply and unsent-request workflows. Committed
retries create no new revision, and another principal cannot read the receipt.
These checks establish neither installed signed custody nor device effects.
Health mutations now publish their exact original and custody verifier in the
private journal before delivery. These same Store workflows check publication,
two windows sharing its guard and durable removal before enabling new work.
Startup loads private records before session/mutation controls; it performs no
automatic custody or API work. Check Setup can report the authenticated current
owner while originals remain unresolved, without automatically replacing the
selected credential. The pending panel offers explicit original lookup/retry and held-review
cancellation through existing custody and authenticated original identity.
The cancellation/revocation cases include lost actual not-found replies:
original lookup, exact retry and the same mutation control retain the original
without a revision or replacement input. A missing retry result cannot release
the session/operation guard.
`mix woh.native.pending.codec.smoke` checks the independent closed
[pending-operation records](../../docs/specs/native-pending-custody-v1.md),
original custody/context matching, fixed profile phases, category uniqueness
and parser/capacity bounds. It performs no file publication, API call or
Keychain work; persistent journal and recovery composition remain separate.
`mix woh.native.pending.storage.smoke` checks private journal file publication,
revision/content/inode CAS, unchanged records, original profile phase guards,
durable resolution, unsafe paths/files/locks and capacity. Separate processes
exit before/after publication and read the original after restart; competing
publishers retain one original without overwriting the other. Network choices
keep their separate document and lock. These fixtures send no API/device
requests and open no Keychain. Persistent storage is implemented; app operation
and recovery composition remain separate work.
`mix woh.native.pending.coordinator.smoke` checks authenticated original capture
and publication against a real private Store, before any mutation. Separate
client processes recover a discarded committed reply by original lookup or
exact retry without adding a Store revision. Changed snapshot credential and
epoch refuse publication, and startup reads without capture or automatic API
work. The fixture uses ordinary private credentials supplied on stdin; it opens
no Keychain and establishes no signed custody. Model/UI composition follows
the implemented coordinator. The same task exercises the typed recovery
entry point across process restart, wrong verifier and mismatched principal.
The health task renders `_build/native/pending-panel-preview.png`.
The explicit native picker, private record/file layer and child startup for
[native network preferences](../../docs/specs/native-network-preferences-v1.md)
are implemented. Refresh Interfaces reads local OS inventory; choose a network
or Disabled, Save for Next Start, then explicitly stop and enable Home to apply
it. Saving never reconfigures the running child. Discover Devices remains an
authenticated read-only action in the profile panel. No choice enables physical
dispatch. Missing configuration defaults to disabled; malformed or unavailable
configuration refuses startup without an inherited fallback.
`mix woh.native.network.preference.smoke` checks canonical
records, bounded private reads, atomic revision/inode compare-and-swap, lock
capacity, unsafe path/file refusal and the exact default/selected child
environments without packets. `mix woh.native.network.inventory.smoke` checks
independent scope/packed-mask cases and actual agreement with the OTP inventory.
`mix woh.native.network.panel.smoke` checks explicit selection, pending guards,
window conflict and interface disappearance, and renders
`_build/native/network-panel-preview.png`. The core-pipe fixture checks that an
original child retains its first environment after a later preference save.
App/helper usage descriptions are required by packaging inventory. Actual
signed service attribution, OS allow/deny/revoke and device reachability need
their installed/physical evidence; these software fixtures do not supply it.
The maintenance panel uses its own status read, so a maintenance-only credential
needs no ordinary-control or Thing grants. It retains the original request and
credential in memory for an uncertain lookup/retry and disables new changes
until that request is resolved. Copy the displayed epoch/operation ID before
quitting the window; client-side recovery across UI restart is still pending.
Current status and historical receipt counts remain separate, and end leaves
rules suspended. The panel does not install an update or restore a controller.
Credential provisioning
and signed app identity are still required for installed use.

For a foreground development host before hardware enrollment, stop any
running Home host and run
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/bootstrap_health.exs`
from the repo. It prints a one-time read-only credential for Keychain import;
run it in a private terminal, without putting the credential in shell arguments.
The same directory must then be used by the background host. A second run
cannot mint another copy of that principal. This is a development bootstrap,
not the installed credential broker. Run `mix woh.bootstrap.health.smoke`
to verify the one-time behavior without displaying a real secret. Run
`mix woh.native.live.host.smoke` to check the compiled Swift client
against an actual foreground Home host using that credential over standard
input, without showing or logging it.
Run `mix woh.native.cli.parity.smoke` to stage one held fixture request
through Swift, read and cancel its receipt through the CLI, then read the
terminal receipt through Swift against one live private host. It also suspends
rules through Swift and compares the immutable activation receipt and current
policy with the CLI against that same host. No fixture sends a device packet.
It also begins and ends maintenance through Swift, compares the exact receipts
and current status with the CLI, checks held-work invalidation and blocked new
staging, and rereads the unchanged original begin receipt after end.

Before installed use, the bundle still needs Developer ID signing,
notarization, entitlements, signed installed broker and peer-identity checks,
registration/approval tests, and lifecycle tests under a fresh account.
`mix woh.macos.native.deps.check _build/macos/WotexHome.app` checks
the direct Mach-O load paths and deployment minima in the assembled bundle;
assembly runs it before writing the app reports. The declared minimum is macOS
15.0 because of the packaged OTP/NIF closure. A fresh macOS 15 account still
needs an installation and runtime check.

For trusted foreground development maintenance, stop the host and run
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/bootstrap_maintenance.exs`
in a private terminal. It prints the fixed maintenance credential once; protect
it in a private credential file for the CLI or import it through the existing
Keychain control for the native maintenance panel. This principal has no device-control
permission or Thing grants. `maintenance-status` supplies the current epoch and
Store revision for `maintenance-begin EPOCH OP EXPECTED`. Beginning suspends rules
and persists the request barrier across restart. Inspect the original operation
with `maintenance-operation-status EPOCH OP` after an uncertain reply, and create
and verify the consistent backup through trusted local custody.
`maintenance-end EPOCH OP EXPECTED BEGIN_REVISION` permits new requests while
leaving rules suspended. These commands never install an update or restore a
controller; signed installation and fenced recovery require their own workflow.

## Development component worker

The optional [WIT worker](../components/README.md) is built separately from the
app/OTP release. Only an explicit trusted runner path enables import-free pure
previews; it neither probes the LAN nor changes profile/dispatch admission.
Do not copy this binary into an inventoried bundle: native closure, legal inputs,
JIT/interpreter strategy, signed entitlements and installed retirement tests
must first be integrated into assembly and qualified under WOH.08/17.

The [portable profile plan](../../docs/plans/portable-profile-admission.md) places
data-only delivery before optional helpers. No native runtime is needed for
data admission. Its future installed-host checks must cover private immutable
publication/synchronization, missing dependency health, offline local approval,
retained backup objects and quarantined restore. The shared CLI now imports bounded profile bytes and performs explicit local
approval, preparation and selection through the private Authority socket.
Maintenance commands remain separate from profile changes.

The opted-in Home host now owns `profiles/` beside its SQLite Store, using an
existing private 0700 data directory. It resolves `/var`/`/tmp` and other directory
aliases to a canonical physical path before Store startup. Only after Store has
acquired ownership does it create/open the private immutable profile namespace
and transient one-use review owner. Existing nonprivate/symlink profile roots
are rejected without changing them. Restarts discard pending reviews and stop
downstream workers; retained approved bytes and Store history remain separate.
Public profile commands and native presentation are implemented. These host fixtures do not establish installed app custody or disk
power-loss behavior.

Trusted foreground profile setup uses `mix run bin/bootstrap_profiles.exs manager`
or `operator` with the existing opted-in host/data-directory environment. Import
the printed credential into a private 0600 CLI file or native credential custody;
never put it in arguments. Manager has only profile management; operator adds
enrollment review and has no targets, maintenance, control or qualification.
`profile-import`, `profiles`, `profile-target`, `profile-prepare`, `profile-change`,
`profile-operation-status`, `profile-review-status`, `profile-review-cancel` and
`profiles-collect` share the [closed route mechanism](../../docs/specs/portable-profile-api-v1.md).
Artifact and operation input files are descriptor-checked private 0600 regular
files; local paths never reach the server. Use original receipt status after an
uncertain change; exact preparation retries recover pending tokens without
renewing evidence. Installed brokerage and storage qualification still need their checks.

The portable-profile Swift client and window panel are implemented. The independent peer check and live CLI comparison use disposable fixtures
and enable no physical dispatch. Response parsing rejects duplicate decoded names
and excessive nesting before Foundation allocation. Actual installed Keychain and storage acceptance still require their owning
checks. The panel imports bounded JSON through the native file picker, displays
prior/captured identity and capability changes, and requires an explicit identity
review before selection. It retains exact inputs and the original credential
while a result is uncertain, disables new changes and supports original scoped
lookup or retry. Expiry never renews evidence; a vanished proposal requires
resolution of its original operation. Pending client custody remains in memory.
Run `mix woh.native.profiles.panel.smoke` for eight real Store/capture workflows:
happy path, lost approval/preparation/selection/cancellation, expiry and missing
bytes, plus a lost committed approval followed by original-principal revocation.
Failed retries retain the original credential and inputs; expiry or a vanished
review keeps new work blocked until resolved. The host capture is scripted and sends no device packet; the fixture
changes no Keychain item. It renders the populated review panel to
`_build/native/profiles-panel-preview.png` for layout inspection.

## Trusted portable-profile recovery

Run these shared development commands from the Home repository root.
Stop the existing controller before taking ownership in a foreground Mix process.
With the same private data directory selected,
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/recovery.exs export /absolute/archive.backup`
exports an encrypted consistent database plus every retained exact profile byte.
Supply the 32-byte key as exactly 43 unpadded URL-safe Base64 characters plus LF
through stdin from separate trusted custody. Never put the key in arguments,
environment, logs or beside the archive. Export fails if any retained byte is
missing/corrupt; it does not substitute another version or copy inert orphans.

Offline `mix run --no-start bin/recovery.exs verify /absolute/archive.backup`
reports validated history and exact included/external dependencies.
`mix run --no-start bin/recovery.exs stage /absolute/archive.backup /absolute/new-directory`
uses the same stdin key and creates a new directory under an existing canonical
private 0700 parent. It never overwrites existing content. The result contains
0400 immutable objects under `profiles/` and 0600 `home.sqlite`, already marked
as restore quarantine. A database-only archive with portable dependencies
cannot claim complete byte transfer. Verification/staging do not start Home.

Do not point a controller at this directory or remove its quarantine marker.
Store refuses startup. Fenced activation still requires old-writer isolation,
credential/authority review and radio-counter continuity; those requirements
are separate from the byte-transfer check. Registry metadata, qualification
packages/reviewer keys and device credentials/counters remain external.

For an explicit source transfer, first provision separate transfer custody with
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/bootstrap_transfer.exs`.
It grants only `host:transfer`, with no maintenance or Thing grant. Preserve its
secret in separate private custody. After an authorized maintainer begins the
existing maintenance barrier, run
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/recovery.exs retire-export EPOCH OPERATION_ID EXPECTED_REVISION DESTINATION_OWNER_ID /absolute/archive.backup`.
Supply two stdin lines: the original transfer credential, then the archive key,
each as the 43-character encoding plus LF. Review the chosen destination owner
and current watermark explicitly. The command permanently retires the source,
verifies complete receipt/byte correspondence in the archive, then stops its
owning Host supervisor. Failed export leaves the source retired and inactive.

After interruption, use
`mix run --no-start bin/recovery.exs export-retired /absolute/canonical/source-directory /absolute/archive.backup`
with only the key stdin line. It starts an isolated retired Store/custody reader
under the existing lock, with no socket/device worker or migration, and closes it
after export. A complete matching existing archive is an exact retry; wrong
keys/archives are refused without replacement. Hash/size refer to the exact
authenticated archive bytes. This source delivery does not activate a destination
or establish physical old-writer isolation. Signed installation, fresh-account
background-service behavior and the actual isolation procedure remain separate.

An assembled OTP release also ships `bin/wotex_home_recovery`; use the same
command arguments/stdin custody without Mix or this checkout. Its
`new-owner /absolute/private/operator-custody/owner.json` provisions destination
owner custody before source retirement. Its parent must already be canonical
and 0700; the immutable 0400 file stays outside the arrived archive/restore
directory. The returned public `owner_id` is the explicit retirement destination.
This command takes no stdin key and starts no Home service. Existing custody is
never overwritten. This identity alone cannot activate a restore.

`bootstrap-transfer` supplies a separate one-time credential in a foreground
private Host. After an accepted transfer it derives a fresh role from the current
ownership epoch; it never revives the copied revoked source role. A repeat in
the same epoch returns `principal_exists` without redistributing a secret.
Run `--help` without a credential to inspect the closed
command set. Stop the installed background service before a foreground recovery
process takes its data lock; offline commands start no normal Host.

The shared trusted in-process receiving session is now available through
`WotexHome.Recovery.Destination`. Its constructor takes the canonical staged
`directory`, existing private `review_root`, separately provisioned `owner_file`,
an authenticated `archive_basis` loader and explicit current `issuer_policies`
and trusted `clock` callbacks. The archive key stays inside the private loader.
No issuer or trusted clock is provided by default. The session starts only its
private review owner and recovery-mode Store, then binds the actual Store PID.
It starts no ordinary Host, socket, capture or device worker.

The same foreground caller prepares and approves the original review, then
calls `Destination.accept(session, review_file, operation_id)`. Delivery saves
the exact immutable operation before the transaction; the returned credential
file remains private 0600 custody and no raw credential appears in the summary.
`Destination.recover(session, review_file)` resolves that original private
receipt after an interrupted reply. Accepted delivery stays read-only until the
session closes. Ordinary Host startup and maintenance end are separate steps,
with dispatch still disabled. Actual current issuer/clock/installed custody
qualification remains required; do not manufacture trusted callbacks from an
archive or use synthetic test evidence for a real transfer.

The packaged foreground command now delivers that session:

```text
bin/wotex_home_recovery receive DIRECTORY ARCHIVE OWNER_FILE CLOCK_POLICY_FILE ISOLATION_ISSUERS_FILE REVIEW_ROOT
bin/wotex_home_recovery receive-status DIRECTORY OWNER_FILE REVIEW_ROOT REVIEW_FILE
```

Use canonical absolute paths and existing private 0700 roots. Keep owner and
current policy files outside the staged directory. The clock policy is the
closed document in [the clock contract](../../docs/specs/controller-clock-v1.md);
the current issuer file uses the explicit encoding in
[the transfer contract](../../docs/specs/controller-transfer-v1.md).
Both are immutable private 0400 files provisioned by the trusted operator.
Neither an arrived archive nor a historical receipt installs current trust.

`receive` first reads the exact archive-key stdin line, then prints a
`clock_request` JSON summary with its original request file/digest and remaining
deadline. Obtain a signed response from the explicitly qualified clock issuer,
publish it in private 0400 custody, and send one canonical JSON line:

```text
["clock-response.v1","REQUEST_DIGEST","/absolute/private/clock-response.json"]
```

It then prints `transfer_review`, including the exact review, credential and
domain file references, conservative issue time and minimum approval delay.
Complete the qualified old-writer isolation procedure for this exact review,
publish its signed decision in private 0400 custody, and send:

```text
["transfer-approval.v1","REVIEW_DIGEST","/absolute/private/isolation.json","OPERATION_ID"]
```

Each metadata line is canonical compact JSON plus LF, at most 4096 bytes, and
must arrive before its original deadline. The output contains the durable
receipt and private file references. EOF, timeout or invalid context closes
the session. A committed receipt remains recoverable with `receive-status`,
which reads no stdin key and needs no live clock or current issuer. Close the
receiving session before separately starting the ordinary Host. Dispatch stays
disabled until its actual qualification and current guards permit it.

After closing recovery and starting the ordinary Host, the receiving credential
may make a fresh `lifx-rereview` of an exact retained compiled enrollment using
new host-owned discovery/interview evidence. The current acceptance must name
that reviewer and retain the unchanged binding/declaration. Copied credentials
and unrelated reviewers remain refused. The old review is retained, and current
reports and qualification are withdrawn by the re-review barrier. Portable
selected profiles still use their explicit profile lifecycle; after compiled
re-review, a new reviewed portable selection can use the validated transfer
barrier. Target grants, maintenance end and actual physical qualification remain
separate decisions.


Profile operation controls now use the same private pending coordinator as
health and maintenance. `mix woh.native.profiles.panel.smoke` checks exact
original input/custody and published pending/commit/cancel intent before actual
Store requests across eight workflows. Held review metadata is saved before
controls, selection keeps its prepare input, and vanished reviews cannot
recreate approval. Missing cancellation keeps its original; an outstanding
cancel intent cannot enable commit. The task renders the profile panel without
Keychain changes or device packets. Persistent recovery controls remain separate
from this completed operation-model composition.

The profile panel fixture runs sixteen domain/shared-recovery workflows. It
checks recovered preparation, fixed commit/cancel intent, refused held-review
retry before custody work, exact original resolution and revocation before
mutation. Expired or vanished reviews remain retained. Ordinary fixture secrets
arrive through stdin; scripted capture qualifies no actual device or signer.

`mix woh.native.target.wire.smoke` checks the independent original native target
access records and immutable receipt correspondence. The typed codec includes
the original operator reference and exact reviewed target/profile pins; its
separate scalar scanner preserves setup/broker bounds. Both app and helper
compile the codec. The fixture opens no Keychain, authenticates no signed peer,
changes no grant and sends no device packet. The signed broker delivers these
records through existing-only original custody and its owned core pipe. The
app matches returned receipts against the complete original mutation input.
`mix woh.native.core.pipe.smoke` checks actual missing/denied access calls leave
the Store revision unchanged; `mix woh.native.broker.socket.smoke` checks
unsigned access callers send no data and agent refusal precedes core work.
Successful installed signing and Data Protection Keychain access require the
signed-host procedure above. Versioned pending publication and explicit native
access controls follow [pending custody v2](../../docs/specs/native-pending-custody-v2.md).
The pending codec/storage commands now check exact access records, v1-preserving
upgrade, retained v2 resolution and actual concurrent upgrade/ordinary CAS.
Access model composition is exercised by the command below.

The app now offers **Review Power Access** and **Review Revocation** for the
native Operator session. Review the displayed Light and selected profile,
confirm the access change, then explicitly grant or revoke. Revocation is
available when the profile is unavailable. Scope and receipt changes require
refreshing Home; access does not qualify a device or enable physical dispatch.
An unconfirmed change exposes original lookup/retry and remains in the shared
pending panel across restart. Changing sessions or target input cannot rebind it.

Run `mix woh.native.access.panel.smoke` for fifteen actual private Store
review/publication/recovery workflows. Its inert custody/private Authority
adapter performs no Keychain operation, signed-host authentication or device
packet. The task writes `_build/native/access-panel-preview.png` and the
unconfirmed preview beside it. Inspect both after layout edits, then compile
the complete app. Installed signed custody follows the separate procedure above.
