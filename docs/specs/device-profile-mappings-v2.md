# Portable device mapping profile v2

Version: 0.3.1. Updated: 2026-10-14. Owner: WOH.18, H18-08/H18-T11–H18-T12.
Semantic ownership: WOH.01; protocol consumption: WOH.03.
Status: accepted successor target. Implementation: pure envelope/projection boundary
implemented; durable admission/protocol/runtime adoption planned. Evidence: bounded
decoder/v1 regression tests and an exact seven-case archive consumer.

## Result and producer/consumer ownership

A new supported model or readable quantity can be independently described,
imported and reviewed without adding its model/sensor name to Home or WoTEx code.
WoTEx's implemented WPF.01–02 own the generic external-profile reading protocol;
Home owns its device/semantic definitions and source notices. Public templates
ship in Home's release; generated/installation drafts stay in private custody.
Optional reusable exports are explicitly imported, with no shared repo required.
Home owns which definitions it accepts, identity/enrollment, risk, freshness,
grants, current state and authority. No worldwide catalogue belongs in WoTEx.

The [authoring successor](profile-authoring-v1.md) consumes WPF.03's exact
installed-contract export/finalizer/diagnostics before this envelope's local
review/admission. Derived canonical profile/definition bytes are retained as
new artifacts with their own raw identities, not claimed original substrings
of a draft bundle. Importing a valid bundle transfers no approval.

This target consumes WPF rather than reimplementing its parser/compiler/unit
algebra in Home. The installed producer's grammar/operator/selector support
remains finite. New protocol, SDK, privileged behavior, unsupported schema/math
or routine representation requires an owning reviewed code contract. Data cannot
create a cloud-only device's absent local API or physical support.

The implemented `wotex-home.portable-profile.v1` and its LIFX direct-power
approvals/receipts remain unchanged. V2 is a separate consumer envelope around
external definitions; no v1 field gains new parameters, code, scope or validation.
V2 has no deployed compatibility cohort. Unknown formats refuse,
with no fallback or migration inferred from a label.

## Exact v2 input and closure

The envelope contains exactly format, id, version, profile, definitions,
home_contracts and provenance. Format is `wotex-home.portable-profile.v2`.
ID uses Home's current bounded opaque ID syntax; version is ASCII x.y.z.
Profile is one exact WPF.01 Reference to separately retained `wotex.profile@1`
bytes by semantic identity. Custody maps each reference to one explicitly
approved raw-byte digest; ambiguous byte variants refuse selection. Definitions
is a sorted unique array of exact WPF References forming its
selected semantic closure. Each Reference contains id (absolute URI ≤256 bytes),
version and sha256 (lower hex64); no URL is fetched.

Home_contracts is a sorted array of exactly channel_id and contract_ref entries.
Channel_id matches one selected external profile channel. Contract_ref names an
exact independently installed Home consumption contract; it does not author risk,
permission, source truth, a process or a module. There must be one match per
required channel; unsupported optional channels are listed as exclusions.
Duplicate/conflicting references or ambiguous channels reject.

Provenance is exactly publisher, source, license: nonempty inert text ≤256 UTF-8
bytes each, no control characters. It is attributed information, not a signature,
permission or executable fetch instruction.

| Resource | Initial Home ceiling |
| --- | --- |
| Envelope/profile/individual definition | 64 KiB each, depth eight, 4096 JSON nodes |
| Selected channels/definitions/dependencies | 32 / 32 / 32 |
| Complete selected raw closure | 256 KiB before copies; existing custody object/byte quotas still apply |
| Fingerprint clauses/values | WPF grammar narrowed to 32 each; actual host capture only |
| Interpreted report | WRT.06 C02 ≤64 KiB, depth eight, 1024 typed nodes and collection 256; no bulk waveform/media |
| Supported first operation set | Property readproperty/observeproperty and Event subscribeevent only; no inferred writes/actions |

