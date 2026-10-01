# WOH.01 — Home Things, capabilities and units

Version: 0.2.3. Status: accepted target.

## Semantic boundary

**H01-01.** W3C WoT TD/TM values remain authoritative for affordance structure. Home provides a small versioned semantic vocabulary, not a second TD parser or a universal building ontology. External SAREF/Brick/Haystack annotations may be preserved as metadata; no remote ontology resolution is required to switch a lamp. Matter Device Types are export projections, not the internal domain model.

Each capability identifies its source profile and evidence, operations, value schema, units, access/risk class, observation method, freshness policy and rounding/error bounds. An absent capability is not a zero, false or failed device. Manufacturer extensions are retained under explicit namespaced metadata and are not silently promoted to generic semantics.

At the Home API boundary, Thing IDs, capability keys and profile/evidence references are bounded opaque strings, never runtime-created atoms. This first semantic subset uses exact integer units: fraction parts per million for brightness and saturation, millidegrees for hue, Kelvin for colour temperature and milliseconds for transitions. A profile may expose fewer operations than its role permits. Unknown fields fail admission, except bounded explicitly namespaced extension metadata, which carries no operation authority.

## Reference roles

| Role | Baseline | Optional, only when qualified |
| --- | --- | --- |
| Light | power | brightness, colour, colour temperature, transition, identify |
| Switch/Plug | power | active power, voltage, current, cumulative energy, overload state |
| MotionSensor | detected motion | illuminance, battery, test state |
| OccupancyEstimate | estimated occupancy with provenance | confidence and expiry; never equivalent to physical motion |
| SmokeDetector | reported smoke state | battery, optical density, fault, test status; maintenance actions are separate |
| EnvironmentalSensor | named quantity and unit | calibrated uncertainty, additional channels |
| Gateway/Bridge | connection and identity metadata | child inventory and network diagnostics |

A PIR observation does not prove room occupancy. A bridge's availability does not prove that every child is reachable. Device battery percentage and battery voltage are distinct quantities; do not derive one without a qualified curve.

## Lighting

**H01-02.** `brightness` is a dimensionless fraction in [0,1], independent from power. A zero level does not imply that the device is electrically off. Colour is a tagged value with an explicit colour space: a qualified profile may offer HSV (hue in degrees, saturation in [0,1]) or CIE xy plus a separate brightness. Colour temperature is in Kelvin, with a profile-specific range. Conversion, gamut clipping and quantization are explicit adapter operations with test vectors. Never promise perceptually identical colour from two different lamps.

`setState` carries an absolute desired state and optional transition duration in milliseconds. It is offered only when a profile can define coherent semantics; separate physical writes remain a non-atomic plan with per-step outcomes. A transition acknowledgement is not completion evidence. Polling-derived changes are not mislabeled as native device events.

## Groups and scenes

**H01-03.** Room membership, groups, scenes and Home modes are composition records, not inferred physical identities. A scene binds exact members and capability/profile revisions. Execution returns each member's outcome and reports partial completion. Group membership edits require revalidation of permissions, load risks and admission evidence. An aggregate 'all off' requires sufficient fresh evidence from every required member; one unknown member prevents that claim.

The first executable scene data subset allows one ordinary-risk absolute effect per whole-Thing domain and binds each member to its declared profile and expected resource revision. It produces no command authority. A per-member report distinguishes `reported_match`, protocol acceptance, unknown, failure, rejection and not-started; only all members marked `reported_match` yield `all_reported_match`, which is still a report-level claim rather than proof of physical output. Group membership changes, per-member durable receipts and real scene dispatch remain separate work.

Vendor-native scenes/groups are optional optimized projections after equivalence is tested. They do not bypass per-member Home policy. There is no blanket rollback of a partially executed scene.

## State and provenance

**H01-04.** State separates requested, admitted, protocol-reported and observed values, plus quality, trust, timestamps and freshness. Home 'observed' means qualified evidence received, not an independent measurement of the physical effect. Health separates connection, freshness, battery, device fault and host uncertainty rather than collapsing them into one green indicator.

Schema 15 additionally records a Store-owned receipt epoch and elapsed monotonic time without changing the adapter's original source/receipt metadata. The authenticated `home-reported-facts-v1` projection checks the exact current declaration, read capability and original journal identity, then uses only that Store clock for receipt freshness. Missing, untimed, old-Store-boot, future, expired, unknown-quality and synthetic-lab reports remain `unknown`. An exact duplicate cannot renew freshness. This is freshness of accepted receipt, not proof of source age, device authentication or physical cause; source correlation and profile qualification remain separate. Its `reported_fact_preview_only` scope is not current invariant admission or dispatch authority.

Use explicit units: temperature degC or K with conversion recorded; power W; energy Wh; time milliseconds/UTC where defined. Decimal/rational or bounded integer representations are preferred for policy thresholds. Counter wrap/reset is a source-epoch event, not negative energy usage. Unknown/nonfinite values never become zero.

## Acceptance

H01-T1: equivalent Light operations through two protocols need no vendor branch above the profile boundary. H01-T2: unit and colour conversion vectors include limits, clipping and white-only devices. H01-T3: missing scene members produce partial/unknown results. H01-T4: battery voltage, percentage and missing data remain distinct. H01-T5: extensions survive TD admission without gaining unsupported executable capabilities.
