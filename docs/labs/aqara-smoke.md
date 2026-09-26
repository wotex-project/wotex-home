# Aqara smoke detector — direct Zigbee qualification

Status: procedure ready for exact-device identification; physical tests not run.

## Inventory gate

The detector is purchased; its regional SKU, Zigbee fingerprint and firmware are not established by the conversation. The Aqara hub was not purchased. Record the retail/regulatory label, manufacturer manual revision, battery/date information, coordinator chipset/revision/firmware and USB interface. Do not publish serial numbers or IEEE addresses.

The third-party [JY-GZ-01AQ profile](https://www.zigbee2mqtt.io/devices/JY-GZ-01AQ.html) also lists JY-GZ-03AQ and warns about some firmware/coordinator combinations. Treat this as a test hypothesis and risk register. Do not automatically update or downgrade the purchased detector.

## Prepare

- [ ] Ensure the detector continues to provide its standalone function following its manual. Home is not the household's fire-protection system.
- [ ] Use a documented coordinator firmware and a private backed-up network. Confirm that only one application owns the serial port.
- [ ] Disable automatic OTA and all remote alarm/mute/linkage writes.
- [ ] Block WAN. No Aqara account or cloud service may carry telemetry.

## Enroll and inspect

- [ ] Follow the exact manual's physical pairing procedure within a finite permit-join window; do not guess button timing from another model.
- [ ] Capture Basic identity, endpoints, descriptors, clusters, power source and available versions under bounded interview limits.
- [ ] Match an exact profile; otherwise retain an unknown candidate. Pairing success does not permit every advertised action.
- [ ] Close joining and verify that another unsolicited device cannot enroll.

## Read-only behavior

- [ ] Map independently reported smoke, test, fault, battery and voltage only when actually supported.
- [ ] Follow the manufacturer's safe self-test procedure. Record siren behavior separately from radio reports; neither substitutes for the other.
- [ ] Confirm that self-test cannot create a real-smoke event or execute a production safety scene.
- [ ] Verify that silence/staleness does not clear a smoke fact or imply a dead battery.
- [ ] Restart the host, then disconnect/reconnect the coordinator. Network and Thing identities must persist without a factory reset.
- [ ] Test backup recovery on a dedicated cohort. Never restore stale outgoing security counters or operate two coordinators with the same identity concurrently.

## Stop conditions

Unexpected alarm behavior, missing expected reports, unknown firmware or ambiguous identity blocks the affected qualification. Preserve logs privately and return to the manufacturer's supported safety procedure; do not experiment with automatic hush or linkage commands.

Record a seven-day reporting/availability soak after basic tests. Report measured observations only, not an inferred multi-year battery lifetime. Changing coordinator or detector firmware starts a new affected cohort.
