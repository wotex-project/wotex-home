# Linux release development

The shared service target is Debian 13 on arm64 and amd64. Initial arm64 OTP
assembly, inert service configuration, a development initial/repeat/uninstall
workflow and platform-specific payload/host probes are implemented. Actual
installed-systemd qualification, upgrades, disk containment and a paired LAN
listener remain work. amd64 assembly remains work, even
though the direct-ELF checker understands that target.
Home retains one Authority and one Store, with physical dispatch disabled by
default. Building a release does not authorize hardware effects.

## Development assembly

Use the repository's `.tool-versions` and `mix.lock` on an arm64 Linux build
host. Fetch and compile the pinned dependency sources, and obtain the pinned
public LIFX registry before running the fresh-source release runner:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=prod EX_MAUDE_BUILD_CNODE=0 mix deps.get --check-locked
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=prod EX_MAUDE_BUILD_CNODE=0 mix deps.compile
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=prod mix woh.lifx.registry.fetch
WOTEX_HOME_GIT_DEPS=1 EX_MAUDE_BUILD_CNODE=0 elixir bin/build.exs --dependency-env prod
```

Build from clean committed source. The runner freshly compiles Home and
explicitly reuses only the selected build host's dependency cache. macOS native
dependencies cannot supply a Linux cache. The Debian packages and tools must
match [the pinned arm64 native profile](native-libraries-arm64.json); a newer
provider requires a reviewed profile/input update and fresh checks. The build
host needs `dpkg-query`, GNU `readelf` and `patchelf`. They are build tools and
are not shipped as runtime dependencies. Assembly removes the unused Maude
binary/library tree and C-Node bridge on Linux arm64, preserving the model
source and legal inputs. Unsupported assembly platforms refuse.

Before probes or final reports, assembly copies the six exact GCC, C++,
terminal, OpenSSL, zlib and zstd providers into `native/linux-libraries/lib`.
It checks Debian binary/source package versions and original byte hashes,
copies the pinned copyright and common-license inputs, and replaces every
ELF's RUNPATH with its own release-relative vendor path. Provider files use
`$ORIGIN` and must also match their pinned post-patch hashes. No system package,
library, service or loader configuration is changed. The manifest records the
profile, transformation digests and direct-load result. The build runner
rechecks this bundle and the complete inventoried native closure before
reporting a successful development release.

This step accepts only owned, fresh, unissued Mix staging; existing generated
reports or a native bundle refuse. All provider and legal inputs are checked
before writes. A later tooling failure can leave incomplete staging, which
receives no final reports and must be discarded. It does not overwrite an
issued release. Verified initial namespace publication is implemented; upgrades
and rollback are separate unfinished work.
The [native input record](../../docs/provenance/linux-native-libraries.md)
describes package provenance and unresolved redistribution review.

The payload probe verifies CLI/recovery startup and checks that the missing
checker yields an inconclusive result with no checker receipt. An unexpected
packaged or ambient Maude backend refuses that probe. Its success message says
`unavailable-verifier refusal`; it does not claim a working verifier. Packaged
Store/schema/retry/restart/backup probes and the component/SPDX/inventory checks
remain required. Their synthetic private state grants no household authority
and supplies no qualified clock or device effect.

Use the printed release path for the separate real host/socket check:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=prod mix woh.release.smoke RELEASE_PATH/bin/wotex_home
```

The build host needs its `kill` executable for this probe's private child
shutdown. Missing `kill` refuses before host launch. The probe confirms private
Store/socket modes, framed authentication refusal and socket cleanup after
shutdown. It registers no service and modifies no household state. A Debian 13
arm64 development prototype passed these checks with networking disabled.

The native closure check below must pass for the assembled payload. These
unsigned development checks do not establish a portable installed shared-host
package, service lifecycle or physical qualification.

## Direct native closure

From the repository root, inspect an inventoried Linux release with:

```sh
WOTEX_HOME_GIT_DEPS=1 mix woh.linux.native.deps.check RELEASE_PATH arm64
```

Use `amd64` for that architecture. The build host needs GNU `readelf`; the
checker never runs `ldd` or executes the inspected native files. It verifies
the complete existing release inventory before and after inspection. Every
ELF must have the selected 64-bit little-endian architecture and executable
or shared-object type. Foreign Mach-O/PE files, symlinks and payload drift
refuse inspection. One native BEAM executable is required.