These are first Home host limits, not a limit on sensor types in the world.
Enforce bounds before construction/expansion. Reject unknown/duplicate fields,
invalid strings, nonfinite/cyclic input, unsafe references, unsupported required
operators and unrepresented values. No archive, remote context, dependency
solver, author module, script or raw packet template is admitted.

The consumer adapter explicitly translates this envelope's profile/definition
closure into public WPF constructors/Compiler inputs and retains the producer's
projection identity. It adds Home consumption/qualification identity separately;
it cannot label Home envelope bytes as a WPF profile or rewrite their digest.
Freeze independent envelope-to-producer vectors and executable schemas before
a loader/migration; do not invent a currently installed registry ID.

## External meanings and first normalized Home values

### Pure envelope and projection boundary

`WotexHome.Profiles.ExternalEnvelope.compile/5` takes original envelope bytes,
documents, installed basis, capture and explicit reader limits. It returns an
inert native ExternalEnvelope, before custody import/selection and canonical
observation admission. This stage cannot call Authority, Store or a transport.
No installed consumer contract ID or device qualification is inferred.

Documents is a closed string-keyed map with profile and definitions. Profile
is one closed record {reference, raw_sha256, bytes}; definitions is a sorted
array of the same records, exactly matching the envelope's definition references.
bytes are original UTF-8 WPF bytes, each at most 64 KiB; their complete selected
total is at most 256 KiB before parsing/copying. raw_sha256 is verified against
those bytes; public WPF parse/reference functions verify semantic identity.
References are sorted by ID/version, unique by ID, and exact across all joins.
No alternative raw variant is searched or selected. Missing required references
refuse through the public compiler. Home compares its selected definition set
with public Compiler.references/3 and refuses any unreachable definition, without
copying the producer's closure walker. Missing that additive API is unavailable.

Installed basis contains exactly bindings, contracts, home_contracts and
producer. Bindings and contracts are the selected public WPF registrations and
references, at most 32 each. home_contracts is at most 32 sorted unique exact
WPF-shaped references to consumer-installed consumption contracts; it is an
explicit trusted host assertion, not data authored by the envelope. producer
contains exactly core_archive_sha256, runtime_archive_sha256 and
profiles_archive_sha256, each lower hex64, identifying the caller-selected
artifact cohort. The pure constructor binds this assertion without proving
artifact custody; the archive lane independently selects and verifies bytes.
Capture is the complete public WPF capture, never inferred from model data.

Reader limits has all eight WPF fields. Positive ceilings are max_bytes 262144,
max_depth 8, max_nodes 4096, max_channels/max_definitions/max_bindings/
max_dependencies 32, and max_numeric_digits 64. This bounds aggregate compiler
inputs separately from the 64-KiB individual document/envelope limit. Smaller
selections are allowed and retained; no ambient configuration is consulted.
The envelope decoder enforces depth eight, 4096 nodes (including keys), 32
members/items per container, strings ≤256 bytes, duplicate-key refusal and no
JSON numbers before materializing a profile. Unknown fields and numeric values
are invalid because this envelope has only references and attribution text.

The envelope's required channel must have one exact installed home_contract
entry and only readproperty/observeproperty (Property) or subscribeevent (Event)
operations. Actions, writes, unknown consumption contracts or unsupported
required compiler plans refuse. Optional unsupported or unmapped channels return
sorted exclusions with channel_id and fixed reason producer_unsupported,
operation_unsupported or consumption_unavailable. A supplied unknown channel
or uninstalled contract reference refuses, including optional entries. At least
one channel must remain included. Definition semantics remain externally named;
this inspection boundary neither normalizes a Home quantity nor qualifies it.

