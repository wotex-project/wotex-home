# Offline boot and recovery acceptance

Status: target procedure. This is a network-isolation test, not proof of cybersecurity.

Preinstall reviewed application, model, tokenizer, Maude executable/model closure, schemas and profiles. Record their digests. Block WAN and public DNS before boot. Keep local routing and documented local name resolution available; preserve realistic device DHCP behavior.

| Case | Expected result | Evidence |
| --- | --- | --- |
| Cold host start | Useful local control without cloud login or artifact download | startup log and bounded egress capture |
| LIFX discovery/control | Older bulb works through local broadcast/unicast | exact firmware and wire exchange |
| Aqara report | Local coordinator receives a qualified report | interview/profile/report identity |
| Hue/Shelly, when qualified | Local credentials and local status/control only | per-profile exchange |
| UI closed | Registered background controller continues | process identity and rule result |
| Inference stopped | Typed controls and admitted automation remain usable | same input/output assertions |
| Verifier stopped | New proof-required draft stays inactive; valid admitted rules continue | active digest and zero candidate driver calls |
| Host restart | Durable receipts restored; uncertain effects not replayed blindly | outbox/receipt trace |
| AP reboot/address change | Qualified identity recovered, not duplicated | discovery/reconciliation trace |
| Coordinator unplugged | Explicit degraded state; no auto network reset | driver lifecycle and network identity |
| Clock wrong after boot | Unsafe schedules delayed with reason, manual local control available | clock-confidence and deadline trace |
| WAN restored | No retroactive vendor enrollment or telemetry upload | egress capture |

macOS sleep/logout is a separate availability test. A sleeping host cannot be credited with processing radio events. Record this limitation rather than passing it because the detector's own siren still works.
