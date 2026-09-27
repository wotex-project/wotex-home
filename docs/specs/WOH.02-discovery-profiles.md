# WOH.02 — Discovery, enrollment and profile admission

Version: 0.2.8. Status: accepted target.

## Discovery is not trust

**H02-01.** A local introduction becomes a bounded candidate observation, not a Thing with command authority. Native discovery, configured addresses and imported captures all pass the same evidence boundary. The record includes interface, source endpoint, receive epoch/time, raw-data reference, claimed identifiers and trust class. Duplicates and conflicting identifiers are visible; labels and RSSI cannot settle an identity conflict.

Discovery runs on selected interfaces for a finite window. mDNS/UDP are normally link-local; routed discovery requires explicit configuration and admission. No Internet discovery endpoint is required. A discovered URL is checked against network policy before fetching it, including after re-resolution and redirects.

The first pure LIFX discovery window emits one tagged GetService packet for an explicit interface and finite receive epoch. It accepts only matching unicast StateService responses during the window, coalesces repeats from one endpoint and retains distinct endpoints that claim the same target so collision review can reject ambiguous enrollment. It produces bounded untrusted candidates with no route or control permission. Socket ownership, actual interface selection and physical response evidence are still separate work.

## Enrollment

**H02-02.** Explicit operator selection binds the candidate to a stable pseudonymous Thing ID, exact profile revision and credential reference. Physical-button, QR/install-code, bridge enrollment and legacy trust-on-first-use are different enrollment methods. TOFU is labelled weaker, not advertised as authenticated device attestation.

The first executable review screen binds a selected candidate, linked read-only interview, unique exact profile hint, proposed Thing declaration and explicit enrollment method. It rejects conflicting stable-ID claims, ambiguous candidate/profile selection, mismatched profile/qualification references and accidental reuse of the device's raw stable ID as the Home Thing ID. Its result remains `pending_authenticated_commit`: the operator ID is attribution data until the authority authenticates the selection, and no credential, route or command permission is created by review alone.

The Store now accepts that review through an authenticated `enroll:review` principal and re-runs its bounded structural checks before one transaction inserts the Thing and a durable stable-ID binding. The credential's principal ID must equal the selected operator ID. The binding records the reviewed candidate, method, qualification reference, profile and identity digest; unique stable ID and review reference prevent a second Thing from inheriting them, including after revocation or restart. Legacy in-process `enroll_thing` remains a trusted bootstrap/fixture primitive and does not create this reviewed binding. A reviewed binding documents an operator's identity selection, not device attestation, executable profile qualification, a route, a target grant or permission to send.

The reviewed identity digest now has a versioned input domain and binds reported transport, manufacturer, model and firmware as well as stable ID and selected profile. A changed firmware inside one profile's allowed set changes the digest and must not silently inherit a prior qualification. Earlier development bindings using the first digest formula remain unqualified until a fresh authenticated re-review.

Schema version 7 now marks earlier bindings as digest version 1 and preserves their original review as a legacy history row. A fresh authenticated re-review by the bound operator appends a version 2 row with reported manufacturer/model/firmware, updates the active binding and retains earlier review references as tombstones. It requires the exact current Thing declaration, stable ID, profile, qualification reference and enrollment method. The transaction clears current reports and pending source-epoch grants, rejects held requests and invalidates unsent execution work; handed-off work becomes unknown. Each Thing is limited to 32 retained reviews. Re-review records a new identity decision, not cryptographic device attestation or control qualification.

The first LIFX-specific interview path now fills this read-only record from correlated vendor/product and host-firmware replies. Its exact protocol identifiers are evidence strings; a product-capability registry and a physical cohort review are still needed before a packaged profile is selected.

The registry interpreter can resolve a pinned vendor/product/firmware tuple to declared manufacturer features. It cannot convert a discovery claim or product name into enrollment: the exact device cohort, packaged registry artifact, profile revision and operator review remain separate gates.

For the first LIFX direct-power profile, a pure mapping assessment re-runs the enrollment review, requires a LIFX serial-shaped stable ID and exact numeric vendor/product/firmware lookup, and binds the single ordinary Boolean power declaration, registry bytes and runtime modules into a digest. It returns `pending_physical_qualification` with `profile_mapping_only` scope. An arbitrary registry object can be structurally assessed for fixtures; installed admission must use the pinned packaged artifact and independent exact-cohort hardware evidence. This assessment does not grant a route or command authority.

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
