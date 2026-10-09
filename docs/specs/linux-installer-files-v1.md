# Linux installer file primitives v1

Version: 0.1.8. Status: development mechanism; installed-host and storage qualification missing.

These primitives support the [service installer boundary](linux-service-layout-v1.md#installer-boundary)
under the [release contract](WOH.16-release-recovery.md). They manipulate only
administrative installation files and can consume the existing authenticated
maintenance API. They do not own SQLite, receipts, controller
identity, grants or device transport. An administrative progress record cannot
authorize Home control or substitute for maintenance/recovery.

## Packaging and execution

Linux assembly copies the two installer-file scripts and the two bootstrap
scripts into the Home payload's `priv/linux-install` before computing the
service artifact ID. Final inventory and the Home component/SPDX group bind
their bytes and modes. They add no native ELF or dependency update. An existing
tool directory refuses assembly. Native macOS assembly does not copy them.
They use Debian base Perl, IO::Handle, POSIX, Socket and SHA-256 tooling. This is
development integrity evidence, with artifact authenticity and redistribution
review still unresolved.

The file launcher clears inherited environment. The arm64 helper validates
Linux/aarch64/root, normalizes its own group to root and traverses absolute
paths with held directory descriptors and no symlink components. Parents are
root-owned without other writers; only sticky shared temporary ancestors are
allowed, with a protected immediate parent. Staged trees contain regular
single-link files and real directories owned by root, without special mode
bits or group/other writers. Tree bounds are 20,000 files, 20,000 directories
and 2 GiB. A future installation workflow must also bind those trees to the
verified artifact and its exact owned namespace.

## Publication and progress

Exclusive file publication and complete directory publication use Linux
`renameat2(RENAME_NOREPLACE)`. An occupied destination, including a symlink,
is preserved. Directory publication first checks a bounded private
`.installer/owner.json` against the caller's expected digest, then syncs files
and directories before the rename and both parents afterward. Retrying an
uncertain publication must verify the retained owner/payload and sync the
published namespace and its parent before creating accounts or registration.

Private progress replacement checks the original bytes' SHA-256 under the
installer lock, writes an exclusive temporary file, flushes its language
buffer, applies permissions, syncs the file, replaces atomically and syncs the
parent. New bytes, length and expected digest are bounded. Mode is 0600 for
private progress and 0644 for public unit configuration. Removal checks exact
owned regular bytes/mode before unlink and parent sync. Directory creation
sets and syncs declared owner/mode in an exclusive temporary directory before
no-replace publication and parent sync. A stopped creator cannot expose a final
state directory with incomplete ownership. Filesystem errors refuse;
an error after a rename is uncertain and requires original-record inspection,
not rollback by deleting an arbitrary destination.

## Inert update staging

Updates keep administrative ownership outside issued payloads. Under the
retained marked lock, `publish-release` scopes its source to
`BASE/.installer/update-stage-NONCE/release` and its exclusive destination to
`BASE/releases/ARTIFACT`, where NONCE and ARTIFACT are lowercase 64-digit
hexadecimal values. BASE is the exact parent of the caller-pinned original
`.installer/owner.json`. BASE and `releases` are root-owned 0755; `.installer`
and the stage root are root-owned 0700. `stage.json` is a separately pinned
root-owned single-link 0600 administrative record; it never enters the release.
Only that record and the optional `release` directory may occupy the stage.

`Woh.Tool.LinuxInstallStage.snapshot/5` observes a stage against the separately
pinned external bootstrap manifest. It admits only declared directories and
single-link files with exact complete bytes/modes, or 0600 byte-for-byte prefixes
of independently verified source files left by interrupted bootstrap copying.
The latter require the complete source file's pinned hash and mode. Missing
declared objects may describe an incomplete stage; changed bytes, unknown
objects and links refuse observation and remain untouched. Portable observation
grants no installation ownership or mutation permission.

The observation binds a bounded SHA-256 tree frame. Its first line is
`WOTEX_HOME_INSTALL_STAGE<TAB>1<LF>`, followed by sorted depth-first rows.
Directory rows are `D<TAB>OCTAL_MODE<TAB>RELATIVE_PATH<LF>`; file rows are
`F<TAB>OCTAL_MODE<TAB>DECIMAL_SIZE<TAB>SHA256<TAB>RELATIVE_PATH<LF>`.
The root path is `.`; numbers have canonical spelling. Names use the closed
ASCII path alphabet, with no links, special objects or alternate devices. The
native observer independently reconstructs this frame under held no-follow
descriptors before mutation. Bounds are 20,000 files, 20,000 directories,
2 GiB of observed bytes, 64 nested path components and 4 MiB of frame bytes.
The external manifest retains the bootstrap's stricter 10,000-file/1-GiB bounds.

Publication requires the expected whole-stage frame, stage marker, original
owner and copied inventory digests. It preserves an occupied destination,
syncs complete files and normalizes only payload directories to 0755 before
exclusive rename and parent sync. Payload file bytes and modes stay intact.
`sync-release` checks the same original ownership and copied inventory at the
exact published path, requires public directory modes, and syncs the retained
tree and parent. The caller must verify the complete pinned payload closure
before publication and again when resolving an uncertain publication; these
file primitives alone do not establish artifact compatibility or completeness.

`remove-stage` requires that same owned private namespace and exact whole-stage
frame before deleting anything. It repeats file hashes and held/named identity
before removal, syncing each directory and the parent. The caller may use it
only after a valid complete or source-prefix observation. It cannot remove a
published release, unrelated directory or Home state. Changed or foreign stage
content remains for explicit inspection. These are coordinator prerequisites;
they do not select a release, switch a service, end maintenance or collect old
installed payloads.

The [minimal-base packaged probe](../../native/linux/README.md#packaged-update-staging-probe)
now repeats full-payload publication/sync, exact source-prefix cleanup and
changed-byte preservation under the retained real lock. The clean `865cc08`
arm64 release passes with 1,471 bootstrap payload files and unchanged inventories.
Its flat maintenance guard also rejects malformed frames before connection and
all four allowed operation shapes before bearer transmission to a substituted
root peer. The fixture changes no installed Home service or Store; installed
lifecycle, coordinator interruption and storage qualification remain separate.

## Lock lifetime

The launcher claims a private marked kernel-flock file, refuses a foreign lock
or concurrent installer, and preserves its descriptor into the coordinator.
The coordinator's descriptor/path must agree. Each mutating helper duplicates
that same open-file description with `pidfd_open`/`pidfd_getfd`, checks its
private marker, inode/path and exclusive flock, and retains it for the whole
operation. A privileged child command has parent-death SIGKILL and a retained
lock-holding parent. Setup fails before file mutation when descriptor retention
is denied or unavailable; it has no unlocked fallback. The privileged installer
therefore requires these calls to be permitted for its own process descendants.
Runtime Home remains unprivileged and needs none of this installer access.

## Authenticated maintenance client

`Woh.Tool.LinuxInstallMaintenance.request/5` is an internal prerequisite for
updates. Under the retained installer lock, its native child clears supplementary
groups and drops all UID/GID privilege to the owned account ID in 100–999 before
reading a credential or connecting. It installs parent-death SIGKILL after the
UID change, repeats the original-parent check and disables dumpability. The
root parent retains the same kernel lock until that child completes. No bearer
is placed in process arguments, environment, a temporary file, administrative
records or diagnostic output. The caller supplies its independently held current
credential through a bounded pipe; installation ownership never provisions or
substitutes for `host:maintain` permission.

Socket traversal holds no-follow directory descriptors. Ancestors must belong
to root or the service UID without other writers, except root-owned sticky
temporary ancestors used by private probes. The immediate directory is
service-owned 0700 and the endpoint is a real service-owned 0600 socket. The
client connects through the held parent and verifies the listening peer's
actual `SO_PEERCRED` UID before sending a length-framed request. The existing
server still requires its same-UID peer and current bearer authorization;
root gains no socket exception.

The bridge permits only maintenance status, update status, begin and principal-private
original-operation lookup. It never ends maintenance or invokes device/rule,
provisioning, Store or recovery commands. The child exchange has a 15-second
deadline and 4 KiB framed input/response-body bounds. Its private output prefixes
the kernel-reported listening PID as four big-endian bytes; total output is at
most 4,100 bytes. `request_peer/5` returns that PID with the typed result so an
updater can compare it with the owned systemd main process. Strict response decoding checks closed
status/receipt shapes, integer bounds, epoch/operation correspondence and
unknown-outcome counts. A historical begin receipt is not proof that the barrier
is currently active: an updater must compare fresh status with that exact begin
revision before stopping or switching a release.

The native input guard accepts only the closed flat ASCII encoding emitted by
the internal client: unescaped strings and canonical nonnegative signed-64-bit
integers, with exactly the permitted fields. API version and numeric original
identity/revision fields keep their integer kind; a canonical 32-byte URL-base64
credential keeps its string kind. Duplicate fields, escapes, expanded containers,
trailing documents, noncanonical numbers and unsupported routes refuse before
opening a socket. The helper uses no `JSON::PP` or other optional Perl module;
the minimal declared Debian base image must be able to run every file/lock
operation. Typed response decoding remains in the existing bounded BEAM client.

The caller must retain its original epoch, operation ID and expected revision
durably before begin. A failed or lost reply authorizes no stop/switch and must
be resolved using that original identity. This primitive does not implement an
update journal, artifact compatibility, release switching or automatic rollback.

## Evidence

Lock-marker validation now opens a separate read-only description of the exact
held locked inode, with no-follow and matching metadata. The original description
still retains the kernel flock throughout the privileged helper's lifetime.
Validation never seeks or consumes that shared description's cursor. Concurrent
descendants previously shared its offset through `pidfd_getfd`, causing sporadic
marker refusals. A 128-descendant concurrency case and a deterministic original-
cursor preservation case failed before correction. The focused 23-case Linux
file/installer run passes afterward; no file mutation or ownership check is relaxed.

The marked-lock read-only `observe-process` and `empty-cgroup` primitives now
support the [live update joins](linux-release-update-v1.md#live-process-and-stopped-cgroup-prerequisites).
The process reader holds `/proc/PID`, verifies actual service UID/GID, empty
capabilities and no-new-privileges, joins the root-owned pinned executable, and
rechecks start/image/cgroup identity. It reads no command line, environment or
credential. The cgroup reader holds protected directory descriptors and checks
recursive population plus the direct process list twice; linked, populated or
frozen groups refuse. Neither primitive signals a process or changes registration.

The focused joint suite passes 71 Linux cases and the process/host portable
subset passes 11 macOS cases. Process kernel reads and root file/custody/CAS
operations are actual. Registration and cgroup event/type responses are synthetic;
an installed systemd lifecycle and effective service cgroup remain unqualified.

The actual Debian arm64 UAPI headers bind the selected syscall numbers:
setgroups 159, renameat2 276, prctl 167, pidfd_open 434 and pidfd_getfd 438. Five focused cases
check fresh packaging, exclusive writes/CAS/removal, atomic owned directories, complete publication and
changed/linked staging refusal. Linux exercises actual base-tool filesystem
operations; macOS exercises only packaging. An additional private Docker-VM
probe checks descriptor inheritance through the packaged BEAM. A second probe
duplicates the lock into a helper, kills its original coordinator, observes
concurrent setup refusal while the helper lives, then observes release after
the helper finishes. That development container allowed SYS_PTRACE and used
an unconfined seccomp profile solely within its own PID namespace; it is not
an installed shared-host or default-container qualification.

Flush/sync calls and process-crash probes do not prove storage power-loss
survival. Effective systemd lifecycle, disk containment, updates, unrelated
workload coexistence, physical qualification and signed delivery remain separate.

Five maintenance-client cases include closed-result/input refusal, an actual
private Store/server running as UID 211, root-peer rejection, unauthorized bearer,
original begin lookup/retry, restart-retained barrier, changed retry refusal,
wrong UID, linked parent, unlocked client and substituted listening UID. The
substituted listener receives no credential bytes. A waiting child has all
UID/GIDs 211, no supplementary groups or effective capabilities, and dies after
its root retaining parent is killed. These run only inside the private Linux
development namespace; the two pure cases also run on macOS. The native tests
require a marked inherited installer lock and permitted descendant descriptor
retention. Existing maintenance transaction and installer regressions accompany
them; no installed systemd or physical evidence is inferred.

Eight staging cases pass on the pinned Debian arm64 builder, with real marked
locks, exclusive rename, sync and scoped cleanup. They cover empty/complete
observations, interrupted source prefixes, malformed manifests, changed bytes,
unknown objects, links, occupied destinations, wrong digests, original-owner
changes and unlocked/out-of-scope refusal. The four portable cases also pass on
macOS. The combined staging/file/bootstrap run passes 19 Linux cases and eight
macOS cases; syscall access is permitted only in its private development
container. Issued release assembly and installed service/update qualification
remain separate checks.

A fresh packaged probe exposed the former unconditional `JSON::PP` import as
absent from the minimal declared Debian image. The replacement closed parser
passes base-image syntax checking and 31 Linux maintenance/staging/file/installer
cases under the real marked lock. Seventeen malformed frame variants reach no
socket; a valid control reaches a substituted listener and is refused by its
kernel UID before bearer transmission. The source staging fixture explicitly
sets public inventory mode before pinning, so the launcher's 0077 umask cannot
create a different fixture payload. Fresh packaged execution is still required
for the corrected source; syntax and builder fixtures do not establish it.
