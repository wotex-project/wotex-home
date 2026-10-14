# Inert external read-target recovery domains

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.15 H15-05/06, WOH.18 H18-T8/T11/T12, controller-transfer-v1.
Implementation: inert v3 derivation, historical decoding and quarantine
correspondence implemented. Evidence: [executed software/archive cases](../provenance/external-recovery-domains-2026-10.md).

## Result and ownership

A retired schema 34/35 source containing external EnvironmentalSensor Things
can derive a complete bounded inert domain inventory and compare it with its
encrypted staged quarantine. Every external target stays in that inventory,
including revoked targets. External metadata cannot authorize destination
acceptance: its transport/counter basis remains unknown. Read-only capability
does not prove that a device has no authenticated transport, radio state or
other controller. No credentials, owner processes, source leases or freshness
are restored from these records.

[Controller transfer](controller-transfer-v1.md) owns retirement, encrypted
archive correspondence, live isolation review and acceptance. Its existing
v1/v2 domain encodings and complete LIFX isolation rules remain unchanged.
[Targets](external-target-selections-v1.md) and
[observations](external-observations-v1.md) own retained private source bindings,
selection/report originals and sequence cursors. RecoverySnapshot's normalized
commitment includes these actual tables and their exact rows, independently of
the producer or source owner. The inventory summarizes an already validated
Registry Thing; it never reconstructs WPF semantics or accepts a caller's
capability proposal.

## Closed encoding and bounds

Use domain v3 only when at least one retained Thing has external read
capabilities. With only legacy Things continue emitting the exact v2 bytes.
V3 is compact canonical JSON in the same four-slot envelope:

```
["wotex-home.controller-domains.v3", logical_snapshot_digest,
 seven_source_counts, sorted_records]
```

The seven counts keep their v2 order and meaning: principal rows, active
principals, qualified profile heads, legacy current observations, target grants,
source grants, override leases. External report rows are immutable snapshot
history; they are bound by the full logical digest, not mislabeled as legacy
observations or added to these counts. Bounds remain 64 total records, 32 legacy
identity rows per Thing, 2048 total legacy selections, 131072 per source count
and 4194304 UTF-8 bytes. Excess refuses invalid_transfer_domains as a whole,
without truncation. Decode/re-encode must match exact bytes.

A generic record uses exactly these ten slots:

```
[target_id, "active"|"revoked", "external:" + artifact_hex64,
 resource_revision, declaration_digest, external_capabilities,
 null, [], [], ["unknown"]]
```

Target is a Home ID of 1..128 bytes. Resource revision is nonnegative signed-64.
Declaration digest is SHA-256 of the retained complete Thing document, lower
hex64. Capabilities contain 1..32 entries, sorted uniquely by binary capability
key. Each entry is exactly `["external_read", capability_key, declaration_hex64]`;
the hash is the exact retained ReadCapability declaration SHA. Unknown/extra
slots, duplicate keys, malformed hashes, mixed legacy/external capability entries,
legacy bindings/histories or a resolved transport basis refuse. Opaque units,
C02 definitions and arbitrary channel names are not coerced into the legacy
capability vocabulary. Full declarations and external history stay bound by the
complete snapshot. Legacy records in a mixed v3 inventory keep their exact v2
record encoding. V1/v2 decoding never accepts an external record.

## Requirements and failure behavior

**ER-01 — Preserve complete scope.** RecoveryDomains derives external summaries
from the validated Registry ReadCapability records, not current live producer
calls. Current and revoked targets, all external source/target/report originals
and sequence cursors remain in the logical and normalized commitments. Source
and quarantine inventories must match exactly; changing or deleting any retained
row must change the commitment or fail integrity. Missing private profile bytes
does not erase these metadata records. No persistent schema change is allocated.

**ER-02 — Keep unknown isolation closed.** Any generic record makes the inventory
counter_state unknown with null counter digest. DomainCodec.acceptance_basis
returns transfer_domain_isolation_unavailable for that inventory for every
method, even if a caller claims physical disconnection. It cannot be signed as
an accepted no_radio_state scope or commit destination acceptance. Native review
and transfer APIs retain their existing unknown-state refusal. A future generic
isolation successor must define actual transport/source custody and historical
coverage before allowing a resolved basis; declaration/read capability alone is
insufficient. No mutation, grant or restored freshness occurs on refusal.

## Acceptance

| Case | Requirement | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| ER-T1 | 01/02 | Independent temperature, unfamiliar quantity and multi-channel v3 bytes decode identically. Mixed v3 legacy/external set stays unknown; unchanged legacy v2 remains complete. Reordered/duplicate/33-channel, mixed capability, hash, extra-slot or resolved external basis accepted fails. | Pure/software |
| ER-T2 | 01 | Actual schema 35 Store selects, admits a report, retires and exports. Retired basis and inclusive staged quarantine derive the exact same v3 inventory and normalized commitment with producer/source absent. Missing target, changed original/cursor or resurrected live guard fails. | Software/archive |
| ER-T3 | 02 | Actual generic inventory refuses every acceptance method; valid legacy v2 acceptance cases remain green. Any accepted generic scope, destination epoch advance or authority grant fails. | Software |
| ER-T4 | 01 | Actual revoked generic Thing remains in source/quarantine inventory; missing private bytes retain metadata while changed snapshot hashes or damaged rows refuse. Truncated scope or producer-required decoding fails. | Software/archive |

This successor provides inert recovery correspondence. Completed generic
controller acceptance and physical source isolation remain explicit later work.
