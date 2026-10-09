# Linux release development

The shared service target is Debian 13 on arm64 and amd64. Initial arm64 OTP
assembly, inert service configuration and platform-specific payload/host probes are implemented. This
directory does not provide an installer, service registration, paired LAN
listener or installed-host qualification. amd64 assembly remains work, even
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
issued release. Atomic installation and rollback are separate unfinished work.
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
so zero exit status alone is insufficient. A future installer must require
both successful verification and no diagnostics before registration.

The clean `984fb970d85f4e7e015f7d29baa19926b82c3096` payload also passes the
minimal-runtime probe with `--cpus 2 --memory 512m --memory-swap 512m
--pids-limit 96`, 64 MiB temporary storage and the profile's scheduler flags.
This checks that bounded development fixture, not effective systemd limits,
maximum workload, disk containment, installed coexistence or hardware.
