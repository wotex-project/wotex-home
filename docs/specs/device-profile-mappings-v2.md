# Portable device mapping profile v2

Version: 0.1.0. Owner: WOH.18, H18-08/H18-T11–H18-T12; semantic ownership WOH.01, protocol mappings WOH.03. Status: accepted successor target; schema/bindings and multi-channel runtime planned.

## Extension result and compatibility

A new model or additional standard sensor channel using an installed supported
binding and semantic contract should be independently authored, imported and
reviewed without editing Home or rebuilding it. Adding a genuinely new protocol,
privileged operation or unsupported semantic contract is a separately reviewed
binding/runtime change. No description language can manufacture a local API for
a cloud-only device. Support means an exact protocol/host/device cohort, not a
vendor logo, number of adapters or a promise that every home device works.

`wotex-home.portable-profile.v1` remains unchanged and limited to its current
LIFX direct-power selection. This document targets a separate
`wotex-home.portable-profile.v2`; no v1 field gains parameters, helper imports,
credentials, new operations or looser validation. Existing profiles, approvals,
receipts and projection identities retain their original format/compiler basis.
Unknown formats and required contracts fail closed, without falling back to v1.

## Capability-first mapping

A physical Thing can expose multiple independently described channels. Display
roles organize the UI; they are not a hard-coded list of every permitted device
model. Host-owned, versioned capability contracts specify operation, exact
value representation, unit/scale, missing/invalid meaning, risk, freshness
ceiling and whole-Thing effect-domain relationships. Profiles reference those
contracts and may narrow their operations/ranges; they cannot redefine them.
The generic admission/projection pipeline must not require a vendor-specific
branch in Authority, Store, rules or Swift for a supported sensor model.

The first semantic expansion is bounded reported observations: temperature,
relative humidity, illuminance, contact state, motion, battery fraction/voltage
and electrical power/energy. Each gets exact conversion/missing/reset vectors
before implementation. A standard readable scalar/Boolean channel can use the
same validation and rendering path regardless of brand. Nonstandard quantities
may be preserved as bounded namespaced metadata for inspection; they cannot
become automation facts or write controls without a supported semantic contract.
Electrical-load control, locks, heaters, alarms and safety maintenance require
their own risk/effect semantics. Calling a device a Switch never assigns it a
safe load class. Unknown optional metadata stays inert; unknown required
capabilities or security requirements reject admission.

The first read-only semantic contracts use these exact normalized values;
concrete namespaced contract IDs/digests are frozen with the executable registry.
Numeric bounds below are representation ceilings, not a sensor's claimed
operating range. Bindings and profile selection must narrow them to the actual
qualified range; risk/freshness and safety-device context remain host-owned.

| Meaning | Value / unit | Initial representation constraint |
| --- | --- | --- |
| Temperature | Signed integer millidegrees Celsius, `mdegC` | At least −273150; at most signed-64 maximum; a reported invalid sentinel is unknown |
| Relative humidity | Integer fraction, `ppm` | 0–1000000; not absolute humidity |
| Illuminance | Nonnegative integer, `mlx` | Millilux; not irradiance or estimated brightness |
| Contact closed | Boolean, `none` | `true` means the enrolled contact reports closed; not a lock/security guarantee |
| Motion detected | Boolean, `none` | Reported detection; not continued room occupancy |
| Battery fraction | Integer fraction, `ppm` | 0–1000000; no implicit voltage-to-fraction curve |
| Battery voltage | Nonnegative integer, `uV` | Microvolts; not inferred charge |
| Active electrical power | Signed integer, `mW` | Sign convention (import/export) is declared by the qualified binding |
| Cumulative electrical energy | Nonnegative integer, `mWh` | Direction/register identity and reset/wrap source epoch are explicit |

All normalized integers fit signed 64-bit representation. Source decimal values
use checked exact decimal/rational conversion, not IEEE float threshold
rounding. A required conversion with unrepresented precision rejects that
sample unless a separately qualified host contract declares its error policy.
Source null, out-of-range and invalid-sentinel values become explicit unknown,
never zero/false. Channels using these values expose read/report only in the
first expansion; their existence does not create an action or writeproperty.

## Closed data and binding registry

The accepted schema shape is one bounded UTF-8 JSON object, with closed fields:
`format`, `id`, `version`, `fingerprint`, `binding`, `channels`, `dependencies`
and `provenance`. `binding` identifies one installed binding contract; each
channel identifies a local channel key, supported semantic-contract reference,
read/event/write operation subset, a binding-specific selector and optional
range narrowing. A selector is not an instance route. Dependency entries pin
exact TD/TM, registry, binding/semantic contract and optional qualified decoder
identities where required. Provenance remains attributed data, not trust.

