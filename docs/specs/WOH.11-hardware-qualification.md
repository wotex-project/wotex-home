# WOH.11 — Qualification and evidence programme

Version: 0.2.0. Status: accepted target.

## Evidence is multidimensional

**H11-01.** Record implementation coverage, test environment and claim separately. `fixture`, `simulator`, `integration`, `hardware` and `field` identify environments, not a single score that proves every feature. A paired detector can have hardware identity evidence and no alarm-report evidence. Every capability names its own passed, failed, blocked or not-run cases.

A cohort binds hardware SKU/revision, firmware, adapter/profile, native stack, host OS/runtime, network topology and application/model versions. Any changed participant invalidates affected receipts; do not merely regenerate old hashes. Physical tests use explicit operator consent and never run as a default CI step.

## Required test families

**H11-02.** The baseline programme includes decoder/property-based tests; simulated protocol peers; real loopback/native process integration; device-in-loop behavior; WAN/public-DNS cut before boot; AP/device/coordinator restart; storage/power-loss recovery; controller duplication; update/restore; and the universal affordance suite. The negative admission suite must assert zero mutating driver calls, not only a rejected UI status.

**H11-03.** Smoke qualification begins read-only and follows the exact manufacturer's safe testing procedure. Test alarm autonomy with the controller absent, network reporting independently, test-versus-real semantics, stale/clear behavior and coordinator recovery. Do not use smoke generation, covert alarm disablement or automatic firmware downgrade as a lab shortcut. Acoustic exposure and the household's continuing protection are operator safety prerequisites.

**H11-04.** The default stability cohort is seven days of timestamped operation including controlled network/host interruptions. This is an engineering acceptance target, not a battery-life or reliability prediction. Measure report rates, unexpected wakeups, queue drops, reconnects, CPU/memory, disk growth and observed battery changes. A seven-day run cannot substantiate a ten-year battery claim. Longer field measurements remain separate.

## Receipts

**H11-05.** A receipt contains scenario/requirement IDs, exact source/firmware/model identities, command sequence, environment, expected assertions, actual results, artifact digests, exclusions and reviewer. Private raw captures and keys are not committed. Sanitization records its transformation and preserves framing/checksum validity. A changed fixture is a new fixture, not a purported original capture.

Evidence manifests and executable schemas belong in `test/support/` or `priv/` once implemented. Documentation catalogs obligations; production code never loads acceptance policy from Markdown. No public support badge may be generated merely from a populated catalogue.

## Initial acquisition priorities

Use the owned older LIFX bulbs and purchased Aqara detector. Acquire an exact locally controllable Zigbee coordinator only after documented host interface, macOS serial, firmware custody and electrical/RF requirements are checked. Hue/Shelly ownership and exact models remain unconfirmed unless recorded. No Pi purchase is required for the macOS path; no LoRa equipment is required.

## Acceptance

H11-T1: a per-capability report cannot promote an unrun physical claim. H11-T2: cohort drift invalidates the correct cases. H11-T3: all required interruption and prevention cases have explicit receipts. H11-T4: no keys, stable personal identifiers or household observations escape the private evidence boundary. H11-T5: release readiness lists unresolved hardware and standards-certification obligations separately.
