# Raspberry Pi 4 development firmware

This Nerves project embeds the same `wotex_home` application as macOS. It uses
`nerves_system_rpi4` 2.0.x and stores the Home SQLite database and private
socket under `/data/wotex-home`. The initial image has no driver handoff,
commissioned radio, production credential broker, model, or ARM Maude binary.
It does not automatically mark a new firmware slot good. Do not deploy it as
a home controller or infer a rollback result from an image build.

From this directory, run `MIX_TARGET=rpi4 EX_MAUDE_BUILD_CNODE=0 mise exec -- mix deps.get`
and `MIX_ENV=prod MIX_TARGET=rpi4 EX_MAUDE_BUILD_CNODE=0 mise exec -- mix firmware`.
The `.tool-versions` file matches the target's OTP 28 major version. The resulting `.fw`
is a development image. Do not burn or upload it to an unidentified board.
From the repository root, run `python3 bin/check_nerves_image.py native/nerves/_build/rpi4_prod/rel/wotex_home_firmware native/nerves/_build/rpi4_prod/nerves/images/wotex_home_firmware.fw` to verify the ARM executable closure and record the image hash before board tests. This is packaging evidence only.
Also run `python3 bin/check_nerves_serial_modules.py ~/.nerves/artifacts/nerves_system_rpi4-portable-2.0.4/images/rootfs.squashfs --require <selected-driver>` after identifying the coordinator's USB bridge. The known choices are `cdc_acm`, `ch341`, `cp210x`, `ftdi_sio` and `pl2303`. This inventories the cached system artifact only; verify the bound driver and stable device path on the board.
Before board validation, record board revision, storage, power supply, system
and firmware hashes; exercise WAN-free boot, Store integrity, slot validation,
rollback, power-cut recovery and coordinator removal using the WOH.09 lab.
Capture `Nerves.Runtime.firmware_slots/0` and `Nerves.Runtime.firmware_validation_status/0` on both tentative and reverted boots. `:unknown` is an unresolved status. Do not enable `StartupGuard` solely to make a tentative image persist: its OTP-start check does not establish Home data compatibility or authority recovery.

The Mix release leaves its cookie randomly generated; copies of one image
contain the same cookie. This profile does not start Erlang distribution or an
SSH/network management service. The private local API uses
a Unix socket and still requires a provisioned principal credential. A future
remote maintenance profile needs per-unit credentials and explicit access
control before a network listener is enabled.
