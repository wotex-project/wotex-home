# Hardware qualification ledger

Reviewed: 2026-10-01. The operator reports all needed hardware available. Exact inventory and physical test results have not yet been recorded.

| Target | Possession / identity | Capability evidence | Next gate |
| --- | --- | --- | --- |
| Older EU LIFX bulbs | Owned; one discovered device reports vendor 1, product 22, firmware 1.22 | The selected `en0` WoTEx UDP probe interviewed this identity and separately read power on on 2026-10-01; no writes. Transcript digest `efd15d22b9e3b18d32e2b063cda9e37c3a76a07b804919eb7e71955f6b571e84` commits to the private interview capture | Exact physical cohort review, qualified read/write/readback, crash and WAN-cut |
| Aqara Smoke Detector | Purchased without hub; exact retail/Zigbee fingerprint pending | None recorded here | Manual/label, coordinator, read-only interview and independent alarm/report tests |
| Zigbee coordinator | Available per operator; exact chipset/firmware not yet recorded | Host USB inventory returned no devices on 2026-10-01; no `_zigbee-ncp._tcp` service advertised in an eight-second browse | Documented NCP/USB, firmware custody, exact detector compatibility |
| Hue Bridge/lights | One mDNS advertisement reports Bridge model BSB002 | Read-only discovery on 2026-10-01 advertised HTTPS on 443. The observed certificate has a bridge-ID CN and Philips Hue root-bridge issuer, validity 2017–2038; default system CA verification fails. A separately supplied published Hue root verified the CA chain, validity and bridge-ID CN; the Home reader reached the HTTPS endpoint and received an authentication rejection for a synthetic key. No real application key or resource data was read; this is not physical enrollment | Independently reviewed TLS trust/pin, private application key, exact firmware, local resources/events and offline control |
| Shelly devices | Hardware available per operator; exact models not yet recorded | A six-second local `_shelly._tcp` browse on 2026-09-28 found no advertised service; the read-only Gen2 interview has only scripted-peer evidence | Per-model local path and safety/load policy |
| Mac host | Intended first development host | No installed Home host exists in this record | Background service, IPC, permissions, USB, sleep/recovery |
| Nerves appliance | Hardware available per operator; exact target not yet recorded | None | Same domain corpus plus real storage/radio/update evidence |
| Matter export | Future server-role dependency | Controller evidence is not sufficient | Upstream server profile and independent-controller tests |

Read [procurement](../plans/procurement.md) before choosing a coordinator. Host protocol openness, no-cloud operation, firmware licensing and physical compatibility are different fields. A decoder fixture never upgrades a device's hardware status automatically.

Each future ledger entry records case IDs, exact source and firmware cohort, observed result, limitations and reviewer. Passed alarm autonomy and passed Zigbee reports are separate entries. Keep private captures, keys and stable household identifiers outside public Git history.
