# Hardware qualification ledger

Reviewed: 2026-09-26. No physical tests were performed as part of the specification revision.

| Target | Possession / identity | Capability evidence | Next gate |
| --- | --- | --- | --- |
| Older EU LIFX bulbs | Owned; exact product/firmware pending | None recorded here | Local discovery/version/state/control and WAN-cut |
| Aqara Smoke Detector | Purchased without hub; exact retail/Zigbee fingerprint pending | None recorded here | Manual/label, coordinator, read-only interview and independent alarm/report tests |
| Zigbee coordinator | Not yet selected/purchased in this record | None | Documented NCP/USB, firmware custody, exact detector compatibility |
| Hue Bridge/lights | Candidate; ownership/model not confirmed | None | Exact bridge/local API and offline enrollment/control |
| Shelly devices | Motion 2 appeared in earlier bench inventory; plug/smoke SKUs unconfirmed | No new hardware evidence | Per-model local path and safety/load policy |
| Mac host | Intended first development host | No installed Home host exists in this record | Background service, IPC, permissions, USB, sleep/recovery |
| Nerves appliance | Future selected target | None | Same domain corpus plus real storage/radio/update evidence |
| Matter export | Future server-role dependency | Controller evidence is not sufficient | Upstream server profile and independent-controller tests |

Read [procurement](../plans/procurement.md) before choosing a coordinator. Host protocol openness, no-cloud operation, firmware licensing and physical compatibility are different fields. A decoder fixture never upgrades a device's hardware status automatically.

Each future ledger entry records case IDs, exact source and firmware cohort, observed result, limitations and reviewer. Passed alarm autonomy and passed Zigbee reports are separate entries. Keep private captures, keys and stable household identifiers outside public Git history.
