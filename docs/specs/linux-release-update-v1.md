# Linux release update v1

Version: 0.1.14. Status: development compatibility/status/fence, inert staging, incarnation-bound journal, current selection, owned inspection, joined maintenance, fence/stop and target-switch segments, process/cgroup observations, service transition helpers and packaged probes implemented; intent planning/staging composition, public update entry and installed qualification unfinished.

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

Guard format version is an integer: JSON `1.0` refuses even though its numeric
value equals 1. A pre-correction decoder regression reproduced its acceptance.
The corrected portable case passes, and 23 joint Linux fence/maintenance cases
pass, including actual boot and new-end refusal for a floating format version
without replacing guard bytes or changing the original barrier/history.

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

New records have exactly `schema_version: 2`, scope `linux_release_update_journal`,
`owner_sha256`, `initial_release`, `generation` and `updates`. Every release
identity has exactly `source_revision`, `artifact_id`, `bootstrap_sha256` and
`inventory_sha256`, with canonical lower-case hexadecimal lengths. The initial
identity must agree with the immutable format-2 installation owner. Each update
has exactly a random 64-digit `nonce`, source and target identities,
`original_main_pid`, `source_process`, `phase` and `maintenance`. The retained
process has exactly `pid`, `account_id`, `start_ticks`, `boot_id`, `cgroup`,
`image_sha256`, `image_device`, `image_inode` and `invocation_id`. The original
PID equals its PID in 2–2147483647; account ID equals immutable ownership.
Start tick/inode are positive unsigned-64-bit integers, device is nonnegative
unsigned-64-bit, boot identity is canonical lower-case UUID, cgroup is the fixed
controller path, image digest is 64 lower-case hex and invocation is nonzero
32 lower-case hex. Closed conversion never interns caller-supplied JSON keys.
Repeated preparation and every phase CAS preserve the entire original process,
including when the numeric PID is unchanged. The coordinator must still establish
the observation's actual origin and recheck it with the kernel peer. Pins and
administrative process values remain declarations until their live joins.

Version-1 records remain readable in their original closed shape. A byte-CAS
format upgrade to version 2 is permitted only with empty or fully completed
history, preserving every original intent value, owner/pin and phase-generation
counter. Completed legacy intents retain their six fields without an invented
process; they must form a contiguous leading prefix. Every newly appended intent
requires the full process shape. New version-1 intents, downgrade, changed history
or format upgrade of unfinished legacy work refuse. Existing original begin lookup/
retry remains readable; missing historical incarnation evidence grants no effects.

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
effects. The complete switch/resume workflow remains unfinished. Repeat/uninstall
now consume the selected release only after every retained update is complete;
incomplete, malformed, foreign or inconsistent progress refuses before effects.

## Current-release selection and lifecycle

`LinuxUpdateSelection` retains `BASE/.installer/current-release.json` under the
same marked lock, initial-owner custody and native byte CAS. It is a root/group-0
owned, single-link 0600 file of at most 64 KiB. Its exact fields are
`schema_version` (integer 1), scope `linux_current_release`, `owner_sha256`,
`selection_generation`, `release`, `selected_nonce`, `intent_sha256` and
`configuration`. Configuration is the exact format-2 path/hash map derived from
the selected artifact. Generation zero requires an empty journal and the original
identity with null nonce/digest. Each selection increments generation exactly once,
up to the journal's 16-update capacity.

Selection binds the exact final intent in `target_running`, with the current
release equal to its source. The intent digest is SHA-256 of a canonical UTF-8
frame: `WOTEX_HOME_UPDATE_SELECTION`, tab, frame version, newline; then tab-separated nonce,
source identity fields, target identity fields, original main PID, principal,
epoch, operation, expected revision and begin revision, followed by newline.
Identity field order is source revision, artifact, bootstrap and inventory digest;
integers use canonical decimal. The validated journal excludes tabs/newlines in
text fields. No phase name, credential or private device identity enters the frame.
Frame version 1 retains the exact encoding for legacy intents. Version 2 inserts
the nine retained process fields after original main PID in their order above.
Changing boot/start/invocation/image evidence therefore invalidates selected intent
binding even when PID is unchanged. A format upgrade alone preserves the exact
completed legacy selection digest and does not manufacture process evidence.

