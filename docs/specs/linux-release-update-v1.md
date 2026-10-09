# Linux release update v1

Version: 0.1.6. Status: development compatibility/status/fence, inert staging, administrative journal, service transition helpers and packaged probes implemented; coordinator and installed qualification unfinished.

This profile joins [initial installation](linux-installation-v1.md), the
[service layout](linux-service-layout-v1.md), [maintenance client](linux-installer-files-v1.md#authenticated-maintenance-client)
and [release/recovery contract](WOH.16-release-recovery.md). It preserves the
single Authority/Store and default-disabled physical dispatch. It does not
install a second writer, reset an authority epoch, end maintenance, restore a
database, refund causal spend or replay an uncertain handoff.

## Compatibility and authenticated observation

Service manifest format 2 adds an exact update compatibility declaration for
the implemented Store schema 27 and the root-owned host startup fence below.
The development update profile permits a same-schema release replacement only.
Another schema requires its separately implemented migration/recovery profile;
an older executable is never started speculatively against newer data. Legacy
format 1 packages remain verifiable for their original install/repeat/uninstall
semantics but do not satisfy this update profile. Artifact integrity and the
external bootstrap pin are required; unsigned development integrity does not
establish authenticity, legal clearance or installed qualification.

`maintenance_update_status` accepts only API version 1, operation and current
credential. It requires `host:maintain` and returns exactly the existing five
maintenance status fields plus `principal_id`, `store_schema_version`,
`writable` and `update_fence_enabled`. The Store reads its own actual schema;
no transport receives a connection. This is a permission-scoped live status,
not a receipt or authorization to switch a release. The service-UID bridge
also retains the kernel-reported listening PID for comparison with the owned
systemd main process; caller-authored PID or socket ownership alone is insufficient.

## Root-owned deny fence

Format 2 units bind their artifact ID and the fixed
`/opt/wotex-home/update-guard.json` path in trusted launch configuration. The
guard is a root/group-0-owned, single-link, regular 0644 file of at most 4 KiB
under protected real root-owned directories. It contains exactly:

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer 1 |
| `scope` | `linux_release_update_guard` |
| `owner_sha256` | Digest of immutable initial installation ownership bytes |
| `artifact_id` | Exact target source/core payload digest |
| `authority_epoch` | Original positive signed-64-bit authority epoch |
| `begin_revision` | Original positive signed-64-bit maintenance begin revision |
| `state` | `pending` or `complete` |

An absent guard permits initial setup. A configured malformed/unreadable/linked
or foreign-owned guard fails closed. At boot the host owns its Store first,
then checks the fence before profile custody, transport, scheduler, worker or
API consumers start. A pending fence requires the exact artifact and Store
epoch/begin revision. A complete fence still binds the artifact, but permits
the separately authenticated operator to have ended maintenance after completion.
Every Store restart repeats the fence.

The single writer checks the configured fence before a **new** maintenance-end
transaction. Pending or malformed guard refuses end; historical exact end
receipts remain historical and retryable. The installer publishes/syncs pending
before its final authenticated active-barrier check and stop. An end that won
the earlier race therefore appears in fresh status; an end ordered afterward
is denied. This file can only add refusal. It cannot grant maintenance, control,
qualification or a new Store revision. Root remains in the host trust boundary.

## Durable administrative intent

`LinuxUpdateJournal` provides a closed, bounded administrative record at
`BASE/.installer/update-journal.json`. It is root/group-0 owned, single-link
0600 and at most 64 KiB, under the exact protected installation and private
administrative directories. Reads and writes require the marked installer lock,
repeat initial owner-byte custody, and preserve immutable ownership outside the
payload. Publication is exclusive; subsequent writes use original-byte SHA-256
CAS and the existing file/directory synchronization. An uncertain write is
resolved by inspecting the retained record, not by inventing another intent.

The record has exactly `schema_version: 1`, scope `linux_release_update_journal`,
`owner_sha256`, `initial_release`, `generation` and `updates`. Every release
identity has exactly `source_revision`, `artifact_id`, `bootstrap_sha256` and
`inventory_sha256`, with canonical lower-case hexadecimal lengths. The initial
identity must agree with the immutable format-2 installation owner. Each update
has exactly a random 64-digit `nonce`, source and target identities,
`original_main_pid`, `phase` and `maintenance`. It preserves the original PID
in 2–2147483647; the coordinator must still verify the actual image and kernel
peer. Source/target pins are declarations until complete payload verification.

At most 16 updates are retained, with unique nonces and chained source/target
identities. Only the final update may be incomplete. Capacity exhaustion refuses
new work; no history is automatically evicted or collected. Phases are strictly
ordered: `planned`, `staged`, `begin_recorded`, `maintenance_active`, `fenced`,
`stopped`, `configuration_ready`, `target_running`, `selected`, `complete`.
Generation equals the retained intent/phase transition count. CAS permits one
new intent or one next phase, preserving completed history and original pins.
Repeated preparation with the same immutable intent retains its current phase;
changed originals, overlapping updates and skipped phases refuse.

Before begin, a schema-27 writable, fence-enabled authenticated normal status
supplies the original principal, epoch and expected revision. The private record
retains those fields, operation ID `update:NONCE` and initially null begin revision.
This tuple cannot be resnapshotted after recording. Lookup/retry commands use
only the original epoch, operation and expected revision. Accepting begin requires
the closed actual receipt with that principal/epoch/operation and a begin revision
greater than the original watermark. Later phases preserve the whole tuple.
No credential, socket body or caller-expanded field is retained.

This journal is an internal coordinator prerequisite. Its phases are administrative
claims, not receipts, live barrier evidence or permission for service/control
effects. Current-release selection and the complete switch/resume workflow remain
unfinished. Initial install/repeat/uninstall now refuse any retained update journal
before effects, including malformed/foreign bytes; update-aware repeat/uninstall
must be implemented before that journal can participate in a delivered update.

## Coordinator sequence

The coordinator must retain original update intent and administrative progress
under the existing marked installer lock before effects. Immutable initial
ownership remains intact; a separately CAS-bound current-release record names
the selected release. Retained update history is finite. Source and target must
have the same closed account/path/resource profile and supported data schema.
Verify the existing installation, source payload, current configuration, actual
main process and current credential before choosing an update. Bootstrap and
sync the exact target into inert private custody before publishing it exclusively.
An occupied foreign target or changed unit is preserved.

The [inert staging primitives](linux-installer-files-v1.md#inert-update-staging)
now implement separately pinned administrative stage records, complete/prefix
observation, exclusive payload publication, sync and scoped cleanup. They retain
the original ownership record outside the issued release. The coordinator must
still bind the original intent and complete compatible payload to these calls;
stage fingerprints alone cannot select a release or authorize service effects.

`LinuxInstallHost.controller_status/1` reads a bounded closed set of systemd
properties for the one fixed controller unit. It requests `--all` to retain
empty `DropInPaths`, which [systemctl show](https://manpages.debian.org/trixie/systemd/systemctl.1.en.html)
otherwise suppresses. Effective-unit checks make the same explicit request.
Duplicate, omitted, expanded or malformed properties refuse. The unit must be
loaded from its exact owned fragment with no drop-ins or control process.
Only `active/running` with a canonical main PID in 2–2147483647, or
`inactive/dead` with both PIDs zero, is accepted. Failed and transitional
states refuse rather than becoming permission to restart.

`stop_controller/2` repeats the original main-PID comparison before sending a
single stop to that unit and separately observes stopped state afterward. An
already stopped unit needs no command. `start_controller/1` requires stopped
state, sends only start, and separately returns the new observed main PID.
Uncertain command/status results refuse; they do not retry, enable/disable a
unit, reset restart limits or select another executable. Mutations retain the
existing privileged helper lock and parent-death guard. Fixture callback
overrides are internal and absent from the installer CLI. The coordinator must
still join exact source/target payload/configuration, kernel peer, process image,
empty stopped cgroup and live original maintenance barrier before effects or
completion. PID observations alone do not establish those joins.

After staging, read fresh authenticated update status and durably retain the
original principal, epoch, operation ID and expected revision before begin.
Lost begin replies use original lookup/retry; never resnapshot into another
operation after transmission. A historical receipt is insufficient: compare
fresh status with its exact active begin revision and principal. Publish pending
fence and repeat that live comparison before stopping the owned controller.
Confirm it is stopped before replacing the exact old unit through byte CAS.
Verify/reload the owned configuration and start only the target. Do not reset
restart limits, start an old fallback or change unrelated services.

Fresh target process, socket peer, schema and retained original barrier must
agree before committing current-release selection and completing the guard.
Interrupted progress resumes the same intent and phase; ambiguous ownership,
barrier, registration or schema refuses. Accounts, private state, credentials,
history and spent roots remain intact. Completion never ends maintenance or
reactivates rules. State-preserving uninstall must understand the committed
current release and refuse an unfinished update. Automatic rollback and purge
are separate operations requiring their own compatible recovery contract.

## Required evidence

Use actual SQLite/authenticated route tests for schema/status, current permission,
original end retry and pending-fence denial; exercise the actual host restart
tree to prove no consumers start after a failed fence. Verify legacy/new package
formats and independent peer PID/UID checks. Coordinator fixtures must inject
lost replies and failures at every publication, begin, stop, CAS, reload, start,
selection and completion boundary, retaining original history and foreign bytes.

A fresh current-source packaged host must exercise the guard under its real
service UID. Actual installed systemd/coexistence, effective limits, restart
exhaustion, disk/power-loss, compatible schema recovery, amd64, signed delivery
and physical tests remain distinct obligations. No fixture, compiler, root file
or historical receipt closes them.

The compatibility/status/fence subset now passes 64 Linux cases with the
maintenance, host, installer, service and file suites. A later focused 12-case
run adds successful pending host boot and failed Store-restart recovery,
completed-artifact end refusal, strict update-status decoding and kernel peer
PID equality. Forty macOS cases pass the portable/core subset; a later focused
three-case run includes the pure guard/status changes. Linux-root guard cases
use private protected namespaces and actual SQLite/host supervision. Installed
systemd and coordinator interruption remain separate evidence requirements.

The [packaged service-UID probe](../../native/linux/README.md#packaged-service-uid-fence-probe)
now exercises the production fixed guard path under UID/GID 211 against an
independently root-staged arm64 release. Actual SQLite/authenticated socket
checks retain the original barrier and receipts, refuse wrong artifact/epoch/
revision/custody, deny pending end, stop consumers after a failed Store restart,
permit separately authenticated end after completion and preserve exact retries.
The root-owned payload stays inventoried and all six providers load from it.
Synthetic administrative guard progress is not a release-switch coordinator or
installed systemd/coexistence, power-loss, resource or physical qualification.

Staging prerequisites pass eight actual Linux cases and four portable macOS
cases. Their interrupted-copy checks compare exact source prefixes, and native
cleanup/publication independently recheck the pinned tree under the real lock.
The release-switch coordinator and installed qualification are unfinished.

The [minimal-base packaged staging probe](../../native/linux/README.md#packaged-update-staging-probe)
now checks the complete clean `865cc08` arm64 payload under the actual marked
lock: 1,471 bootstrap files are copied, verified, published and synced; exact
source-prefix cleanup and changed-byte preservation pass. Closed maintenance
frames and kernel-peer substitution are checked without sending a bearer.
This is packaged prerequisite evidence, not a service-switch coordinator or
installed/power-loss qualification.

The service-helper run passes 26 Linux cases with existing installer/file
regressions. Nine portable host cases pass on macOS. Independent property
fixtures cover absent empty fields, duplicate/expanded values, foreign
fragments/drop-ins, PID bounds, changed main process, transitional/failed
states and lost stop/start observations. Commands are captured by synthetic
service callbacks; actual Linux file/lock cases remain distinct. Real systemd,
cgroup/process-image joins and installed lifecycle remain untested.

Journal checks pass seven Linux cases under actual marked-lock/native CAS
operations, including private modes, linked/changed records, original-owner
substitution, stale/skipped publication and reload. The joint journal/installer/
maintenance/SQLite run passes 42 Linux cases; 21 portable journal/SQLite cases
pass on macOS. The actual SQLite lost-begin-reply/restart case resolves the same
original receipt and retry while keeping maintenance active. Installer fixtures
preserve owned units, owner bytes and progress while refusing repeat/uninstall.
Phase progression fixtures do not establish process switching, completion or
storage power-loss survival.
