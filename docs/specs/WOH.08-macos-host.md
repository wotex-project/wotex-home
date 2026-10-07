# WOH.08 — Native macOS control surface and background host

Version: 0.2.45. Status: accepted target.

## Process ownership

**H08-01.** SwiftUI owns windows/menu bar, accessibility, native permissions, Keychain integration and notifications. The Elixir/OTP release owns Home state, driver connections, scheduling, admission and execution. Vendor packet formats and rule evaluation never enter Swift.

Frameshift supplies a useful authenticated IPC and native-shell precedent, but its app-owned lifetime is not Home's default. Closing a window must not stop automations. The installed Home profile uses an operator-enabled bundled per-user LaunchAgent managed through [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). A foreground CLI/demo profile remains available and explicitly ends when its process exits. Do not install a privileged root daemon just to keep the UI closed.

**H08-02.** The UI reports background registration, approval-required, running, stopped and degraded states separately. 'Quit UI' and 'Stop controller' are distinct operations. Uninstall/disable background service is explicit and leaves a clear account of the home's resulting availability. A second process cannot take the same authority/store/radio lock.

An opt-in Elixir supervisor now owns the private data directory, Store and socket as one local process tree. A Store crash restarts the Store and socket together under a same-host lock; stopping the supervisor closes the socket. The database file is mode 0600. Application startup enables this process tree only when `WOTEX_HOME_DATA_DIR` is set to an absolute private directory; otherwise no Home host starts. The core host itself does not manage service registration, native credential custody or radio ownership.

A trusted `:lifx_capture_interface` application setting or explicit `WOTEX_HOME_LIFX_INTERFACE` host environment setting can add a LIFX capture process under the same supervisor. It selects the named live IPv4 interface and opens the pinned WoTEx UDP socket from inside that process. A missing or ambiguous interface prevents startup; a changed scope prevents further capture calls and discards pending evidence. Authenticated `enroll:review` operators can invoke bounded discovery and interview, then commit a one-use capture through an immutable compiled profile by reference. They cannot checkout the transcript, submit candidate/profile bodies, qualify the profile or send a device write. The setting is absent by default, so installing the development bundle does not probe the LAN on startup.

When that owner is enabled, an authenticated target-granted controller can explicitly refresh one enrolled LIFX Thing by Home ID. The host performs fresh discovery and exact enrolled stable-ID selection inside the owner before unicast; the client never supplies routing or profile data. Enrollment capture and refresh are mutually exclusive, so refresh cannot overwrite or consume pending review evidence. The Store rechecks the current credential, grant, binding and declaration when it commits the validated report. No periodic probing is enabled merely by installing or starting the host.

An unsigned arm64 development bundle now contains a SwiftUI registration window, a `Contents/Library/LaunchAgents` property list using `BundleProgram`, a small per-user helper and an inventoried OTP release. The window uses `SMAppService.agent(plistName:)` for explicit enable/disable and shows registration status without claiming the host is healthy. The helper creates or checks a mode-0700 user Application Support directory, launches the bundled release with that data path, forwards termination and waits for shutdown. A direct helper startup/shutdown check passed on the development Mac, including private socket modes. The assembly script does not register the agent. Signing, approval, actual SMAppService lifecycle, installed credential custody and fresh-account tests remain open; an unsigned bundle is not H08-T1 evidence. Apple's [Service Management guidance](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos) defines the bundled `BundleProgram` layout.

The development bundle now declares macOS 15.0 as its minimum and cross-compiles the Swift window and agent for that deployment target. The previous assembly inherited the build Mac's macOS 27.0 minimum despite advertising 13.0 in its plist. The packaged OTP/NIF closure includes binaries with a 15.0 minimum, so 13.0 was not a supportable claim. The assembly verifies each native load command's minimum against the plist; a clean macOS 15 installation and API availability remain untested.

## IPC and credentials

**H08-03.** The local baseline is versioned length-framed JSON over a per-user Unix domain socket. Use an application-owned directory with mode 0700 and socket mode 0600, reject symlink/non-socket replacement, verify the peer UID where supported and authenticate sessions. Bootstrap secrets are ephemeral, not in process arguments, URLs or logs. Local path possession alone is insufficient authorization.

