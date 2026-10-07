# Raspberry Pi 4 development firmware

This Nerves project embeds the same `wotex_home` application as macOS. It uses
`nerves_system_rpi4` 2.0.x and stores the Home SQLite database and private
socket under `/data/wotex-home`. The initial image has no driver handoff,
commissioned radio, production credential broker, model, or ARM Maude binary.
It configures wired `eth0` for IPv4 DHCP with VintageNet. The image has no
Wi-Fi provisioning, SSH, mDNS or network API listener. VintageNet's external
connectivity host list is replaced with loopback so it does not probe public
DNS providers; the default network configuration is not persisted outside the
read-only image. A board lab still needs WAN-free DHCP and packet evidence.
It does not automatically mark a new firmware slot good. Do not deploy it as
a home controller or infer a rollback result from an image build.

From this directory, run `WOTEX_HOME_GIT_DEPS=1 MIX_TARGET=rpi4 EX_MAUDE_BUILD_CNODE=0 mise exec -- mix deps.get --check-locked`
and `WOTEX_HOME_GIT_DEPS=1 MIX_ENV=prod MIX_TARGET=rpi4 EX_MAUDE_BUILD_CNODE=0 mise exec -- mix firmware`.
The Git setting keeps this firmware build on the two exact upstream revisions
even if neighboring development checkouts exist.
The `.tool-versions` file matches the target's OTP 28 major version. The resulting `.fw`
is a development image. Do not burn or upload it to an unidentified board.

For socket-restricted host-side checks with already-built root test dependencies,
run `elixir bin/test.exs --socket-free --firmware-host` from the repository root.
This freshly compiles the Home code and board-probe modules and runs their
deterministic mount/USB/slot fixtures. It neither starts Nerves services nor
cross-builds a new image, and it cannot replace on-board tests.
The cross-built release also includes pinned Maude license/notice files for its
retained standard libraries and canonical Apache 2.0 texts for the two locked
Hex dependencies; the image checker verifies them. No Maude executable is
packaged for this ARM target.
From the repository root, run `mix woh.nerves.image.check native/nerves/_build/rpi4_prod/rel/wotex_home_firmware native/nerves/_build/rpi4_prod/nerves/images/wotex_home_firmware.fw` to verify the ARM executable closure and record the image hash before board tests. This is packaging evidence only.
Also run `mix woh.nerves.serial.check ~/.nerves/artifacts/nerves_system_rpi4-portable-2.0.4/images/rootfs.squashfs --require <selected-driver>` after identifying the coordinator's USB bridge. The known choices are `cdc_acm`, `ch341`, `cp210x`, `ftdi_sio` and `pl2303`. This inventories the cached system artifact only; verify the bound driver and stable device path on the board.
Before board validation, record board revision, storage, power supply, system
and firmware hashes; exercise WAN-free boot, Store integrity, slot validation,
rollback, power-cut recovery and coordinator removal using the WOH.09 lab.
Capture `Nerves.Runtime.firmware_slots/0` and `Nerves.Runtime.firmware_validation_status/0` on both tentative and reverted boots. `:unknown` is an unresolved status. Do not enable `StartupGuard` solely to make a tentative image persist: its OTP-start check does not establish Home data compatibility or authority recovery.
At the local board console, `WotexHome.Firmware.BoardSnapshot.capture()` records those fields with the current Home Store health without validating the slot. Keep the output in private lab evidence alongside the exact system and `.fw` hashes. A successful snapshot is only one observation, not a pass for H09-T3 or H09-T4.
With the selected coordinator attached, `WotexHome.Firmware.UsbInventory.capture()` reports USB VID/PID and bound interface drivers without copying device serials. Run it before and after unplug/reconnect, then record the actual tty and stable path privately. It neither opens the NCP nor forms a Zigbee network.

The Mix release leaves its cookie randomly generated; copies of one image
contain the same cookie. This profile does not start Erlang distribution or an
SSH/network management service. The private local API uses
a Unix socket and still requires a provisioned principal credential. A future
remote maintenance profile needs per-unit credentials and explicit access
control before a network listener is enabled.

## Component runtime gate

The [component worker](../components/README.md) currently has desktop development
checks only and is absent from this firmware. Inclusion requires a pinned exact
rpi4 architecture/libc cross-build, image native/legal inventory, enforceable
memory/deadline containment and board restart/offline evidence. A macOS Wasmtime
build and portable `.wasm` do not satisfy that gate. No plugin becomes active on
this target until the Store lifecycle and exact mapping are also qualified.

