# Hardware qualification ledger

Reviewed: 2026-09-28. The operator reports all needed hardware available. Exact inventory and physical test results have not yet been recorded.

| Target | Possession / identity | Capability evidence | Next gate |
| --- | --- | --- | --- |
| Older EU LIFX bulbs | Owned; exact product/firmware pending | The read-only selected-interface probe, now using the pinned WoTEx UDP owner, found zero candidates on `en0` on 2026-09-28; no device identity obtained | Confirm power/Wi-Fi, then local discovery/version/state/control and WAN-cut |
| Aqara Smoke Detector | Purchased without hub; exact retail/Zigbee fingerprint pending | None recorded here | Manual/label, coordinator, read-only interview and independent alarm/report tests |
| Zigbee coordinator | Available per operator; exact chipset/firmware not yet recorded | None | Documented NCP/USB, firmware custody, exact detector compatibility |
| Hue Bridge/lights | Hardware available per operator; exact models not yet recorded | None | Exact bridge/local API and offline enrollment/control |
| Shelly devices | Hardware available per operator; exact models not yet recorded | A six-second local `_shelly._tcp` browse on 2026-09-28 found no advertised service; the read-only Gen2 interview has only scripted-peer evidence | Per-model local path and safety/load policy |
| Mac host | Intended first development host | No installed Home host exists in this record | Background service, IPC, permissions, USB, sleep/recovery |
| Nerves appliance | Hardware available per operator; exact target not yet recorded | None | Same domain corpus plus real storage/radio/update evidence |
| Matter export | Future server-role dependency | Controller evidence is not sufficient | Upstream server profile and independent-controller tests |

Read [procurement](../plans/procurement.md) before choosing a coordinator. Host protocol openness, no-cloud operation, firmware licensing and physical compatibility are different fields. A decoder fixture never upgrades a device's hardware status automatically.

Each future ledger entry records case IDs, exact source and firmware cohort, observed result, limitations and reviewer. Passed alarm autonomy and passed Zigbee reports are separate entries. Keep private captures, keys and stable household identifiers outside public Git history.
