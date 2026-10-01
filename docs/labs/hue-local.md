# Hue local Bridge lab

Goal: prove Hue lights remain controllable/observable through the local Bridge with WAN blocked.

- [ ] record Bridge model/generation/firmware;
- [ ] block WAN/public DNS;
- [ ] discover by local mDNS or configured address;
- [ ] perform explicit local enrollment and store credential privately;
- [ ] enumerate light resources/capabilities;
- [ ] map at least power/brightness and supported colour capabilities;
- [ ] exercise local update/event path;
- [ ] restart Bridge and recover Things;
- [ ] restart Home and preserve logical identity;
- [ ] compare overlapping Light semantics with LIFX in universal-light lab.

The implemented reader is `mix woh.hue.read INTERFACE IPV4 BRIDGE_ID PEER_SHA256 CA_PEM KEY_FILE [LIGHT_UUID]`. Obtain the exact bridge ID, approved CA and leaf fingerprint through trusted review first. The key file must be a bounded regular 0600 file containing the application key; the task takes the path, never the key on the command line. The selected interface must stay current across the check. Successful reports are lab evidence only and do not enroll a Thing. The reader neither pairs nor writes nor subscribes to events. A TLS rejection or changed pin requires review, never a fallback to HTTP.
