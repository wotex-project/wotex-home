# Linux installer file primitives v1

Version: 0.1.1. Status: development mechanism; installed-host and storage qualification missing.

These primitives support the [service installer boundary](linux-service-layout-v1.md#installer-boundary)
under the [release contract](WOH.16-release-recovery.md). They manipulate only
administrative installation files. They do not own SQLite, receipts, controller
identity, grants or device transport. An administrative progress record cannot
authorize Home control or substitute for maintenance/recovery.

## Packaging and execution

Linux assembly copies the two installer-file scripts and the two bootstrap
scripts into the Home payload's `priv/linux-install` before computing the
service artifact ID. Final inventory and the Home component/SPDX group bind
their bytes and modes. They add no native ELF or dependency update. An existing
tool directory refuses assembly. Native macOS assembly does not copy them.
They use Debian base Perl, IO::Handle, POSIX and SHA-256 tooling. This is
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

## Evidence

The actual Debian arm64 UAPI headers bind the selected syscall numbers:
renameat2 276, prctl 167, pidfd_open 434 and pidfd_getfd 438. Five focused cases
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