Both the old and new selection are readable during `target_running`, covering
interruption on either side of selection publication. `selected` and `complete`
require the new selection; earlier phases retain the previous completed selection.
Readers and writers recheck the actual durable journal before and after selection
I/O. A caller-provided future phase cannot substitute for persisted progress.
Stale byte CAS, skipped generations or substituted intent refuse without replacing
retained bytes.

Repeat/uninstall preserve immutable initial owner bytes and the state record's
original owner digest. They derive an effective owner from completed selection,
verify both the original payload and selected payload against retained bootstrap
and inventory pins, and require the supplied artifact/configuration to match the
selection. Whole-bootstrap verification also covers inventory-file metadata that
the inventory deliberately excludes from its own content map. Uninstall/reinstall
retain the account, private data and update history; they do not end maintenance,
reactivate rules or choose an old fallback.

These are internal coordinator primitives. There is no public update action yet.
Live owned process/image/cgroup, kernel peer, compatible schema and original active
barrier joins remain requirements for the coordinator, not facts established by
administrative phase records.

## Coordinator sequence

### Owned installation entry

`LinuxInstaller.inspect_update/1` requires the actual marked lock and a completed
initial installation. It reads closed original owner/state records with integer
format versions, validates the original full payload pin, host cohort, foreign
namespaces, service account and private-state custody, and returns original bytes
and the independently derived initial inventory pin. It performs no account,
configuration, registration or service mutation and opens no Store. It remains
usable when an update is pending, so a resuming coordinator can inspect original
ownership without invoking initial-repeat semantics. The coordinator separately
loads actual journal/selection and joins current configuration and live process;
this entry observation alone grants no maintenance or switch authority.

### Live process and stopped-cgroup prerequisites

`LinuxInstallHost.controller_registration/1` reads the exact seven status
properties plus `ControlGroup` and `InvocationID`, with explicit `--all`.
A running controller requires `/system.slice/wotex-home.service` and a nonzero
32-digit lowercase invocation identity. Stopped registration permits only the
same or empty cgroup and the retained or empty invocation. Expanded, duplicate,
missing or changed registration refuses.

`LinuxUpdateProcess` first verifies the supplied format-2 release against exact
source/artifact, whole-bootstrap and inventory pins under protected root custody.
Exactly one inventoried `erts-VERSION/bin/beam.smp` must be a root/group-0-owned,
single-link 0755 image of 1–64 MiB. The coordinator must still scope that supplied
release to the owned selected/source or target namespace.

The native marked-lock `observe-process` primitive holds the actual `/proc/PID`
directory while reading only stat/status/cgroup, executable and kernel boot
identity. Its held process directory prevents numeric PID reuse from redirecting
later reads. It accepts only live R/S/D/I process states and the bounded current
52-field stat shape, retaining the canonical start tick. All UID/GID slots must
equal the recorded service ID; supplementary groups are empty or that same ID.
Inheritable, permitted, effective, bounding and ambient capabilities are zero,
and `NoNewPrivs` is 1. The actual executable path, device/inode, owner, mode,
link count, size and metadata must agree with the independently hashed pinned
image. Start, identity, image and membership are rechecked before returning the
closed `WOTEX_HOME_PROCESS` version-1 frame. No argv, environment, socket body,
Store handle or credential is read or retained.

The BEAM join reads kernel observations twice and registration on both sides,
requiring equal boot/start/image/account/cgroup and service invocation identities.
It can compare the exact retained original observation and separately require
the verified maintenance socket's kernel listening PID to equal that main PID.
The journal now retains the original incarnation before effects; the coordinator must join
the actual schema and original live barrier; PID equality alone does not close
those obligations.