The [portable profile plan](../../docs/plans/portable-profile-admission.md) allows
data-only parity without this engine. Future data delivery must test durable
artifact publication, quota/retention, offline local approvals and quarantined
dependency transfer on the exact Pi 4 storage/firmware. Those board cases remain
open; a data artifact or another project's Pi result cannot qualify this image.

The shared Home host now creates/opens private `profiles/` beneath the owned data
directory after Store obtains its lock, and supervises the transient profile
review owner before consumers. Existing nonprivate/symlink roots are refused.
Custody/review restarts discard pending proposals and stop downstream workers
while retained Store history remains intact. Root host fixtures cover this
ordering; a fresh Pi firmware build and actual `/data` publication, restart and
power-cut lab remain required. This change neither validates a firmware slot nor
qualifies physical profile use.

The shared headless profile API/CLI now uses the same nine closed routes as the
foreground macOS host, including bounded byte import, review preparation,
selection/revocation and principal-private original status. See the
[API mechanism](../../docs/specs/portable-profile-api-v1.md) for exact fields and
uncertain-reply recovery. Root software tests do not establish their availability
in a fresh image or durable publication on Pi storage; build/check that image and
run the board lab before qualifying those properties.

## Trusted portable-profile recovery

Run these shared development commands from the Home repository root.
Stop the existing controller before taking ownership in a foreground Mix process.
With the same private data directory selected,
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/recovery.exs export /absolute/archive.backup`
exports an encrypted consistent database plus every retained exact profile byte.
Supply the 32-byte key as exactly 43 unpadded URL-safe Base64 characters plus LF
through stdin from separate trusted custody. Never put the key in arguments,
environment, logs or beside the archive. Export fails if any retained byte is
missing/corrupt; it does not substitute another version or copy inert orphans.

Offline `mix run --no-start bin/recovery.exs verify /absolute/archive.backup`
reports validated history and exact included/external dependencies.
`mix run --no-start bin/recovery.exs stage /absolute/archive.backup /absolute/new-directory`
uses the same stdin key and creates a new directory under an existing canonical
private 0700 parent. It never overwrites existing content. The result contains
0400 immutable objects under `profiles/` and 0600 `home.sqlite`, already marked
as restore quarantine. A database-only archive with portable dependencies
cannot claim complete byte transfer. Verification/staging do not start Home.

Do not point a controller at this directory or remove its quarantine marker.
Store refuses startup. Fenced activation still requires old-writer isolation,
credential/authority review and radio-counter continuity; those requirements
are separate from the byte-transfer check. Registry metadata, qualification
packages/reviewer keys and device credentials/counters remain external.

The shared trusted source-delivery commands are
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/bootstrap_transfer.exs`
for separate `host:transfer` custody, and
`WOTEX_HOME_DATA_DIR=/absolute/private/directory mix run bin/recovery.exs retire-export EPOCH OPERATION_ID EXPECTED_REVISION DESTINATION_OWNER_ID /absolute/archive.backup`
after the existing maintenance barrier. The latter consumes the original
transfer credential then archive key as two private stdin lines; neither belongs
in arguments, environment or logs. It permanently retires source writes,
verifies original receipt/byte correspondence and stops the owning Host.

Interrupted delivery uses
`mix run --no-start bin/recovery.exs export-retired /absolute/canonical/source-directory /absolute/archive.backup`
with only the key line. The locked offline reader starts only retired Store and
custody, performs no migration and closes both afterward. Matching existing
archives are exact retries; wrong keys/archives, normal sources and quarantine
are refused. These are shared repository development commands, not a claim that
a flashed board provides installed operator custody or survives a power cut.
Physical old-writer isolation, radio-counter continuity and destination
acceptance remain separate gates.

The shared OTP payload now includes `bin/wotex_home_recovery` with the same
arguments and private stdin custody, plus explicit `bootstrap-transfer` setup.
`new-owner /absolute/private/operator-custody/owner.json` takes no key and starts
no Home service. It creates immutable 0400 destination identity under an existing
canonical 0700 parent outside the archive/restore directory. Use the returned
public `owner_id` as the explicit source retirement destination. This file grants
no permission or activation and is never overwritten.
This provides a checkout-independent entry point; its presence/execution in a
particular appliance image still requires that image's build and board checks.
