# Universal Light interoperability

Status: target procedure; start with the owned LIFX bulb and an independently qualified second profile.

## Claim

An unchanged semantic consumer can read and set overlapping Light capabilities through different local protocols. The test does not claim equal colour gamut, brightness perception, latency or transport guarantees.

Use the same versioned Thing Model and consumer calls, but separate TD Forms/profile codecs. Start with power and normalized brightness; add colour temperature and tagged colour only where both devices support them. Include a white-only light to prove optional capability handling.

## Checks

- [ ] Consumer logic contains no brand/protocol branch.
- [ ] Target selection comes from enrolled identity and admitted capabilities.
- [ ] Brightness zero and power off stay distinct.
- [ ] Gamut/temperature clipping is disclosed, not silently claimed equal.
- [ ] Unsupported operations fail before network I/O.
- [ ] A command receipt stays separate from reported/observed state.
- [ ] Group execution reports a missing member and partial completion.
- [ ] Delayed or duplicated replies cannot complete the wrong request.
- [ ] A blocked invariant fails identically through native UI, CLI and optional ecosystem export.
- [ ] WAN remains blocked throughout.

Record protocol profiles, TD digests, consumer binary/source, requests/results and the exact equivalence tolerance. Use an independent consumer or peer implementation to avoid a sender and receiver agreeing on the same bug.
