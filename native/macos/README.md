# macOS development bundle

From a clean Home source tree, assemble and inventory the production OTP
release, then run `python3 bin/assemble_macos_app.py` from the repository root.
For local LIFX metadata testing, run `mix woh.lifx.registry.fetch`
before building the release; the fetched registry remains outside Git.
The result is `_build/macos/WotexHome.app`. XcodeGen also creates an ignored
`WotexHome.xcodeproj` for further native development. The assembly script uses
the installed Command Line Tools Swift compiler and produces an unsigned,
arm64 development bundle.
The assembly writes an unsigned file inventory for the complete app bundle.
Run `python3 bin/macos_app_inventory.py verify _build/macos/WotexHome.app`
to check the outer bundle and its embedded OTP release inventory.
It also writes a file-level SPDX 2.3 JSON document for the full bundle;
run `python3 bin/macos_app_spdx.py verify _build/macos/WotexHome.app` to check it.

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
It verifies the private socket path and same-user peer before sending the
credential. The host checks the caller's kernel peer UID before reading a frame.
The native socket client uses one monotonic five-second deadline across
connect, send and receive; a slow response cannot reset that deadline.
The returned counters describe the Store, not physical device
health. Run `python3 bin/smoke_native_health.py` to check the native frame and
response handling against an independent socket peer. Run
`python3 bin/smoke_native_snapshot.py` and
`python3 bin/smoke_native_read_view.py` for independent paging fixtures.
Run `python3 bin/smoke_native_receipt.py` for receipt lookup and cancel fixtures.
Run `python3 bin/smoke_native_enrollment.py` for the scoped enrollment status fixture.
Run `python3 bin/smoke_native_power_submit.py` for the typed mutation fixture.
Run `python3 bin/smoke_native_overrides.py` for the scoped override fixture. Run
`python3 bin/smoke_native_override_mutations.py` for issue/status/revoke fixtures.
Credential provisioning
and signed app identity are still required for installed use.

For a foreground development host before hardware enrollment, stop any
running Home host and run
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/bootstrap_health.exs`
from the repo. It prints a one-time read-only credential for Keychain import;
run it in a private terminal, without putting the credential in shell arguments.
The same directory must then be used by the background host. A second run
cannot mint another copy of that principal. This is a development bootstrap,
not the installed credential broker. Run `python3 bin/smoke_bootstrap_health.py`
to verify the one-time behavior without displaying a real secret. Run
`python3 bin/smoke_native_live_host.py` to check the compiled Swift client
against an actual foreground Home host using that credential over standard
input, without showing or logging it.
Run `python3 bin/smoke_native_cli_parity.py` to stage one held fixture request
through Swift, read and cancel its receipt through the CLI, then read the
terminal receipt through Swift against one live private host.

Before installed use, the bundle still needs Developer ID signing,
notarization, entitlements, a background credential broker, installed peer-UID IPC checks,
registration/approval tests, and lifecycle tests under a fresh account.
`mix woh.macos.native.deps.check _build/macos/WotexHome.app` checks
the direct Mach-O load paths and deployment minima in the assembled bundle;
assembly runs it before writing the app reports. The declared minimum is macOS
15.0 because of the packaged OTP/NIF closure. A fresh macOS 15 account still
needs an installation and runtime check.
