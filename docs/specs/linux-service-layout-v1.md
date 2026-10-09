# Linux service layout v1

Version: 0.1.2. Status: development packaging format; installed-host and resource qualification missing.

This closed arm64 configuration is subordinate to the
[release contract](WOH.16-release-recovery.md). It packages inert files for
the shared-service target. Packaging never creates an account, mounts a
filesystem, writes `/etc`, registers a unit or starts a controller. The
[profile](../../native/linux/service-profile-arm64.json) fixes its names and
initial containment settings. An installer and effective host qualification
remain separate work. amd64 needs its own native package and evidence.

## Identity and paths

The artifact ID hashes the clean Home source revision and the sorted core
payload's relative paths, modes, byte counts and SHA-256 values. Service files
and final generated reports are excluded to avoid a self-referential path.
Final inventory covers every service file and report. Identical source and
core bytes retain the ID; another source, mode or payload changes it. The
generated executable path is `/opt/wotex-home/releases/<artifact-id>/bin/wotex_home`.
No mutable `current` symlink or source-revision-only directory names a release.

The fixed account/group is `wotex-home`; no UID, password, bearer credential,
device identity or pre-enrolled home is shipped. The Store/custody namespace
is `/var/lib/wotex-home`, with its existing private `ipc/home.sock` endpoint.
BEAM temporary files use `/run/wotex-home`. State/runtime directories are
0700 and the service umask is 0077. Runtime is unprivileged, with a read-only
system view, inaccessible home directories, private temporary/device views
and no Linux capabilities. This initial profile grants no serial/radio device
access, configures no LAN listener and leaves physical dispatch disabled.

The service uses the existing Authority and single Store. Its process or log
failure cannot activate rules, refund causal spend, replay an uncertain handoff,
reset controller ownership or authorize another writer. Copied namespaces
and restarted services retain existing recovery/clock/qualification guards.

## Containment and logs

The development main-process limits are two CPU cores of quota, 384 MiB memory
pressure threshold, 512 MiB memory maximum, no swap, 96 tasks, 4096 descriptors
and no core dumps. BEAM has four ordinary, two dirty CPU and two dirty I/O
schedulers. Failure restarts wait five seconds, with at most three starts per
60 seconds. Shutdown sends SIGTERM to the main process and allows 30 seconds
before killing remaining owned processes. Losing the owned journal service
also stops the controller rather than leaving an unbounded logging producer.

Home uses only its named journal namespace. Its journald drop-in declares half
a CPU core, 96 MiB, no swap, 32 tasks and 4096 descriptors, with bounded restart
settings. A Home-owned mount unit provides a volatile 32 MiB tmpfs at
`/run/wotexhomejournal`; journald binds it at its own log directory. It does
not alter the default journal or another namespace. Rotation targets 16 MiB
retained data and 1 MiB files, with 100 messages per 30 seconds, no kernel reads
and no forwarding. Active-file overhead can exceed retention targets; 16 MiB
is not a hard footprint promise. Effective tmpfs capacity bounds the filesystem.
Volatile logs carry no receipts or recovery authority.

The four owned configuration files are the controller service, namespace
journal configuration, namespace-specific journald budget drop-in and
`run-wotexhomejournal.mount`. They are regular 0644 payload files under
`native/linux-service/etc/`, covered by the service manifest and final inventory.
The manifest has exact profile, source/artifact IDs and file hashes, with
registration `not_performed_by_packaging`, unresolved license review and no
authenticity claim. Its source must match the final inventory. Added, linked,
modified or widened-mode configuration refuses.

These are chosen development limits, not a qualified minimum machine or
measured shared-host capacity. Durable-state hard quota is explicitly
`not_implemented`. Release retention, Store/custody/backup disk bounds, helper
exhaustion, effective cgroups/mounts, journal pressure, restart exhaustion and
an unrelated workload require implementation and actual cohort evidence before
shared-service qualification. Container bounds and parsing do not establish it.

## Installer boundary

The initial read-only preflight now verifies the external bootstrap pin and
exact service report, then observes Debian/arm64/libc/systemd/cgroup metadata,
account/group and unit namespaces, every reserved path and its ancestors, and
the deepest applicable mounts. Required shared parent directories must exist,
be real root-owned directories and exclude other writers. An occupied Home
resource refuses instead of being adopted. ext4, xfs and btrfs local writable
storage are the initial allowed filesystems; the release mount must allow
execution. Private state may be on a no-exec mount. Network filesystems and
read-only mounts refuse. systemd must actually be PID 1.

Its plan is a development observation, grants no mutation permission and must
be rechecked under the installer's ownership lock. It does not create accounts,
reserve free space, publish files or register units. Existing installs are
refused by this initial-only barrier. The separate
[development installation workflow](linux-installation-v1.md) now implements
same-artifact repeats, interruption/cancellation and state-preserving uninstall.
Different-artifact updates remain work and require maintenance/recovery.
The actual Linux private-path probe checks unchanged foreign file bytes and
metadata and symlink-ancestor refusal. A container without systemd PID 1
refuses after fixture-payload verification. These are development checks, not
a fresh installed shared host or effective resource/physical qualification.

The development installer verifies the local artifact and exact effective profile
before registration. It refuses foreign accounts, namespaces, mount paths,
units, journal configuration, symlinks and conflicting ownership. systemd can
create/change ownership of declared directories, so preflight precedes any
unit start. Repeats verify the same artifact and preserve private data and
configuration. Interruption retains prior usable registration or identifiable
inert staging. Uninstall preserves private state unless its deletion is
separately explicit. Global package, journal, firewall, BlueZ and unrelated
service changes are outside this profile.

Debian documents directory/sandbox behavior in
[systemd.exec](https://manpages.debian.org/trixie/systemd/systemd.exec.5.en.html),
resource controls in
[systemd.resource-control](https://manpages.debian.org/trixie/systemd/systemd.resource-control.5.en.html),
restart/stop behavior in
[systemd.service](https://manpages.debian.org/trixie/systemd/systemd.service.5.en.html)
and journal rotation in
[journald.conf](https://manpages.debian.org/trixie/systemd/journald.conf.5.en.html).
