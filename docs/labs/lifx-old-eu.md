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
