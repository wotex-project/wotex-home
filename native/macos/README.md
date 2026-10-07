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
verified controller health. The agent creates a private Application Support
directory, starts the bundled OTP release, forwards termination, and exits
when the host exits. Closing the window is independent of the registered
agent. No registration or signing is performed by the assembly script.

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
they do not claim to recall a packet already handed off. Rule source editing,
admission and explicit invocation remain CLI/API operations.
It verifies the private socket path and same-user peer before sending the
credential. The host checks the caller's kernel peer UID before reading a frame.
The native socket client uses one monotonic five-second deadline across
connect, send and receive; a slow response cannot reset that deadline.
The returned counters describe the Store, not physical device
health. Run `mix woh.native.health.smoke` to check the native frame and
response handling against an independent socket peer. Run
`mix woh.native.snapshot.smoke` and
`mix woh.native.read.view.smoke` for independent paging fixtures.
Run `mix woh.native.receipt.smoke` for receipt lookup and cancel fixtures.
Run `mix woh.native.enrollment.smoke` for the scoped enrollment status fixture.
Run `mix woh.native.power.submit.smoke` for the typed mutation fixture.
Run `mix woh.native.overrides.smoke` for the scoped override fixture. Run
`mix woh.native.override.mutations.smoke` for issue/status/revoke fixtures.
Run `mix woh.native.rule.smoke` for closed rule status, suspension and
principal-private operation lookup fixtures, including malformed responses.
Run `mix woh.native.maintenance.smoke` for authenticated maintenance status,
begin/end, closed receipt validation and a lost response followed by exact retry.
Run `mix woh.native.profiles.smoke` for all nine closed profile routes, exact
operation hashes, identity/diff/status fields, malformed results and lost-reply
recovery. The live CLI parity task also compares profile import, approvals,
revocation, catalogue/target reads, original receipts and collection.
Run `mix woh.native.setup.peer.smoke` for the closed Developer ID requirement,
hardened-runtime entitlement checks, real kernel socket audit-token capture and
unsigned setup refusal. The private seal expires at its original five-second
deadline. Both native build commands include this gate; it does not yet open a
setup channel. Signed pair success, service lifecycle and Keychain custody need
the installed checks in [the peer contract](../../docs/specs/macos-signed-peer-v1.md).
The trusted core now supports [owner-scoped native setup roles](../../docs/specs/native-setup-authority-v1.md):
four fixed roles, no initial Thing grants, verifier-only provisioning and the
original creation receipt on unchanged retry. The ordinary socket rejects these
operations. The installed Keychain custodian and its private core channel are
still separate work; manual development credential import remains available.
The [private core channel](../../docs/specs/native-core-channel-v1.md) is now
implemented with the fixed release entry `eval WotexHome.NativeSetup.CoreHost.main()`.
It owns binary stdin/stdout, pins the original Store, bounds every frame and
decision, keeps diagnostics on stderr and stops its own Host on pipe loss.
Real child-pipe checks cover original receipt recovery across restart, oversized
and dripped frames, EOF and lock/socket release. Native agent pipe ownership and
installed Keychain delivery still need their own implementation and evidence.
Run `mix woh.native.setup.wire.smoke` for independent canonical core and broker
records, original receipt identity checks and malformed/bounded parser cases.
These inert fixtures open no Keychain and authenticate no peer. The
[credential broker contract](../../docs/specs/native-credential-broker-v1.md)
keeps installed agent custody and delivery separate from wire evidence.
Run `mix woh.native.core.pipe.smoke` for the native child owner against an actual
Home core and adversarial pipe children. It checks exact original receipts after
restart, private Host socket cleanup, excluded environment overrides and
bounded failure/capacity cases. It opens no setup listener or Keychain item;
signed agent composition remains a separate installed step.
Run `mix woh.native.keychain.policy.smoke` for inert private-group queries,
noninteractive authentication context, epoch account separation and typed errors.
It performs no SecItem operation or account change. The actual agent-only
custodian requires an OS-derived signing seal; installed profile authorization,
locked/denied behavior and isolation still require signed-artifact checks.
Run `mix woh.native.broker.socket.smoke` for actual private socket ownership,
bounded framing/deadline checks, replacement/cleanup refusal and unsigned setup
rejection before core calls. Its separate inert transport cases authenticate no
peer. It performs no SecItem operation and cannot qualify installed brokerage.
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
notarization, entitlements, a background credential broker, installed peer-UID IPC checks,
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
Run `mix woh.native.profiles.panel.smoke` for seven real Store/capture workflows:
happy path, lost approval/preparation/selection/cancellation, expiry and missing
bytes. The host capture is scripted and sends no device packet; the fixture
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