The native value retains exactly bytes, data, raw_sha256, projection,
projection_sha256, consumption_sha256, documents and inputs. inputs contains
exactly installed, capture and reader_limits. documents retains the exact raw
records; projection is the public native WPF Projection. Projection identity is
SHA-256 of UTF-8 wotex-home.external-projection@1, newline and core deterministic
JSON of the complete public projection map. Consumption identity hashes the same
encoding with prefix wotex-home.external-consumption@1 and a closed map containing
envelope_sha256, document_identities, projection_sha256, producer, home_contracts
and exclusions. Document identities contain reference/raw_sha256, profile first
and definitions in reference order. home_contracts is the included envelope
channel/contract list, sorted by channel_id. Exclusion ordering is channel_id.

`ExternalEnvelope.to_map/2` accepts only the exact native shape and identical
reader-limit selection, regenerates from retained original bytes/documents and
inputs, and compares every claimed digest/data/projection. It returns exactly
format (wotex-home.external-profile-inspection@1), envelope_sha256,
document_identities, projection_sha256, consumption_sha256, home_contracts,
exclusions and producer. No source bytes, capture values, credentials or native
projection internals enter that inspection summary. Changed retained data or
limits refuses stale_external_basis; construction alone never proves that the
retained installation/capture is still current.

Public failures are payload-free {:error, code}: invalid_external_envelope,
invalid_external_closure, external_profile_limit, unsupported_external_profile,
stale_external_basis or profiles_producer_unavailable. Missing public producer
APIs return unavailable; no substitute reader runs. Unknown/forged native values
refuse. Resource limits map to external_profile_limit, unsupported producer or
consumer mechanics to unsupported_external_profile, and changed raw/semantic/
capture identity to stale_external_basis. This stage has no I/O, clocks, queue,
retries, persistence or activation. Current trust, actor/grants, enrollment,
physical evidence and final Store/handoff checks remain required later stages.

Freeze the envelope schema in priv/profiles/external-envelope.schema.json and
independent source/identity vectors under test/fixtures/profiles before code.
The archive lane compiles fresh Home boundary source against explicitly supplied
core/Runtime/Profiles archives, with routines and Home application startup absent.
It exercises two independently supplied quantities, required/optional operation
refusal, raw variants, changed capture/basis, malformed/oversize closure and native
forgery. It establishes this pure stage, without satisfying the durable/protocol/
physical acceptance obligations below.

The executed command is `elixir bin/check_routines_shadow.exs --profile-consumer`
with required distinct --core-archive/--core-sha, --runtime-archive/--runtime-sha
and --profiles-archive/--profiles-sha arguments. Each archive is independently
verified before extraction under the existing 32-MiB archive/16-MiB contents/
2048-member bounds. It copies exactly Id, EnvelopeCodec and ExternalEnvelope
from Home source, plus the owning independent fixtures/schema/consumer. Missing,
duplicate, mixed-mode or mismatched arguments refuse before executing archive
code. The ordinary application reports profiles_producer_unavailable until a
coherent producer dependency is selected; an owned local HEAD is not a CI pin.

External WPF definitions describe typed values, units/quantity identity and
model mappings. Home accepts their current meaning only after source review and
exact binding/device qualification. A generic readable contract/renderer can
support another bounded declared quantity using installed mechanics without a
new sensor enum. An unfamiliar physical meaning remains inspection-only until
accepted; schema validity does not make it a trusted automation fact.

The first standard Home normalizations are below. This is an initial consumer
subset, not the exhaustive sensor ontology. Scalar/list/object interpretation
outside this subset uses an exact accepted external definition and supported
consumer schema/renderer; unsupported controls and routine inputs remain unavailable.

| Meaning | Value/unit and exact meaning |
| --- | --- |
| Temperature | Signed integer millidegrees Celsius, mdegC, at least -273150; invalid sentinel is unknown |
| Relative humidity | Integer ppm 0..1000000; not absolute humidity |
| Illuminance | Nonnegative integer millilux, mlx; not irradiance |
| Contact closed | Boolean report, no unit; not a lock/security guarantee |
| Motion detected | Boolean detection report; not continued occupancy |
| Battery fraction | Integer ppm 0..1000000; no inferred voltage/charge curve |
| Battery voltage | Nonnegative integer microvolts, uV |
| Active electrical power | Signed integer mW; qualified import/export sign convention |
| Cumulative electrical energy | Nonnegative integer mWh; direction/register/reset/wrap/source epoch explicit |

