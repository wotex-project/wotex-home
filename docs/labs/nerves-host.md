# Nerves host lab

Future parity lane. The same Home domain/profile/rule fixtures used on macOS must run unchanged.

Qualify:
- exact Nerves target/image;
- Ethernet/WLAN recovery without WAN;
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
