# LIFX old EU bulb lab

## Goal

Prove a currently owned older LIFX bulb can become a Home Light without Internet or LIFX cloud.

## Sequence

- [ ] record exact product/firmware from protocol evidence;
- [ ] block WAN;
- [ ] discover using UDP broadcast compatibility path;
- [ ] query product/version/firmware;
- [ ] materialise only supported Light capabilities;
- [ ] read power/state;
- [ ] write power;
- [ ] set brightness;
- [ ] set colour/temperature only if supported;
- [ ] transition with finite duration;
- [ ] re-query and establish observed state;
- [ ] power-cycle bulb and preserve logical Thing identity;
- [ ] restart Home and rediscover;
- [ ] record packet/evidence digests and limits.

mDNS is optional and cannot be the only discovery path for the old-bulb qualification.

The development Mac has a bounded read-only probe: `mix run bin/lifx_read_lab.exs en0` (replace `en0` with the selected active Wi-Fi interface). It derives the interface's IPv4 prefix, sends one directed-broadcast `GetService`, and interviews at most eight discovered candidates with `GetVersion` and `GetHostFirmware`. It prints only reported identity and candidate references; it does not enroll, write, or qualify a profile. Exit code 3 means no candidates. This probe uses a temporary lab UDP socket and is not the pinned WoTEx transport or the Home command path.

On 2026-09-27, the selected `en0` interface was `192.168.86.149/24`; this probe found zero LIFX candidates during its two-second window. This is a reachability observation, not evidence that the owned bulb is absent, unsupported or defective. Repeat after confirming its power and Wi-Fi attachment, then record exact identity and WAN-cut evidence before marking any case passed.
