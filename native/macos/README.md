# macOS development bundle

From a clean Home source tree, assemble and inventory the production OTP
release, then run `python3 bin/assemble_macos_app.py` from the repository root.
The result is `_build/macos/WotexHome.app`. XcodeGen also creates an ignored
`WotexHome.xcodeproj` for further native development. The assembly script uses
the installed Command Line Tools Swift compiler and produces an unsigned,
arm64 development bundle.

The SwiftUI window uses `SMAppService.agent(plistName:)` to register or remove
the bundled per-user agent. Its status shows registration eligibility, not
verified controller health. The agent creates a private Application Support
directory, starts the bundled OTP release, forwards termination, and exits
when the host exits. Closing the window is independent of the registered
agent. No registration or signing is performed by the assembly script.

Before installed use, the bundle still needs Developer ID signing,
notarization, entitlements, a credential broker, peer-UID IPC checks,
registration/approval tests, and lifecycle tests under a fresh account.
