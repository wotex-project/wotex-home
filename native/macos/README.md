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
retained backup objects and quarantined restore. No profile-import/selection
command exists yet; the current maintenance commands do not install profiles.

The opted-in Home host now owns `profiles/` beside its SQLite Store, using an
existing private 0700 data directory. It resolves `/var`/`/tmp` and other directory
aliases to a canonical physical path before Store startup. Only after Store has
acquired ownership does it create/open the private immutable profile namespace
and transient one-use review owner. Existing nonprivate/symlink profile roots
are rejected without changing them. Restarts discard pending reviews and stop
downstream workers; retained approved bytes and Store history remain separate.
Public profile-import/selection commands and native presentation are still being
built. These host fixtures do not establish installed app custody or disk
power-loss behavior.
