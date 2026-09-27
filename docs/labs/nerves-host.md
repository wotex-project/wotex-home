# Nerves host lab

The `native/nerves` development image cross-builds for the locked Raspberry Pi 4
Nerves system. Cross-compilation does not qualify an installed appliance. The
repository's `bin/check_nerves_image.py` checks the built release architecture,
foreign native binaries and packaged VM arguments before board work; retain its
firmware hash with the private lab receipt. The
`mix woh.nerves.serial.check` checker inventories the selected system
artifact's USB serial modules; require the module for the recorded coordinator
bridge and then verify real USB binding on the board. The
same Home domain/profile/rule fixtures used on macOS must run unchanged on the
board. Record exact board revision, storage medium, supply, NCP and firmware
digest outside version control before touching the device.

Qualify:
- exact Nerves target/image;
- Ethernet/WLAN recovery without WAN;
- wired DHCP without WAN or public connectivity probes in the development image;
- durable state through reboot/power loss/update;
- same Zigbee coordinator over USB first;
- USB reconnect and coordinator backup/restore;
- Maude executable on exact ARM/Linux target;
- DistilBERT memory/latency/thermal behavior;
- watchdog/supervision;
- signed update/recovery;
- WAN-cut suite;
- semantic parity with macOS evidence.

A Pi model passing this lab qualifies only that exact target/profile.

The first board pass must boot with WAN disconnected, show the private
`/data/wotex-home` Store/socket and no actuator dispatch, power-cycle during
Store and firmware operations, then demonstrate both an unvalidated-image
revert and a separately validated image. Capture active/next firmware slots
and database/authority revisions before and after each reboot with
`WotexHome.Firmware.BoardSnapshot.capture/0` at the local console. Preserve
`:unknown` firmware validation status as unresolved. Keep the
original writer and coordinator isolated when testing a restored data image.
Do not mark a slot valid merely because the OTP application started.

With the coordinator attached, capture `WotexHome.Firmware.UsbInventory.capture/0`
before and after cold boot and USB reconnect. Compare its VID/PID and bound
interface driver to the selected module inventory and private coordinator
label. Record the actual tty and stable path separately. An unbound interface,
changed USB identity or missing expected tty blocks NCP qualification.