Apply WOH.15 limits before allocation. Distinguish request correlation from idempotency and physical outcome. Reconnection obtains a current snapshot and operation status rather than resending mutations with new IDs. Events use bounded credit and explicit resnapshot gaps.

The first opt-in Elixir socket server implements this framing and private directory/socket modes. It rejects duplicate JSON members, depth over 16, requests over 64 KiB, unknown operation fields and unsupported versions. It accepts at most 32 concurrent connections; each handles one request with a five-second total frame-read deadline and a bounded response send. A stalled client cannot hold the only accept path. Its routes are authorized redacted health, held request submission/cancellation, scoped receipt status, current-observation snapshot pages, active Thing catalogue pages, scoped observation history and pending-only draft rule review. Ordinary dispatch decisions have a five-second deadline measured from the start of frame reading; draft reviews use a separate ten-second check deadline. A timed-out mutation returns `outcome_unknown`, since its Store call may still commit, and the caller must query the original operation ID. The review runs outside the Store writer, is limited to two simultaneous checker calls, and releases a slot if its worker exits. A full checker pool returns `review_capacity`. It stops when its Store exits. The current bearer credential is supplied inside the private socket frame; callers must keep it out of logs and command arguments.

The server now reads kernel peer credentials on each accepted Unix socket before reading a frame and requires the peer's effective UID to match the socket owner; an unavailable or unknown layout closes the connection. The macOS raw option follows `LOCAL_PEERCRED` and `xucred` from the installed SDK; [Erlang's raw socket option contract](https://www.erlang.org/doc/apps/kernel/inet.html) defines the access method. A same-user live peer and a mismatched UID comparison pass local tests. This is an OS-user gate alongside the bearer credential, not process-code identity or installed app authentication. Native bootstrap/session authentication and installed-service ownership remain required before H08-T4 or host acceptance can pass.

The development SwiftUI window can now import a 32-byte URL-safe operator credential into a non-synchronizing generic-password Keychain item and call authenticated read routes. It checks the private directory/socket type, owner and mode, then uses [`getpeereid`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html) to require a same-user Unix socket peer. The native client bounds the frame and validates the response version and health fields. An independent same-user scripted socket peer passes a valid frame and rejects a wrong-version response. The development foreground bootstrap described in WOH.15 can issue a zero-target read-only credential for this view. It does not establish the installed app's signed Keychain identity, prove peer process identity beyond UID or qualify an installed session. Apple's [generic-password item contract](https://developer.apple.com/documentation/security/ksecclassgenericpassword) defines the Keychain class used here.

The separate trusted `bootstrap_controller.exs` setup command can provision a
named read/control principal only after its first target is enrolled. Its
`grant` mode adds one later active Thing and replaces the principal credential
in the same Store transaction; the operator must replace the old Keychain item.
Neither mode is a socket operation, and the command prints the new credential
once rather than accepting a secret in arguments. This is a development
custody bridge, not the installed broker or signed-client authentication
required by H08-04.

A second smoke now boots the real private foreground Home host after a one-time diagnostic bootstrap and calls `health` through the compiled Swift client. The secret crosses the test harness on standard input, not command arguments or output. The bootstrap explicitly stops its temporary Home application so its socket pathname is removed before the live host starts; the smoke waits for an accepting listener rather than treating a socket file as proof of service readiness. This covers native framing and authenticated health against the current host on the development Mac, not installed Keychain retrieval, signing, service registration or a physical device.

The development SwiftUI window now pages credential-scoped enrolled Thing declarations and current observations through the same private socket and Keychain credential. It renders Thing role, capability count and resource revision alongside typed reported values, quality and trust; the zero-target diagnostic principal sees empty scoped views. Catalogue and snapshot use one Store watermark, so a write between them yields `resnapshot_required` and clears the partial view. The client follows at most four 10-Thing catalogue pages and eleven 100-observation pages, covering the 32 granted Things and 32 capabilities per Thing allowed by the current schema. Independent fixtures check both cursor paths, the 1,024-observation boundary and changed-revision rejection; a live zero-target host smoke covers both routes. These are read-only presentation views; they do not show physical completion or install a credential broker.

The native health decoder now requires the current rule generation and separate held, queued, claimed and unknown-outcome counts. The window displays them together and highlights a nonzero unknown count, so a recorded handoff uncertainty is not hidden behind an aggregate pending number. Scripted native framing and live private-host checks pass on the development Mac; installed service and physical readback claims remain open.

The window can also look up a specific `(authority_epoch, operation_id)` through the authenticated, principal-scoped `status` route. It displays the durable disposition, revision and bounded reason, including `outcome_unknown`, or an explicit not-found result. The Swift client validates the requested ID, returned tuple and closed disposition; an independent socket peer checks a valid uncertain receipt, missing receipt and mismatched response. The receipt view is not proof of physical completion or a signed installed-client identity.

An enrolled Light with an exactly declared ordinary Boolean writable `power` capability now exposes Stage On and Stage Off controls. The native client creates a fresh operation ID, combines the displayed Thing resource revision with the refreshed authority epoch, and sends the closed typed mutation through the existing authenticated `submit` route. It validates that the returned receipt belongs to that operation, displays its durable disposition and retains the operation ID for a status lookup if the response is uncertain. A held receipt means staging only; the UI makes no device-effect claim. The socket and Store still enforce current principal grants, declaration and policy. An independent socket peer verifies the exact mutation and rejects a mismatched receipt. The development diagnostic credential has no control grant, and no physical dispatch is enabled by this window.

The same operation view can now cancel its original `(authority_epoch, operation_id)` while work is held or still queued. The native client verifies the returned tuple and terminal rejected disposition; a missing receipt remains explicit. The window preserves the ID and directs an uncertain cancellation reply to `status`, since the Store may have committed it before the socket timed out. It does not claim to recall a claimed or handed-off effect. An independent socket peer checks the exact cancel frame, a terminal queued-cancellation receipt, not-found and malformed-result rejection.

The native shell can now look up an enrollment review reference with its operator credential. It displays the selected Thing, original review revision, current binding revision, digest version and current/superseded/revoked state. The client validates the closed response and treats another operator's review as not-found. This is a read-only recovery view; it does not accept capture evidence or enroll a device. An independent socket peer checks exact request fields and malformed status rejection.

The native read view now requests current operator overrides for its granted catalogue Things. Its decoder rejects an unrequested or duplicate target, malformed issuer or authority, and an impossible remaining interval. The window shows a bounded list and remaining time from the Store clock. A writable ordinary Light exposes a 15-minute override issue action; the window retains its operation ID and epoch for status lookup after a lost response. A granted issuer can revoke a listed lease by that ID, while other readers see no operation ID or revoke button. The client validates the closed issue/status/revoke receipt and never invents a new ID on retry. These controls do not send a device command or activate an automation. Independent scripted Unix peers check exact read and mutation requests plus malformed response rejection. The view is a point-in-time read and does not prove an automation was active or a physical command was blocked.

A bounded Elixir client now checks the socket and parent directory types, matching owner and private modes, and the connected peer's effective UID before it sends the caller's credential. A missing or replaced private endpoint fails before a request frame is sent. It validates the framed, versioned response with a finite total deadline. This supplies an internal consumer contract; it is not the installed Keychain broker or a signed-process identity check.

The Swift client now uses a nonblocking Unix socket and one monotonic five-second deadline across connection, request writes and response reads. A same-user scripted peer that trickles a response header and body past that deadline fails instead of extending the request on each byte. A transport timeout on a mutation still has uncertain commit status: the client must query the original operation ID. Installed lifecycle and signed-client identity remain separate gates.

A live development-host smoke now stages one held Light power request through the compiled Swift client, reads that exact receipt through the headless CLI, cancels it through the CLI and reads the terminal receipt back through Swift. The credential reaches Swift on standard input and the CLI through a private 0600 file. Both clients agree on epoch, operation ID, disposition, reason and revision against one Store. The same smoke suspends rules through Swift and compares its immutable activation receipt and current generation/state with the CLI. This tests the shared receipt boundary; it does not test the installed SwiftUI window, physical effect or signed app identity.

The rule policy panel reads the active admission, generation, authority epoch and current active/inactive/suspended state. A rule manager can suspend using the displayed Store revision and current epoch, then resolve a lost reply by the original operation ID. The client checks the closed activation fields, consecutive generation and bounded affected/unknown counts. Those counts describe the activation barrier at commit time, not current physical outcomes or recalled packets. Principal-private lookup also accepts an original admission receipt without exposing source/proof bytes. Independent socket fixtures reject Boolean/floating revisions, mismatched operation identity and impossible activation counts. Native source editing, admission and invocation are still separate work.

**H08-04.** Keychain access must outlive the presentation window. A small native credential broker may belong to the registered host or an authenticated XPC helper. It receives narrow operations and checks peer identity; it is not an arbitrary signing/decryption oracle. Secret bytes stay ephemeral at the network boundary where the protocol requires them. Keychain locked/denied is a typed capability failure, never a fallback plaintext file.

## Task-first adaptive composition

**H08-08.** Each native surface has one primary task: inspect an enrolled Thing
and its observations, compare history or quality, request an authorized change,
monitor controller/automation attention, or compose a draft rule. The task brief
names the exact Thing/capability, decision or completion condition, required
evidence and authority, and recovery path. Thing cards represent independently
selectable enrolled Things. Other sections do not become cards by default, and
a dashboard is used only for recurring monitoring or decision work.

Compose the SwiftUI content region by available width rather than device label:
compact below 600 points, medium from 600 through 839 points and expanded at
840 points or wider. Profiles may move supporting regions between inline,
disclosure and adjacent placement. They preserve one semantic state and never
create a second controller model in Swift.

Every profile retains the Thing identity, declaration/profile/resource
revision and capability; reported value and unit; observation source, quality,
trust, event/receive time, boot/source epoch and freshness; selected history
range, filters, draft, focus and navigation; principal, grant and authority
epoch; operation ID and expected revision; and the exact durable and physical
outcome state. A requested, held, queued, claimed, dispatching or
protocol-accepted change remains distinct from an observed device result.
Compact composition must not hide stale/unknown/synthetic quality, evidence
gaps, risk class, required confirmation, denied authority, outcome uncertainty,
controller availability or the status/reconciliation control for the original
operation.

Acceptance uses the same fixtures at 599/600 and 839/840 point content edges.
It covers task completion, keyboard and VoiceOver navigation, focus/draft/
selection continuity, increased text size, Increase Contrast, Reduce Motion
and Reduce Transparency, including resnapshot gaps, stale observations,
revoked grants and outcome-unknown receipts. A layout snapshot cannot establish
device control or physical completion.

## macOS is not an always-on appliance

**H08-05.** Sleep, logout, service revocation, Keychain lock and USB removal have documented availability effects. A per-user agent does not run after logout; a sleeping Mac does not process Zigbee reports. Optional power assertions require user consent and visible energy impact. They are not an absolute uptime guarantee. After wake, reconcile pending outcomes, report observation gaps and rebuild timers using clock confidence.

The detector's standalone siren remains independent. UI labels must never imply the Mac substitutes for a certified safety hub.

## Local networking and USB

**H08-06.** Declare local-network/Bonjour usage for the actual packaged process that owns the connection; test permission denial and restored permission in the installed artifact. Native discovery supplies untrusted introductions to the core. Network permission UX does not authorize a discovered peer.

The Elixir protocol host owns serial access through an explicitly selected adapter. Match USB identity and operator selection, not a guessed `/dev` suffix. On reconnect, verify NCP identity/version before restoring network use. Neither Home Assistant nor Zigbee2MQTT is a runtime requirement; a documented NCP firmware is still required.

## Packaging and acceptance

The development bundle now compiles both app and agent in Swift 6 with warnings
treated as errors and the declared arm64 macOS 15 target. Native client fixture
builds use the same language, warning and deployment policy. This source/build
gate supplies no signing, installed IPC, registration or physical evidence.
Each script supplies a private module cache under its own temporary build
directory; an unwritable global cache cannot prevent this source check.
Compiler intermediates are removed and never become shipped app payload.

H08-T1: a fresh non-developer account can install a signed/notarized artifact containing the selected OTP/native dependencies. H08-T2: background enable/disable/approval and UI/core crash independence. H08-T3: sleep/wake/logout/Keychain denial/USB reconnect. H08-T4: authenticated IPC rejects replayed, oversized, wrong-version and wrong-principal operations. H08-T5: updates retain data, service registration and credentials without a second controller. H08-T6: model and Maude artifacts are preinstalled and no first-run WAN fetch is required. H08-T7: native UI and CLI observe identical receipts. H08-T8: inspect, compare, request-change, monitor and compose-rule fixtures preserve the H08-08 state envelope and honest requested-versus-observed outcome at 599/600 and 839/840 point edges under the named accessibility preferences.

A visual check of the assembled schema 18 app found a misleading registration label: the helper/plist were inventoried but `.notFound` was described as a missing bundled agent. The window now says the background service is unavailable; `.enabled` describes registration/eligibility and `.notRegistered` describes registration alone. Apple's [status documentation](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.property) and shipped `SMAppService.h` distinguish those states from actual process health and require proper app signing for registration. No service registration, credential import or physical mutation was performed during this development-window check.

The native maintenance panel now reads the authenticated barrier independently of ordinary health/control access. Begin/end use that view's epoch, Store revision and original begin revision; a maintenance-only credential needs no Thing grants. The panel separates current status from historical receipts and requires another status read after a change. An uncertain request retains its exact inputs and original credential in memory for immutable lookup or retry, even after another credential is imported; new changes remain disabled until resolved. A receipt lookup never changes the displayed current state. The client rejects Boolean/floating-point counters, changed identities, impossible begin/end revisions, contradictory states and outcome counts, extra fields and malformed error envelopes. Thirty-two independent peer cases include a lost reply followed by an exact retry. Live Swift/CLI parity covers begin/end, invalidated held work, blocked new staging, unchanged historical receipts and rules staying inactive after end. These checks use disposable private Stores and send no device packet. Signing, installed custody, durable client-side recovery across UI restart and actual update installation remain separate gates.

## Optional component worker

The [component runtime](WOH.17-component-extensions.md) is an optional OTP-managed native worker, separate from Swift and Store. Development configuration may enable pure previews only. It is not silently included in the existing app/release closure. Shipping it requires native inventory/legal inputs and actual signed executable-memory, entitlement, EOF/deadline retirement and restart checks; unsigned desktop tests do not establish those results. Procedures belong in [the host guide](../../native/macos/README.md).

## Portable data host gate

Data-only [WOH.18](WOH.18-portable-profile-admission.md) admission/control must
work offline with provisioned local approvals and no component worker. Its
private artifact custody, durable publication, retained dependency inventory and
restore behavior need actual installed-host tests. Signed JIT permission and
OS/native-memory containment apply only when an optional helper is delivered;
portable profile data does not establish those gates or physical qualification.

The shared `Host` now starts private portable-profile custody and transient
selection-review custody immediately after Store has acquired its directory lock.
`profiles/` is created as 0700 only under that owned data directory; an existing
nonprivate or symlink root is rejected without repair. Host resolves OS directory
aliases to one canonical physical path before choosing the Store/custody namespace.
Store receives trusted named process references; custody/review owners receive
no SQLite handle or bearer credential. Custody restart keeps Store history but
stops downstream workers and discards pending reviews. Review-owner restart
releases its monitored leases and stops consumers without replacing Store or
custody. Store restart stops both owners and downstream power workers first.
Compiled operation remains independently guarded; these restarts never activate
profiles, restore qualification or send work. Development fixtures exercise
creation ordering, malformed roots, exact immutable bytes and restart ownership;
installed storage/custody and physical qualification remain separate gates.

The Swift client now implements all nine closed portable-profile routes. Exact
import bytes bind their returned raw digest; canonical ordered operation bytes
bind the original receipt's input digest and all supplied pins. It checks nested
catalogue, target, identity, semantic diff, qualification-head and collection
shapes, typed integer/Boolean distinctions, count/revision bounds and explicit
absence/revocation. A global bounded response scan rejects duplicate decoded
names and excess depth before Foundation parsing. It preserves retained approval
and qualification separately from call-local byte/profile usability.
Independent same-user peer cases cover malformed inputs/results, initial and
replacement identity, changed firmware status, unavailable/revoked selection,
immutable receipt recovery and exact retry after a lost reply. Live Swift/CLI
parity compares import, approval/revocation, catalogue/absent-target snapshots,
original receipts and Store-owned collection on one disposable foreground Store.
Neither check sends a device packet. Native profile window composition remains
pending; signed installed custody, full live capture/selection UI correspondence
and physical acceptance remain separate obligations.
