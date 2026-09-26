# Aqara Smoke Detector direct-Zigbee lab

## Goal

Pair the purchased detector directly to an operator-controlled coordinator and expose an evidence-backed SmokeDetector Thing without an Aqara hub/cloud.

## Before pairing

- [ ] photograph/record exact retail model/SKU/regulatory label;
- [ ] record coordinator model/chipset/hardware revision;
- [ ] pin coordinator firmware/digest;
- [ ] create private device alias.

## Pair/interview

- [ ] open a bounded permit-join window;
- [ ] initiate pairing using the procedure appropriate to the exact device;
- [ ] capture manufacturer/model identifier;
- [ ] capture endpoints/clusters and versions;
- [ ] record IEEE address privately;
- [ ] select a profile only after fingerprint evidence.

## Safety/semantic evidence

- [ ] prove detector's own local alarm remains independent;
- [ ] observe qualified smoke/self-test state safely according to manufacturer procedure;
- [ ] observe clear/recovery if protocol exposes it;
- [ ] battery/voltage evidence if exposed;
- [ ] sleepy periods do not become false offline;
- [ ] coordinator restart recovers network;
- [ ] Home restart preserves identity;
- [ ] WAN absent throughout required path;
- [ ] silence/manual alarm remain disabled until separately qualified.

## Soak

Run a long-duration reporting/battery observation before claiming that our reporting configuration preserves the intended low-power profile.
