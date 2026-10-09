# Linux initial installation v1

Version: 0.1.5. Status: development implementation; installed-host qualification missing.

This workflow implements initial installation, same-artifact retry, cancellation
and state-preserving uninstall under the [release contract](WOH.16-release-recovery.md),
[service layout](linux-service-layout-v1.md) and
[installer file boundary](linux-installer-files-v1.md). Updates and rollback
must join Authority/Store maintenance and recovery; repeating initial setup
with another artifact refuses.

The separately tested internal [maintenance client](linux-installer-files-v1.md#authenticated-maintenance-client)
can consume the existing Authority barrier as the service UID using an
independently held credential. The separate [development update entry](linux-release-update-v1.md#complete-development-update-entry)
now composes the same-schema workflow through the trusted launcher. Format 2's
[compatibility and host fence](linux-release-update-v1.md) are implemented
independently. Legacy format 1 repeats/uninstall preserve their
exact original unit bytes and private data; they do not acquire update support.
The internal update journal now retains original intent and typed begin identity
under native CAS. Repeat/uninstall consume the selected current release only
after every retained update is complete. They verify original and selected payload
pins, preserve immutable owner bytes, and retain the account, private state and
update history across uninstall/reinstall. Incomplete, malformed, foreign or stale
selection/history refuses before account, configuration or service effects.
The complete development updater joins artifact compatibility, original
maintenance, stop/switch/restart and fresh barrier confirmation, with interrupted
phase recovery. Positive installed-host update qualification remains unfinished.
Journal phases grant no service or command authority.

## Entry and ownership

The separately trusted `native/linux/install` and `install.pl` require root,
`--development`, absolute source/manifest paths and an externally held SHA-256
pin. Independent bootstrap copies the verified whole payload to private staging
before inspected ERTS or Home code runs. Temporary storage must permit execution.
Ordinary completion/refusal cleans that invocation's temporary payload; a killed
launcher can leave inert staging. Runtime needs no compiler, network or package
installation. Integrity is not artifact authenticity or redistribution clearance.

The verified coordinator inherits the fixed marked kernel flock at
`/run/wotex-home-installer.lock`. Its descriptor must match the named inode;
mutating descendants retain that same open-file description. Descriptor-transfer
denial refuses before installation mutation. The CLI has no alternate root,
backend or unlocked fixture option. Crash dumps are disabled because the
privileged coordinator briefly observes local account metadata.

Initial observations require the exact verified artifact, Debian 13 arm64/pinned
libc, real systemd PID 1, cgroup v2, supported writable local mounts, protected
shared parents and absent Home namespaces. At most 16 locally unoccupied IDs
in 100–999 cause bounded NSS queries; resolver failure stops immediately. Foreign
accounts, groups, units, drop-ins, journal files, links or namespaces refuse.
Fresh cohort/path observations repeat after publication and before registration
or uninstall stop. The lock coordinates Home installers; root administration
remains trusted.

## Administrative records

Exclusive rename publishes only a complete verified/synced `/opt/wotex-home`
tree. Root/release directories are root-owned 0755; `.installer` is root-owned
0700. Immutable `owner.json` and mutable `state.json` are single-link regular
root-owned 0600 files of at most 64 KiB. Owner JSON has exactly these fields:

| Field | Meaning |
|---|---|
| `schema_version` | Integer 1 |
| `scope` | `linux_initial_installation` |
| `installation_id` | Random 64 lowercase hex characters; no household identity |
| `source_revision` | Verified full Home commit |
| `artifact_id` | Verified source/core payload digest |
| `bootstrap_sha256` | External whole-payload manifest digest |
| `profile` | Exact closed service profile |
| `account_id` | Integer UID/GID in 100–999 |
| `configuration` | Four absolute configuration paths and their SHA-256 hashes |

State JSON has exactly `schema_version`, `owner_sha256`, `generation`, `phase`
and `uninstall_from`. Schema is 1; owner digest binds immutable bytes. Generation
is a nonnegative signed 64-bit integer. Each transition increments it through
original-byte CAS, file flush/sync, atomic replacement and parent sync; exhaustion
refuses. These administrative records hold no bearer, grants, SQLite handle or
device receipt and cannot authorize control.

## Setup, retry and cancellation

Setup phases are `claimed`, `accounts_pending`, `accounts_ready`,
`configuration_pending`, `configuration_ready`, `registration_pending` and
`installed`, with `uninstall_from: null`. Pending phases precede corresponding
effects. Uncertain publication is resolved by verifying the retained owner,
payload and namespace and syncing the complete tree/parent before later effects.

The account has the recorded UID/GID, locked password, nologin shell, fixed
private home and opaque installation marker. Retry accepts exact owned absent,
group-only or ready states. Unlocked/altered accounts refuse. Private state is
created 0700 for that account without an enrolled Store or credential. Existing
state must retain exact ownership/mode; contents are preserved.

Configuration is published exclusively or verified as exact owned 0644 bytes.
Extra budget files refuse. `systemd-analyze --man=no verify` must succeed without
diagnostics, including after interrupted registration. Man page existence is
the explicit development exclusion. Effective fragments/drop-in paths must be
the expected owned set before enabling/starting. Active main-service state
precedes `installed`. Exact installed repeat verifies retained ownership, data,
configuration, effective units and active state without recreating accounts or
automatically restarting an operator-stopped controller.

Any owned setup phase may be cancelled. `uninstall_from` retains that original
setup phase during `uninstall_pending`, `uninstall_stopped` and `uninstalled`.
Later phases require ready accounts; early cancellation can retain absent or
partially created owned accounts. Foreign namespaces or changed configuration
still refuse. `uninstall_pending` precedes disabling/stopping Home and its named
journal/mount. Only successful stop permits `uninstall_stopped`, exact owned
configuration removal, daemon reload and `uninstalled`. Partly removed files
are accepted. Lost stop replies retry stop before removal; lost reload after
removal resumes without recreating units. Uninstall never starts Home.

Completed uninstall repeats verify absent configuration and retained ownership.
Reinstall uses original accounts, artifact and private data. Accounts, data,
release and administrative records are retained. Purge, release/staging
collection, hard state quota, free-space reservation, cross-schema upgrades and
rollback remain unfinished. Global package, journal, firewall, BlueZ and
unrelated service changes are outside this workflow. Physical dispatch defaults to disabled.

## Evidence

Eleven Linux-root workflow cases use real filesystem operations and shadow-utils
against isolated synthetic account files. They cover setup/repeat/reinstall,
lost account reply, parser/configuration refusal, stop/reload interruption,
partial cancellation, malformed owner/state, different artifact refusal and a
namespace changed before registration. Cohort/storage observations and systemd
callbacks are fixtures. Three portable account cases cover occupancy, resolver
failure and query budget. The focused installer/bootstrap/service suite passes
35 Debian arm64 cases; macOS excludes the Linux-root workflows.

A later twelve-case workflow run additionally checks legacy format-1
installation, exact repeat and uninstall against actual file/account primitives,
retaining private bytes. This is fixture lifecycle evidence, not installed
systemd or format-1 update qualification.

Actual parser, packaged BEAM descriptor inheritance, retained-lock process death
and minimal-runtime probes are separate development evidence. A container without
systemd PID 1 must refuse before account/configuration/controller effects.
Positive installed-systemd lifecycle, effective cgroups/mounts, restart
exhaustion, unrelated-workload coexistence, disk/storage power loss, signed
delivery, amd64 execution and physical qualification still need their own
evidence. Fixtures do not qualify devices or grant control.
