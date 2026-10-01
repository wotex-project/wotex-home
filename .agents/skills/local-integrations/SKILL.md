---
name: local-integrations
description: Implement or review local device discovery, protocol reads, writes, enrollment, profile mappings, or transport authentication. Applies when device identity, observations, packet correlation, or physical qualification can change; excludes native presentation-only work.
---

# Local integrations

Input: the selected protocol/device cohort, requested read or effect, existing
profile and transport behavior. Output: a bounded adapter/profile change,
independent protocol checks and an accurate statement of supported and
unqualified physical behavior.

## Establish the supported cohort

Read the relevant protocol section of the
[local integration contract](../../../docs/specs/WOH.03-local-integrations.md).
For enrollment or capability changes, read the applicable
[discovery/profile contract](../../../docs/specs/WOH.02-discovery-profiles.md).
Use primary vendor/protocol documentation for wire behavior; bind support to
the actual model, firmware, protocol revision and declared capabilities.

Trace the existing path through the protocol namespace, its authority use case
and observation/profile mapping. Reusable packet/interaction behavior belongs
to the pinned protocol dependency; household semantics and profile authority
belong to Home. Read dependency provenance when changing those ownership or
version assumptions rather than editing cached dependency files.

## Preserve transport and report meaning

Inspect selected-interface/local-address checks, endpoint identity, bounded
frames and deadlines, sequence correlation and resource/declaration bindings.
Do not extend an observation's freshness by replaying it or copying adapter
timestamps into the Store's own receipt clock. Keep unknown, stale, reported
and unauthenticated values distinct.

For credentialed HTTPS, inspect the actual peer verification and credential
custody path. Preserve the reviewed certificate policy before sending a key;
check wrong peer, expiry, response bounds and redirect/downgrade behavior with
a controlled peer. A synthetic invalid key can test rejection but cannot
establish commissioning or successful device access.

For writes, inspect the durable handoff boundary and independent readback.
Protocol acknowledgement cannot settle a physical observation. Transport loss,
worker death and mismatching readback retain their typed uncertain or
contradicted outcomes rather than causing a blind resend.

## Validate the mechanism and qualification separately

Use the affected existing suites under `test/wotex_home/`: LIFX packet,
session, scripted-peer and power-execution tests; Hue V2/read-path tests; or
Shelly RPC/interview/read-path tests. Add independent malformed-frame,
identity/correlation and timeout cases when the change affects those behaviors.
Use a real local socket/TLS peer when the mechanism depends on it.

Physical support claims require the relevant
[hardware qualification contract](../../../docs/specs/WOH.11-hardware-qualification.md)
and existing procedure in `docs/labs/`. Record only actually observed cohort
results through the project's authorized evidence path. Synthetic signed
fixtures, read-only discovery and successful authentication do not qualify
physical writes, WAN-free operation or detector alarm independence.
