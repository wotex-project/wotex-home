# WOH.11 — Qualification and evidence programme

Version: 0.2.5. Status: accepted target.

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

The first pure `Qualification.Evidence` boundary validates a closed case definition, exact source/profile/firmware/stack/host/topology/application/model cohort, and a sanitized per-case receipt. It provides a keyed HMAC constructor for the source-identity reference; the raw device identifier and key are not fields in the receipt. A supplied 64-character reference still needs trusted provenance outside this pure validator. A passing receipt requires actual matching assertions, a command-sequence reference and an artifact digest. The summary requires the case's exact environment, so a fixture pass cannot fill a hardware case. Firmware or source-identity drift blocks a previously passing receipt, and duplicate or mismatched case and receipt IDs fail closed. It has no private capture store, reviewer authentication, receipt signature, physical test runner or path to the Store's profile-qualification slot; these are still required before device control.

The first [machine-readable LIFX programme](../../priv/qualification/lifx-old-eu-v1.json) fixes eleven H03-T1 through H03-T6 obligations across fixture, integration and hardware environments. `mix compile` followed by `mix run --no-compile bin/report_lifx_qualification.exs COHORT.json RECEIPTS.json` emits a sanitized case/count report for one exact cohort. Empty receipts leave all eleven `not_run`; an environment or cohort mismatch becomes `blocked`. Even if every supplied receipt says passed, the report remains `complete_unverified` with `provenance: unverified`: this syntax checker cannot authenticate the reviewer, capture or device-identity HMAC. It does not qualify the Store profile or replace the wider WOH.11 programme.

An opt-in reviewer attestation wrapper now verifies each closed receipt's Ed25519 signature against a caller-supplied, key-ID-indexed public-key map. The signed bytes are a domain-separated deterministic Erlang term containing the key ID, pinned programme digest and complete sanitized receipt. The three-input report form accepts attestations and a JSON map of URL-safe base64 public keys, labels provenance `signatures_verified_against_supplied_keys`, and still marks even all-passed signed claims as `signed_claims_complete_artifacts_unverified`. It cannot establish public-key trust, inspect private artifacts, verify the source-ID HMAC or authorize physical control. Private signing keys never enter this repository or CLI.

The catalogue is a contract-level summary, not a replacement for per-requirement and per-case evidence. Each implemented case links to its executable test, environment-specific receipt and exact cohort. The release manifest lists blocked, failed and not-run cases alongside passed cases; fixture evidence cannot promote a hardware, field or certification claim.

## Initial acquisition priorities

Use the available older LIFX bulbs, Aqara detector and coordinator. Record the coordinator's exact host interface, macOS serial identity, firmware custody and electrical/RF requirements before qualification. The operator reports all hardware needed for the build available; exact Hue, Shelly and Nerves models remain unconfirmed until locally recorded. No extra Pi or LoRa purchase is required for the macOS path.

## Acceptance

H11-T1: a per-capability report cannot promote an unrun physical claim. H11-T2: cohort drift invalidates the correct cases. H11-T3: all required interruption and prevention cases have explicit receipts. H11-T4: no keys, stable personal identifiers or household observations escape the private evidence boundary. H11-T5: release readiness lists unresolved hardware and standards-certification obligations separately.
