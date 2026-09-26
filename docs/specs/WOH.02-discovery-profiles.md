# WOH.02 — Discovery, enrollment and profile admission

Version: 0.2.0. Status: accepted target.

## Discovery is not trust

**H02-01.** A local introduction becomes a bounded candidate observation, not a Thing with command authority. Native discovery, configured addresses and imported captures all pass the same evidence boundary. The record includes interface, source endpoint, receive epoch/time, raw-data reference, claimed identifiers and trust class. Duplicates and conflicting identifiers are visible; labels and RSSI cannot settle an identity conflict.

Discovery runs on selected interfaces for a finite window. mDNS/UDP are normally link-local; routed discovery requires explicit configuration and admission. No Internet discovery endpoint is required. A discovered URL is checked against network policy before fetching it, including after re-resolution and redirects.

## Enrollment

**H02-02.** Explicit operator selection binds the candidate to a stable pseudonymous Thing ID, exact profile revision and credential reference. Physical-button, QR/install-code, bridge enrollment and legacy trust-on-first-use are different enrollment methods. TOFU is labelled weaker, not advertised as authenticated device attestation.

Device interview records protocol manufacturer/model IDs, endpoints/components, cluster/service capabilities and firmware where exposed. Unsupported identity or capability remains unresolved. Active probes are bounded and read-only unless a separate maintenance operation authorizes a change.

**H02-03.** The purchased Aqara detector is not assigned a regional SKU from a similar product photograph. Record the retail/regulatory label and the actual Zigbee fingerprint. A third-party supported model is a test hypothesis. Its claimed fields are not copied into a TD before reports or explicitly qualified reads establish them.

## Profiles

A profile has an immutable identifier/version, matching predicates, decoder/encoder identity, required native/backend features, security class, health/reporting policy, capability mapping and qualification references. Ambiguous highest-ranked matches block automatic admission. A firmware change invalidates affected mappings until reviewed. Runtime profile updates do not reinterpret historical observations in place.

**H02-04.** Approved profiles are packaged code/data, not arbitrary downloadable scripts. A future external plugin mechanism must define signing, permissions, process isolation and rollback separately. Unknown manufacturer attributes remain bounded opaque evidence, not guessed measurements. A generic protocol package is not a vendor profile catalogue.

## Replacement and churn

**H02-05.** IP addresses, Zigbee short addresses and BLE private addresses are routing metadata. A changed address may update a route under the existing identity evidence. A replacement physical device requires explicit enrollment and policy review; reusing a friendly name does not transfer permissions or past measurements. One device seen by several gateways has one identity with distinct observation paths, not several silently merged owners.

Removal revokes relevant credentials/routes, suspends dependent automations and retains a tombstone for replay protection. Factory reset and coordinator replacement are recovery procedures, never automatic responses to a timeout.

## Acceptance

H02-T1: unknown, ambiguous and spoofed discovery yield no physical action. H02-T2: address churn preserves only a legitimately enrolled identity. H02-T3: swapped devices with the same label cannot inherit authority. H02-T4: firmware/profile changes require explicit requalification. H02-T5: malformed interviews and hostile URLs fail under byte/time limits. H02-T6: offline local enrollment is tested separately from ongoing offline control.