Normalized integers fit signed 64-bit. Use exact checked rational conversion;
inexact required conversion refuses unless an installed qualified error policy
exists. Do not threshold with guessed float tolerance, clip, turn unknown into
zero/false or infer physical meaning from a name/dimension. Other quantities keep
their exact external identity, unit, quality and provenance. Nonlinear processing,
waveforms and media require separately selected codecs/components/stream contracts.

## Binding and observation joins

A selected installed WPF Binding registration owns its closed selectors and
supported operations/codec contracts. WoTEx protocol packages own framing,
authentication/session/correlation and finite resource behavior. Home resolves
private instance endpoints, credentials, interview evidence and actual channels;
a profile fingerprint cannot author those facts.

Initial candidates remain ZCL read/report and a commissioned MQTT observation
stream. ZCL endpoint/cluster/attribute and type selection must match host-captured
evidence. MQTT field extraction is bounded JSON Pointer over that enrolled
payload, without JSONPath, regex or expressions. Broker/topic/account policy
remains private setup. Returned decoded C02 values enter WPF interpretation;
Home verifies source/profile/definition/codec/compiler/capture basis again before
Store accepts an observation. Retained/replayed data cannot renew source freshness.

Malformed/missing/stale values remain invalid/unknown/stale with actual source
provenance. A changed capture/firmware/definition/compiler retires the projection,
not merely its label. Arrays/records obey their admitted structural bounds;
media payloads are not base64 blobs in the Store/API.

Later routine use goes through WRO.05's exact supported correspondence. Current
WRO.01's first dimensions/types are not broadened by adding a descriptor.
Unrepresented behavior or analysis refuses; the generic reader remains usable
with routine/voice/Matter/AI services absent.

## Selection, effect authority and recovery

WOH.18 owns immutable raw bytes, projection/closure identities, private custody,
trust review, selection/history, retention and maintenance. Review shows additions/
removals, quantity/unit/range, binding/codec/behavior changes and affected grants/
routines. Publisher approval is not successor activation or device qualification.

One Store transaction rechecks current actor/grants, actual capture, accepted
definition/binding/compiler and full output/effect resource scope before selection.
New channels/operations do not widen distributed grants; use explicit re-enrollment/
grant-and-rotate. Replacement/revocation invalidates dependent observations and
unsent work; handed-off effects retain unknown outcomes. No profile activates a
routine or receives the Store connection/principal bearer.

Backup retains exact selected closure and historical identities. Missing bytes,
unreported/replaced physical unit, changed host/codecs or revoked trust block
dependent active use; restore never auto-fetches/relabels a successor. V1 history
remains interpretable. WOH.17 optional pure codecs cannot hide stateful SDKs,
source capture, streams or device authority inside a decoder.

## Acceptance obligations

H18-T11: two independent authors add supported different models and an unfamiliar
quantity through public WPF mechanics, without reader/vendor branches in Authority,
Store/rules/Swift. At least one multi-channel sensor and two qualified protocol
paths exercise normalized values, external units, raw sentinels, invalid/stale
provenance, quantity-kind mismatch and counter reset. Test an inspection-only
unknown meaning and unsupported routine shape; neither acquires control authority.

H18-T12: refuse unsupported binding/schema/operator/security/behavior and malformed,
cyclic, over-budget or missing closure; no fetch/module/code execution. Race new
definition/firmware/compiler with compile/project/Store/use, selection/revocation
and handoff. No stale acceptance or widened grant. Offline/reader-only operation,
restart and missing-dependency restore retain exact history and blocked effects.

Software/archive/installed/physical evidence is recorded separately. Passing
the reader, approval or decoder cannot qualify a device or its actual effects.