Initial ceilings are 64 KiB, depth eight, 32 channels, 32 dependencies and 32
firmware fingerprint values. Duplicate keys/channels, nonfinite/unsupported
numbers, unknown fields/operators, unsafe text and overlapping ambiguous
selectors reject before unbounded allocation. Extend custody quotas only with
an explicit measured revision; a bigger profile cannot bypass existing total
byte/object/lease limits. No archive, remote contexts, network fetch, template
interpolation, author-selected module or dynamic dependency resolution exists.

Each installed binding registry entry pins its public producer contract and
implementation cohort, supported selectors, operations and widths, security
requirements, lifecycle, bounds and evidence status. A TD/TM supplies WoT
affordances and Forms through WoTEx; Home supplies the host-owned mapping and
authority review. Discovery/interview captures provide actual instance identity,
endpoints and supported fields. Fingerprints constrain those captures; the
profile cannot author replacement evidence, stable physical identity, routes,
keys, source timestamps or correlation tokens.

First candidates are a standard Zigbee ZCL read/report mapping and a local
MQTT JSON-observation mapping. These are planned Home bindings; neither is
admitted merely because a WoTEx package exists. ZCL selectors name endpoint,
cluster, attribute and supported scalar type within host-checked interview
evidence. MQTT selectors name bounded JSON Pointer fields in the selected
commissioned stream; broker/topic/credential policy stays in private instance
setup. Retained/replayed messages carry their actual provenance and cannot
renew receipt freshness or manufacture an edge. JSON Pointer traversal is
bounded extraction, not JSONPath, regex, an expression or script engine.

The only data transformation primitives are host-specified Boolean/enum tables
and exact checked rational affine conversion of a scalar, with explicit range
and invalid-sentinel rules. Integer overflow, inexact required conversion and
unsupported units reject; no silent threshold rounding. Protocol response
framing, endianness, type decoding and authenticated/correlated delivery belong
to the binding, rather than arbitrary author-authored byte writes. Writes, when
later supported, name a host-defined absolute semantic operation and pass all
normal guards; profiles cannot contain raw packet templates or addresses.

The concrete closed per-binding JSON schema, canonical projection encoding,
TD/TM correspondence, conversion table and independent byte fixtures must be
checked in before a v2 loader or migration. This target deliberately does not
invent an operational registry ID for an unimplemented producer/consumer join.
Binding contract version, artifact digest and qualification identity remain
different values. Discovery, validation, trust approval, selection, qualification
and active use remain separately visible states under the existing lifecycle.

## Executable escape boundary

Use data for supported standard mappings. A proprietary payload outside that
grammar can justify a separately versioned, import-free typed decoder under
WOH.17. It returns bounded values/errors and receives no sockets, keys, bearer,
Store, clock or mutation authority. Home independently checks declared output
types, units, ranges, provenance and exact decoder/profile/runtime evidence.
The current light-power preview world cannot be relabeled a generic sensor
decoder or committed as an observation.

A long-lived adapter needing a native SDK, stream or new protocol cannot be
smuggled into that pure decoder. Its reusable transport belongs in WoTEx;
independently installed components/programs require a separately reviewed
resource/driver contract, OS containment, complete child retirement and
lease/cancellation semantics. There is no downloaded BEAM code, runtime Mix
dependency, evaluated JS/Python/Elixir or untrusted NIF loading in Home.
Refpath's artifact/runtime contracts are candidates for qualified public reuse,
not a required host engine or evidence that Home can execute them today.

## Review, update and qualification

Use WOH.18's immutable raw bytes, independent semantic projection, private
custody, explicit trust/selection, operation receipts, finite retention and
maintenance barriers. Review shows per-channel additions/removals, changed
units/ranges/operations, decoder/binding identity, reported authentication and
affected rules/grants. Approval of a publisher is not approval of every
successor, and installing bytes never selects them automatically.

Expanded declarations cannot silently widen an already distributed grant.
Use the existing explicit grant-and-rotate/re-enrollment mechanism for new
authority; reductions invalidate dependent work. Missing artifacts, changed
firmware/interview basis, new decoder/runtime, revocation and stale source epochs
block affected use without transferring old qualification. Backup retains the
exact closure; restore/host transfer cannot reconstruct it by fetching a
similarly labeled profile. Profile updates fence dependent scheduled and
reported-edge work as well as explicit effects.

## Acceptance corpus

H18-T11: two independent authors add different models/channels using installed
bindings without changes to Home source or binaries. At least one multi-channel
sensor and two protocol paths share capability rendering and fact semantics.
Vectors cover negative/scaled values, enum/sentinel errors, overflow, contact vs
motion, battery voltage vs fraction and reset/wrap of energy counters. Record
which observations are software fixtures and which exact cohorts are physical.

H18-T12: reject unsupported binding/semantic/security requirements, code or
raw-packet fields, ambiguous selectors, excessive depth/channels and stale
captures. Race upgrade/revocation with observations, rules, receipts and handoff;
new channels never widen old grants. Run offline with no Wasm engine or registry,
then restore with a missing dependency and verify dependent work is blocked.
Neither passing import nor decoder output alone establishes device qualification.
