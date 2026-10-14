# Exact external value consumption

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-08/H18-T11–T12; WOH.01 H01-05/H01-T6.
Implementation: pure checked report/consumer value boundary implemented.
Evidence: seven exact-archive consumption cases plus focused unavailable/v1
regressions; current durable observation admission remains separate.

## Purpose and ownership

Home projects one decoded external report through the checked v2 envelope and
an explicitly selected Home consumption contract, preserving its complete
quality and provenance while converting a supported quantity exactly. This
pure component produces an inert value. It does not enroll a Thing, accept an
observation into SQLite, renew freshness, issue a grant, activate a rule or
qualify a physical source. Existing Light/SmokeDetector values and v1 profiles
are unchanged.

The [v2 envelope](device-profile-mappings-v2.md) owns exact original documents,
installed producer registrations, capture and included channel/contract joins.
Public WPF Interpreter.project/3 and Proposal.to_map/2 own report interpretation
and the closed 18-field proposal; Unit.to_map/2 and Unit.convert/4 own supplied
quantity coordinates and rational conversion. Home must not copy their parser,
schema, numeric algebra or quantity catalogue. These APIs exist in the selected
three-archive cohort. Missing APIs are profiles_producer_unavailable. The pure
component accepts explicit inputs and has no clock, credential, Store, network,
filesystem, module loader, application environment or device port.

## Inputs and exact contract

Profiles.ExternalValue.project/4 takes a checked ExternalEnvelope, one decoded
WPF report, a host-selected consumption record and identical reader limits.
The report has the producer's 13 exact fields, including its actual channel,
profile/binding/capture epoch, source/receipt time and decoded C02 value. It is
data, not evidence that a real device emitted it. Report input is non-struct
native JSON; public core JSON.encode/2 bounds complete bytes by min(65536,
reader.max_bytes), depth eight, 4096 nodes, collection 256 and string 4096
before interpreter construction. C02 independently enforces its depth-eight,
1024-node, 256-member and 64-KiB limits. Caller limits may only narrow the
existing complete eight-field v2 reader selection; there are no defaults.

The consumption record contains exactly reference, semantic_ref, value_kind,
unit and constraints. Reference and semantic_ref are exact WPF-shaped references
with absolute URI ≤256 bytes, canonical version and lower-hex64 identity.
Reference must equal the current included envelope channel's Home contract.
Semantic_ref must equal the interpreted proposal's selected external definition.
Both joins are exact, including version and SHA; matching a label/dimension is
insufficient. Reference identifies a host-installed registration; it is not a
claim that its SHA hashes this five-field projection. The host supplies this
record from independent accepted meaning/risk policy, never from the model or
report. This component checks supplied correspondence, not host installation,
source review or current trust.

| value_kind | unit | constraints | Observable result |
| --- | --- | --- | --- |
| integer | Exact non-null public WPF Unit | Exactly min/max signed-64 integers with min ≤ max | Exact converted signed-64 C02 sint in the declared inclusive range |
| boolean | null | null | C02 boolean; source proposal must have null unit |
| external | null | null | Original checked C02 value and original declared unit, without conversion |

Unknown fields, structs, malformed references/units/bounds/kind or fields
inconsistent with this table refuse invalid_external_value. Contract encoding
must fit 8192 bytes, depth eight, 512 nodes, collection 32 and string 256 before
public unit validation. Integer source and target must both be public checked
Units with identical quantity_kind URI and seven-dimensional vector. A mismatch
refuses unsupported_external_value even when quality is not usable. Boolean
source unit must be null. External mode explicitly preserves bounded
scalar/list/record values; it does not expose an unsupported renderer, routine
input or control. No new sensor/model name is added to the generic algorithm.

ExternalValue.consumer_identity/2 exposes the same checked consumer constructor
for [generic read declarations](external-read-declarations-v1.md). It first
applies the complete eight-field Home ceiling validation through
ExternalEnvelope.check_reader_limits/1; invalid/excessive limits refuse
external_profile_limit. It returns the same contract_sha256 and creates no
report or authority. The existing report path uses this same validation.

Contract_sha256 is SHA-256 of UTF-8 wotex-home.external-consumer@1, newline and
public canonical core JSON of the complete five-field record. This separately
binds the actual selected consumer data, including its asserted registration
reference. It is not a WPF semantic-reference identity.

## Requirements and transition

**EV-01 — Interpret the selected basis.** Revalidate the envelope through its
public Home to_map/2 boundary using identical reader limits. Only its included
channels may enter consumption; an excluded/unknown channel or mismatched Home
contract refuses unsupported_external_value. Invoke public Interpreter.project/3
on that checked projection/report, then Proposal.to_map/2. Recheck the exact
semantic_ref before consumer conversion. Stale report profile/binding/capture
joins refuse stale_external_basis; an unsupported required producer shape
refuses unsupported_external_value. No caller-supplied proposal bypasses this
interpretation step.