Only the declared glibc platform libraries and the exact architecture's
loader are external. Debian 13 supplies
[glibc 2.41](https://packages.debian.org/trixie/libc6); newer or private glibc
symbol-version requirements refuse. Other direct loads must resolve to
inventoried ELF files through the referring file's own `$ORIGIN` or
`${ORIGIN}` RUNPATH. Empty, absolute, ambient and escaping paths, old RPATH
and alternate dynamic load/search tags refuse. Dependency counts, search
paths, native file counts, tool output and command duration are bounded.

The JSON result records each native file's direct dependencies, interpreter,
RUNPATH and glibc symbol versions. Its scope is `direct_elf_loads_only`:
dynamic `dlopen`, native symbol correspondence, artifact authenticity, legal
clearance, host resource limits, systemd lifecycle, storage power loss,
coexistence and physical transport need separate evidence. A checker pass is
not an installed-service pass. No privileges or host configuration are needed
for this check.

Run the focused regression with the pinned toolchain and already-built test
dependencies:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test elixir bin/test.exs test/linux_native_deps_check_test.exs test/release_inventory_test.exs
```

On Linux with `cc` and GNU `readelf`, the suite additionally compiles an actual
executable and shared library, checks their release-relative loads, and then
renames the provider to demonstrate refusal. The header/parser fixtures on
macOS do not execute that Linux case. A Debian 13 arm64 container with OTP
28.5.0.6 and Elixir 1.19.6 passed all seven checker cases with networking
disabled. This is development compiler/tool evidence; the Docker VM's kernel
does not qualify the shared system-service target. amd64 execution remains a
separate obligation.

The bundling and component regressions run with:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test elixir bin/test.exs test/linux_native_bundle_test.exs test/linux_native_deps_check_test.exs test/release_components_test.exs test/release_spdx_test.exs test/release_inventory_test.exs test/release_native_backends_test.exs test/release_smoke_test.exs
```

The pinned Debian 13 arm64 builder passed 34 cases with networking disabled.
Its compiled fixture forces all six providers and checks their actual packaged
loader paths. Altered provider bytes cannot be accepted by rewriting the
unsigned transformation digest; changed profiles, malformed records, missing
source legal inputs and linked or modified packaged copyrights refuse. macOS
runs 28 cases and omits the actual Linux compiler/loader cases. These tests do
not qualify a minimal runtime, systemd service or physical host.

The pinned ExMaude dependency has no Linux arm64 Maude executable. A future
arm64 package must report this unavailable backend honestly and refuse its
dependent reviews; copying a macOS or amd64 executable cannot supply it.

## Minimal development runtime

After the foreground host check, run the trusted
[runtime probe](runtime-smoke.exs) using the selected packaged release and its
full expected Home commit. It requires Debian 13 arm64, an unprivileged user,
no ambient Elixir/Mix/compiler/ELF build tools, distributed Erlang disabled and
no configured host, network capture, physical dispatch or component runner.
It creates only its own temporary private Store and socket. The source
revision and complete inventory are checked before use, and the inventory is
checked again after both starts. All six providers must appear at their
packaged paths in the running VM's process maps. CLI/recovery startup and the
unavailable-verifier refusal are included. Shutdown must remove the socket
while retaining the private Store for the second start.
Wrong expected source and root-user runs were checked and refuse before
private Host launch.

For development, this can be reproduced in the pinned bare Debian image:

```sh
docker run --rm --network none --platform linux/arm64 \
  --read-only --user 10001:10001 --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
  --env LANG=C.UTF-8 --env ERL_FLAGS='+S 4:4' \
  --env RELEASE_TMP=/tmp/release-temp \
  --env WOTEX_HOME_RUNTIME_RELEASE=/release \
  --env WOTEX_HOME_EXPECT_SOURCE_REVISION=EXPECTED_FULL_HOME_COMMIT \
  --mount type=bind,source=ABSOLUTE_RELEASE_PATH,target=/release,readonly \
  --mount type=bind,source=ABSOLUTE_REPOSITORY_PATH/native/linux,target=/probe,readonly \
  debian@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f \
  /release/bin/wotex_home eval 'Code.eval_file("/probe/runtime-smoke.exs")'
```

The clean `cd377f23e93a4482903a72c16ba11bad353cb54e` release passed this probe
with glibc `2.41-12+deb13u4`: 1,446 inventoried files, 1,444 SPDX files mapped
to 36 components, and 27 checked ELF files. It also passed the build-host
foreground startup/authentication/shutdown probe and inventory verification
before and after that probe. Both minimal-runtime starts used UID/GID 10001,
a read-only container and payload, dropped capabilities and disabled network;
the runtime had no installed Erlang or compiler. No packages were installed
in the runtime image. The selected build host's dependency verification
rebuilt its exqlite cache from locked source with networking disabled; the
issued artifact remained unchanged.

The Docker VM supplies a development kernel. This evidence does not establish
systemd registration, an installer, unrelated-workload coexistence, measured
resource limits, shared-host storage durability or physical qualification.
Docker is used for this development probe and is not required by the intended
installed shared service. A minimal-runtime pass must not be reported as an
installed-service pass.

## Inert service configuration

Linux assembly packages the
[service profile](service-profile-arm64.json) and its generated configuration
under `native/linux-service/`. The
[closed layout](../../docs/specs/linux-service-layout-v1.md) defines account,
paths, payload identity and containment. The launch path names the hash of
the source/core payload, so a rebuilt different payload cannot borrow the
same directory merely because its source commit matches. The complete
inventory covers the service manifest and four configuration files. They
have their own Home-authored component/SPDX group; packaging never creates
accounts, writes system directories, registers services or mounts filesystems.

Verify an inventoried package with:

```sh
WOTEX_HOME_GIT_DEPS=1 mix woh.linux.service.package verify RELEASE_PATH
```

The chosen development main-process bounds are two CPU cores, 512 MiB memory
maximum, no swap and 96 tasks, with finite restart backoff. The named journal
has separate CPU/memory/task limits and a Home-owned volatile 32 MiB tmpfs.
Durable-state hard quota is not implemented. Those declarations must not be
described as qualified capacity or effective host enforcement.

The focused service regression is:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test elixir bin/test.exs test/linux_service_package_test.exs test/linux_native_bundle_test.exs test/linux_native_deps_check_test.exs test/release_components_test.exs test/release_spdx_test.exs test/release_inventory_test.exs test/release_native_backends_test.exs test/release_smoke_test.exs
```

Forty cases pass on the pinned Debian arm64 builder with networking disabled.
The actual Debian `systemd-analyze` 257 (`257.13-1~deb13u1`) accepts the
generated controller/mount units and namespace-specific journald drop-in
with `--man=no verify` and no diagnostics. Man page existence was excluded
because the tool image has none. An injected unknown drop-in key emits a
diagnostic, confirming that the drop-in was loaded; systemd ignores such keys,
so zero exit status alone is insufficient. The development installer requires
both successful verification and no diagnostics before registration.

The clean `984fb970d85f4e7e015f7d29baa19926b82c3096` payload also passes the
minimal-runtime probe with `--cpus 2 --memory 512m --memory-swap 512m
--pids-limit 96`, 64 MiB temporary storage and the profile's scheduler flags.
This checks that bounded development fixture, not effective systemd limits,
maximum workload, disk containment, installed coexistence or hardware.

## Independent bootstrap staging

The build runner now prints `RELEASE_PATH.bootstrap.tsv` and its SHA-256 after
verifying the final inventory. The external manifest includes every payload
file and the inventory itself. The [closed format](../../docs/specs/linux-bootstrap-v1.md)
defines bounds, paths and the independent trust boundary. Retain the pin and
the launcher through trusted build/operator custody; a pin read from the same
untrusted payload does not authenticate that payload.

Use a separately trusted copy of `bootstrap` and `bootstrap.pl` together:

```sh
native/linux/bootstrap ABSOLUTE_RELEASE_PATH ABSOLUTE_MANIFEST_PATH EXPECTED_SHA256 ABSOLUTE_PRIVATE_DESTINATION
```

The destination must be absent, with a caller-owned parent that other users
cannot write. Debian base Perl and `sha256sum` suffice; no package installation,
Home, Erlang or inspected executable runs. The launcher clears inherited
environment. All copied bytes/modes are verified, directory writes are anchored
to held descriptors, and staging directories stay 0700. Existing destinations
refuse without modification. Exceptions clean this invocation's partial copy;
crash recovery remains an installer obligation. This command never creates
accounts, publishes a release, registers units or starts a controller.

Run the focused producer and Linux execution cases with:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test elixir bin/test.exs test/release_bootstrap_test.exs test/release_inventory_test.exs
```

The bare pinned Debian image also verified an inert copy of all 1,455 files
from the clean `a702d195bfc34b5cb73a6b44990cef6bcb8ac04a` release as root
and UID/GID 10001, with read-only payload/root, dropped capabilities and no
network or added packages. This is bootstrap development evidence, not a
rebuilt current-source artifact or installed-service qualification.

## Initial installation read barrier

`Woh.Tool.LinuxInstallPreflight.check/3` is an internal read-only prerequisite
for the initial installer. It requires a verified external bootstrap pin
and exact service package, Debian 13 arm64 with the pinned libc, real systemd
PID 1 and cgroup v2. Initial setup refuses existing Home accounts/groups, loaded
or registered Home units, reserved paths and unsafe parent components. Mount
inspection selects the deepest applicable mount; local writable ext4/xfs/btrfs
are accepted, with execution required for `/opt` and optional for private state.
No accounts, files, services, data or physical dispatch are changed.

The [service layout](../../docs/specs/linux-service-layout-v1.md#installer-boundary)
records the boundary. This initial plan is not write authorization, a complete
installer preflight, a free-space reservation or a repeat/update workflow.
Those operations must recheck under the installer lock and preserve the
existing maintenance/recovery lifecycle. Actual installed-host evidence remains
missing; the current container environment correctly refuses installation.

The focused checks are:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test elixir bin/test.exs test/linux_install_preflight_test.exs test/release_bootstrap_test.exs test/linux_service_package_test.exs
```

Debian arm64 runs four preflight cases, including actual private foreign paths
and the real PID 1 refusal. macOS runs the two pure cohort/mount cases and
excludes Linux execution. No fixture plan registers a controller.

## Installer file operations

Assembly now includes the
[bounded installer primitives](../../docs/specs/linux-installer-files-v1.md)
in the Home component. They provide private kernel-lock custody, verified
bootstrap copy, exclusive publication, journal CAS, scoped removal and explicit
file/directory sync. They do not provide a controller credential or touch its
Store. Root installer helpers require permitted descriptor duplication for
their own descendants; denial refuses before writes. The Home runtime remains
unprivileged and does not need these installer facilities.

Five focused file cases run on Debian arm64, including actual publication,
foreign-byte preservation, mode/CAS/removal and symlink refusal. macOS runs only
the portable packaging case. A private process-death probe confirms that a
helper retains the original kernel lock after its coordinator dies and releases
it on completion. Its container permits SYS_PTRACE and disables its own seccomp
filter; that is development syscall evidence, not shared-host qualification.
Power loss, effective systemd, disk containment and installed coexistence still
need their own evidence.

## Development initial installation

The [closed workflow](../../docs/specs/linux-installation-v1.md) implements
initial setup, exact repeat/retry, partial cancellation, state-preserving
uninstall and same-artifact reinstall. It remains unsigned development software;
positive installed-systemd lifecycle and shared-host qualification are missing.
Do not infer hardware qualification from successful installation. Home's
physical dispatch default remains disabled.

Keep a trusted copy of `install`, `install.pl`, `bootstrap` and `bootstrap.pl`
together, plus the independently held external manifest and its pin. On the
declared Debian 13 arm64 host, the concrete entry points are:

```sh
sudo native/linux/install --development install ABSOLUTE_RELEASE_PATH ABSOLUTE_MANIFEST_PATH EXPECTED_SHA256
sudo native/linux/install --development uninstall ABSOLUTE_RELEASE_PATH ABSOLUTE_MANIFEST_PATH EXPECTED_SHA256
```

Only these actions and inputs are exposed. The temporary filesystem must allow
execution and root must be permitted to retain its own descendants' lock
descriptor. Unsupported cohort, descriptor transfer, foreign ownership or
changed payload/configuration refuses. The launcher executes inspected code
only from its independently verified private copy. No global packages, firewall,
BlueZ or unrelated services are changed.

Repeat the same command/inputs to resolve interrupted owned progress. Do not
delete the ownership record, replace a unit or reset service restart limits to
bypass a refusal. A stopped installed controller is reported rather than
automatically restarted by repeat setup. Uninstall first disables/stops Home and
its named journal/mount, then removes exact owned configuration; accounts,
private state and release are preserved. An interrupted uninstall must finish
before reinstall. A different artifact requires the unfinished update/recovery
workflow. Purge, stale-stage collection, free-space reservation and hard durable
disk containment remain work.

Run the focused development checks with:

```sh
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test elixir bin/test.exs test/linux_installer_test.exs test/linux_install_host_test.exs test/linux_install_files_test.exs test/linux_install_preflight_test.exs test/release_bootstrap_test.exs test/linux_service_package_test.exs
```

The pinned Linux arm64 builder passes 35 cases with networking disabled.
Workflow fixtures use actual file primitives and shadow-utils with isolated
synthetic account databases; systemd/cohort/storage callbacks are fixtures.
macOS runs the portable account/packaging cases and omits Linux-root execution.
Actual systemd startup, effective cgroups, coexistence, storage power loss and
physical evidence remain separate obligations.
