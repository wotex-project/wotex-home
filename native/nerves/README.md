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