**EV-02 — Convert without guessing.** For usable integer proposals invoke
Unit.convert/4 on the interpreted C02 value, original unit and selected target.
Accept only its exact signed-64 sint result within min/max. A decimal result
or repeating-fraction refusal is inexact_external_value; an unsigned result
outside signed-64 or a range violation is external_value_out_of_range. A
non-numeric usable value is unsupported_external_value. There is no float,
rounding, clipping, primitive coercion or guessed scale/quantity identity.
Usable booleans preserve their exact C02 boolean. External mode preserves the
complete checked original normalized_value and unit.

Initial standard temperature uses millidegrees Celsius, at least −273150;
humidity and battery fraction use ppm 0..1000000; illuminance uses nonnegative
millilux; voltage nonnegative microvolts; active power signed milliwatts;
cumulative energy nonnegative milliwatt-hours. The accepted host registration
must supply each exact quantity URI/coordinate and range. This pure component
does not discover those registrations or infer direction, counter resets,
security or occupancy meaning. Unfamiliar quantities retain their exact external
identity or use an explicitly accepted supplied integer coordinate.

**EV-03 — Preserve uncertainty and time.** Producer qualities invalid, unknown
and stale remain those exact strings/reasons with C02 null. Do not convert a
null into zero/false; target unit remains the selected integer unit, null for
boolean, original for external. Preserve continuity, source_ref/epoch/sequence,
source_time and receipt_time exactly, including absent sequence/time, untrusted
source time, negative monotonic origin and retained/replayed continuity. No
processing time is substituted. Usable does not mean fresh or authenticated.
Later Store admission must apply its actual source custody, epoch, enrollment,
grants, trust, freshness and current selection independently.

**EV-04 — Bind and recheck the inert value.** Native ExternalValue has exactly
inputs, data and sha256 plus its struct tag. Inputs is exactly envelope, report,
contract and reader_limits. Data contains all 18 checked Proposal fields in
their public representation, with unit/normalized_value replaced only by the
consumer result, plus exactly format wotex-home.external-value@1,
consumption_sha256, contract_sha256, contract_ref and value_kind. Interpretation
preserves the producer's original profile_declared/unconverted disposition;
value_kind separately identifies the Home consumer conversion.

Data is bounded by min(65536, reader.max_bytes) encoded bytes with the same
depth/node/collection/string limits as the report. Sha256 hashes UTF-8
wotex-home.external-value@1, newline and public canonical core JSON of data.
to_map/4 takes the native value, current checked envelope, current selected
contract and identical limits. It recomputes the original value from all retained
inputs, compares every native field, then compares current envelope consumption
identity and current contract SHA. Forgery refuses invalid_external_value;
changed current selection refuses stale_external_basis. Success returns exactly
data and sha256, without raw report, envelope bytes, private capture or selector.
The value provides no authority token and disappears on restart unless a later
owning durable contract retains it.

## Failures, compatibility and entry

All errors are payload-free {:error, atom}; no producer path, decoded source
value or private capture fragment is returned. Public producer byte/depth/node/
collection/string/numeric/output limits map to external_profile_limit.
Producer stale_basis/reference_conflict map to stale_external_basis; unsupported
mechanics to unsupported_external_value; inexact_conversion to
inexact_external_value; other invalid data to invalid_external_value. Envelope
failures retain their existing typed outcome. No retry, remote fetch, repair,
cancellation, persistence, schema migration or active selection occurs here.

Before code, freeze independently calculated coordinate/contract identities in
test/fixtures/profiles/external-values.json and the exact consumption-record
shape in priv/profiles/external-consumer.schema.json. Test in the fresh explicit
Core/Runtime/Profiles archive consumer, with no neighboring checkout, Home host
or routines dependency. This component precedes durable v2 observation admission
and does not broaden the existing Semantics.Value/Capability vocabulary.

| Case | Requirements | Stimulus and falsifier | Evidence |
| --- | --- | --- | --- |
| EV-T1 | 01/02/04 | Independent Celsius→millidegrees and unfamiliar density→milli-coordinate vectors; wrong SHA/value or a sensor enum fails. | Pure/archive |
| EV-T2 | 02/03 | Sentinel/null, unknown/stale and retained/replayed reports with actual source/receipt fields. Zero/false substitution or altered time/continuity fails. | Pure/archive |
| EV-T3 | 01/02 | Changed semantic/consumer ref, same dimension with wrong quantity kind, inexact fraction, range/signed-64 excess and non-numeric usable input. Acceptance or rounding fails. | Pure/archive |
| EV-T4 | 01/04 | Wrong report profile/binding/capture, excluded channel, changed current envelope/contract/limits, forged native fields/data/SHA. A current summary of stale/forged data fails. | Pure/archive |
| EV-T5 | 01–04 | Boolean and external bounded values; malformed closed contract/report, over-budget strings/bytes/nodes and absent producer. Fallback or unbounded construction fails. | Pure/software |

Independent Python rational calculations and literal expected C02/provenance
records are the oracle. Software vectors establish correspondence, not actual
device authenticity, current authorization, freshness or qualification.

The [software record](../provenance/external-values-2026-10.md) binds the
implementation, independent fixtures and actual checks.