The stopped join requires the actual `cgroup2fs` filesystem, stable stopped
registration and two equal native observations of the fixed controller cgroup.
The helper holds protected root-owned directory descriptors and refuses links.
An existing group must report exactly `populated 0`, `frozen 0` and an empty
`cgroup.procs`, checked twice with unchanged directory identity. The
[kernel's recursive populated field](https://docs.kernel.org/admin-guide/cgroup-v2.html#un-populated-notification)
also covers live descendants when the parent process list is empty. An absent
leaf is accepted only under its protected existing parent. These primitives
perform no stop, signal, cgroup write, restart or selection and grant no authority.

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

### Joined original maintenance segment

`LinuxUpdateMaintenance.activate/3` now joins the actual owned installation,
retained journal/selection, complete source and staged target pins, exact source
configuration, original process incarnation and authenticated Store before begin.
It accepts only the last original intent in `staged`, `begin_recorded` or
`maintenance_active`. Current selection must still name its source. Every
exchange repeats ownership, payload, configuration and journal custody, observes
the exact original process before/after, checks the kernel peer, and decodes the
closed typed response. Internal fixture overrides are absent from the CLI.

In `staged`, the actual schema-27 writable/fence-enabled normal status supplies
the original tuple, persisted through native byte CAS before any begin frame.
`begin_recorded` first joins the current principal/epoch and looks up that exact
operation. A peer-joined not-found permits only the original retry when status
is still normal at its original watermark. Lost reply or publication refuses
further progress; the next invocation reads actual retained bytes and resolves
the original lookup. Neither tuple nor incarnation is resnapshotted. Accepted
progress still needs original receipt lookup and fresh exact active-barrier
status before returning. An ended barrier, changed principal, revision, peer,
incarnation, payload or configuration refuses. Credentials appear only in the
bounded exchange and never in administrative history or diagnostic output.

This segment performs no stop, unit replacement, fence publication, target start,
selection or maintenance end. Its returned observation is not a durable lease
or future permission; the switch coordinator must repeat live joins at each
effect boundary. Eleven focused Linux cases exercise actual framed Store routes,
SQLite restart/history, complete root-owned payloads and native CAS. Cohort,
registration/process and socket peer are explicit fixtures. The joint run passes
93 Linux and 43 portable macOS cases. Actual installed systemd and complete
switch/resume qualification remain unfinished.

### Pending fence and owned stop

`LinuxUpdateMaintenance.inspect_source/2` now provides read-only owned source
custody in `maintenance_active`, `fenced` and `stopped`. It opens no Store and
does not interpret progress as live authority. `observe_active/3` permits only
the first two phases and repeats the original receipt/process/peer/status joins
without any begin route. These entries preserve the original owner and process
alongside actual journal bytes for the stop segment.

`LinuxUpdateStop.run/3` accepts only those same source phases. Before publishing
pending it requires owned running registration and a fresh exact original active
barrier. An absent guard is permitted only for the first update. Later updates
replace only the completed guard derived from the immediately preceding retained
intent, under original-byte CAS. An already identical pending guard resolves an
uncertain publication without rewriting it. Foreign or malformed guards remain
untouched. Publication uses the native bounded write and file/directory sync.
After publication the segment repeats the full active joins and verifies the
same guard bytes before recording `fenced`.

In `fenced`, a running unit requires the exact original PID, full live incarnation,
receipt and active-barrier joins again before one fixed owned-unit stop. Failed,
transitional or changed registration refuses. An uncertain stop sends no further
command in that invocation. Resume may observe the unit already stopped, with
the exact pending guard, owned source/target/configuration and repeated actual
stopped-cgroup checks before recording `stopped`. It does not require the stopped
source's socket or invent a replacement source process. A retained `stopped`
claim with a running/populated group refuses without another stop. This offline
administrative inspection grants no Store or physical authority; target boot
and eventual completion still require their own live original-barrier joins.

The segment changes no enablement, unit/configuration, account, selected release
or Store receipt. It performs no fallback, restart, target start or maintenance
end. Twenty-three focused Linux cases pass with actual root files/native CAS,
framed SQLite routes, Store stop/reopen and guard-enforced end/boot checks.
Registration/process/cgroup and captured service commands are explicit fixtures.
The joint ten-file suite passes 112 Linux and 44 portable macOS cases. Lost guard,
fenced/stop/stopped replies, end-before-publication, changed incarnation, populated
group and second-update predecessor CAS are covered. Target switching is described
below; intent planning/staging composition, public entry and installed systemd/
coexistence/power-loss qualification remain unfinished.

## Owned target switch and completion

The internal `LinuxUpdateSwitch.run/3` consumes only the retained `stopped`
through `complete` intent. At the stopped boundary, offline inspection accepts
only the exact source or target unit, permitting resolution of an uncertain
original-byte CAS. All other files retain the fixed profile. Foreign bytes,
links, custody changes or populated cgroups refuse before further effects.
The native replacement publishes/syncs only the owned controller unit. Exact
target configuration, pending guard and repeated empty-cgroup observations
surround fixed unit verification and daemon reload. Effective fragments/drop-ins
must match before recording `configuration_ready`.

The target starts through one fixed owned-unit command with no enablement,
restart-limit reset or old fallback. An uncertain start retains its phase;
resume may join an already running target without starting again. Fresh whole
payload pins and actual registration/kernel incarnation identify the target
before its first socket request. Every original-receipt/status exchange repeats
that same incarnation and kernel peer join. Current original principal/epoch,
schema 27, writable fenced Store and exact active begin must agree. The source's
immutable process record is never replaced with a target observation.

Only those live joins permit `target_running`, current-release byte CAS and
`selected`. Lost selection/progress replies resolve actual retained bytes;
already selected target records are not rewritten. Completion repeats target
and original active-barrier joins before replacing only the pending guard with
its exact completed record through native CAS/sync. The complete guard is then
rechecked with the current target before the journal reaches `complete`.

A separately authorized operator may end maintenance after completion of the
guard but before the updater receives its reply or records final progress.
That tail accepts the exact completed guard and selected target, original
historical begin receipt and fresh current permission/principal/epoch/schema
status; it does not demand the old barrier still be active. Pending stages
continue to require that exact active barrier. Credential rotation within the
original principal is allowed; changed principal or authority epoch refuses.
The updater never sends end, another begin, rule activation or a rollback.

The joint ten-file suite passes 129 Linux and 44 portable macOS cases.
Forty focused Linux cases pass, including lost replies at all remaining phases,
unit/selection/guard publication, parser/reload failure, changed effective units,
peer/incarnation/schema/principal/epoch refusal, actual credential rotation,
operator end after guard completion and a second update. The second-source
fixture now uses a temporary Store child to model the stopped service without
automatically reopening its database. Root files/native CAS and actual framed
SQLite restart fixtures establish software behavior; synthetic registration,
process, cgroup and captured command callbacks do not qualify installed systemd,
effective limits, coexistence or storage power-loss recovery. Intent planning,
inert staging composition and the public trusted update entry remain unfinished.

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

Selection and lifecycle checks pass 50 Linux cases and 24 portable macOS cases
with journal, installer and maintenance regressions. Linux cases use actual
protected root files, marked locks, byte CAS, inert target payloads and SQLite.
They cover selection publication, retained journal changes, completed repeat/
uninstall/reinstall, refusal of incomplete or stale selection, and changed
inventory metadata. Process/status/phase values and service callbacks in selection
fixtures are synthetic; they do not qualify an installed release switch.

The joined process/file/host/selection/journal/installer/maintenance run passes
71 Linux cases; 11 process/host portable cases pass on macOS. Actual Linux child
processes exercise held kernel reads, root executable pins, dropped UID/GID and
capabilities, missing no-new-privileges, wrong identity/hash/path and unlocked
refusal. Synthetic registration/process frames exercise changed incarnations and
peer joins. Cgroup event files and filesystem type responses are fixtures; their
actual native descriptor checks cover descendant population, frozen/live lists,
links and changed registration. No installed systemd stop or actual service
cgroup qualification is inferred.

Incarnation and format-upgrade checks pass 78 Linux cases with the joined
file/host/selection/journal/installer/maintenance suites and 30 portable cases
with actual SQLite maintenance. They cover same-PID replacement, closed typed
conversion, owner-account substitution, unchanged completed legacy selection,
unfinished legacy refusal, original-byte upgrade CAS and retained history.
Process values in these progress/upgrade fixtures remain synthetic. The Linux
file cases also reproduce and correct shared lock-marker cursor interference;
the original kernel flock and all ownership checks remain intact.
