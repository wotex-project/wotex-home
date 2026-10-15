# Inert external routine fact projection v1

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.20 H20-01/04, H20-T1/T3; WOH.18 H18-04/05.
Implementation: entry schema/vector frozen; projection planned. Evidence: three
entry shape/hash cases pass; producer execution milestone and
[Home source review](../provenance/routines-external-input-2026-10.md);
the Home projection cases below have not executed.

## Result, ownership and dependencies

WotexHome.Rules.ExternalFact.project/4 joins one existing native ExternalValue
to a WRO.01 Fact and WRO.05 external binding through the actual public reader.
It returns an inert, bounded JSON result with both original witnesses.
A temperature value consumed by Home in thousandths can become a routine input
in centidegrees without treating the Home-converted coordinate as the original
reader output. External profile and installed Basis identities remain distinct.

[External values](external-values-v1.md) own the native Home value, exact checked
envelope, original report, current consumer contract and selected reader limits.
ExternalValue.to_map/4 regenerates those retained inputs and compares the current
envelope/consumer/limits. Its exported data may contain a converted unit/value;
it is not necessarily the original WPF Proposal.

WPF.02 owns public Interpreter.project/3 and Proposal.to_map/2. WRO.05 owns
InputMapping.to_map/3, Input.project/4 and Input.binding_basis/3. Their accepted
execution successor supports required-but-null received_at, explicit conservative
receipt precision and complete installed external bindings. The producer is
implemented at WoTEx 743ef568 with archive/mutation evidence at d1b2e87b. Home's
current f3e77a43 selection lacks this complete seam; select and verify the new
exact source before implementing this consumer. Current source selection,
runtime inventory and historical proof invalidation retain their existing owners.

[External observations](external-observations-v1.md) own actual receipt custody,
current target/source/author/trust/policy checks, Store boot and retained sequence.
This projection grants none of those facts. It creates no Store connection,
current fact read, rule activation, effect, retained timer/lease, service or route.
The existing admitted explicit Boolean rule and legacy FactReadModel retain
their accepted scope. A subsequent current collection contract must obtain and
revalidate qualified inputs through Authority and the single Store.

Revalidating a Home runtime producer assertion delegates to the existing bounded
RuntimeArtifacts inventory: it may read compiled BEAM bytes and use temporary
readers with its existing cleanup rules. Do not bypass that check to call the
whole operation pure or replace it with a cached assertion. Historical archive
assertion fixtures retain their existing closed-shape semantics; they do not
establish current compiled-code correspondence. The value/receipt algebra adds
no transport, custody-file lookup or clock sampling.

## Closed inputs and limits

project/4 takes, in order, native value, Mapping, metadata and context:

| Input | Exact representation and source |
| --- | --- |
| value | Existing ExternalValue native struct, including exactly inputs/data/sha256; revalidate with ExternalValue.to_map/4 before reading its original report |
| mapping | Complete plain WRO.05 Mapping or its exact native InputMapping; its complete Basis, correspondence and own identity must be installed in context.registry |
| metadata | Plain object with exactly the WRO.05 observation metadata fields below, all present; no native struct |
| context | Plain object with exactly consumer, envelope, limits, reader_limits and registry; no defaults or additional fields |

context.envelope is the current exact native ExternalEnvelope.
context.consumer is the current closed Home consumer contract with reference,
semantic_ref, value_kind, unit and constraints. context.reader_limits is the
complete explicit WPF limit selection; ExternalEnvelope.check_reader_limits/1
enforces Home's existing ceilings. A different retained reader limit selection
is stale even when it would accept the same value. context.registry is the
explicit WRO Registry input, either its complete record list or exact native
value accepted by its public constructor. No ambient registry is consulted.

context.limits is a complete WRO Limits selection or its exact native value.
Every integer limit must be positive and at or below these inclusive ceilings:

| Limit | Maximum |
| --- | --- |
| max_bytes | 262144 |
| max_depth | 32 |
| max_nodes | 20000 |
| max_string_bytes | 8192 |
| max_collection_size | 128 |
| max_integer | 9223372036854775807 |

Narrower positive selections are allowed. There is no automatic enlargement,
truncation or partial result. The complete output, including its entire embedded
Mapping, must satisfy selected JSON and integer limits. Every embedded occurrence
is charged. Public producer constructors own bounded native revalidation of the
envelope, report, consumer, Registry and Mapping; their fixed input ceilings stay
in force before projection. Atom keys, improper lists, extra native fields,
unknown context/metadata members and forged native values refuse.

Metadata has exactly id, thing_id, affordance_type, affordance_name, source_class,
source_id, source_epoch, sequence, source_time, source_time_trust, source_time_basis,
source_uncertainty_ms, received_at, receipt_epoch, receipt_ms, profile_digest,
replay, continuity, expires_ms, derivation_digest and contributors.
Their closed WRO.01 types and WRO.05 correspondence checks apply: source identity,
channel/affordance, external profile digest, original sequence, source UTC/trust/
basis/uncertainty and continuity/replay must agree with the Mapping and original
Proposal. Receipt epoch/coordinate must agree with its explicit clock.

received_at must be explicit null in this profile: the native decoded report
contains no receipt UTC witness. Source UTC, processing/evaluation time or an
epoch cannot fill it. An omitted or non-null received_at refuses. This deliberate
consumer restriction does not change the broader WRO Fact grammar.
Thing identity and Fact ID are explicit inert consumer data, not enrollment.
No credential, Store handle, transport endpoint or current-authority claim is an
input. Household source qualification and semantic correspondence remain the
responsibility of the future current collector, not this constructor.

## Requirements and deterministic projection

**REF-01 — Recover the original interpretation.** Revalidate the native value
against exactly context.envelope, context.consumer and context.reader_limits
through ExternalValue.to_map/4. Then call the public WPF Interpreter.project/3
using the checked envelope's original projection and value.inputs.report.
Revalidate the resulting complete Proposal with Proposal.to_map/2.
Do not derive it by deleting Home-only fields from value.data, reuse its converted
normalized_value/unit as the original, or reconstruct source/receipt timestamps.
Retain the independent Home external-value SHA and WRO original-proposal SHA.

**REF-02 — Preserve complete installed correspondence.** Use public
InputMapping.to_map/3, Input.project/4 and Input.binding_basis/3 under the selected
Registry/Limits. Input.project receives the actual reconstructed Proposal and
complete supplied metadata; its context contains exactly registry, limits and
reader_limits. Revalidate the resulting Fact with its public to_map/2.
Return the complete external binding without changing the Fact profile digest
to the Basis digest or erasing its embedded Mapping. Unsupported units/types or
source, profile, capture, compiler, correspondence and installation drift refuse.
The pure supplied Mapping's validity does not establish qualified installation
in Home, actual report custody or a current snapshot.

**REF-03 — Keep receipt precision and lifetime explicit.** Both WRO clock
alternatives retain their exact producer meaning. The original four-member
clock requires a delta divisible by 1000; an unaligned delta refuses inexact
conversion. The six-member floor_millisecond clock requires
target_origin_ms + floor((original_receipt_us - source_origin_us) / 1000),
including negative fractions and exact 65-bit intermediate subtraction.
Final coordinates and bounded expiry addition must fit selected Limits.
The floor mode caps expires_ms at projected receipt plus Basis freshness;
earlier supplied expiry is preserved. Expiry remains exclusive.

This helper does not sample a receipt/evaluation clock, infer a clock pair or cap
expiry from processing time or upgrade an old Store boot. When a later qualified same-host Store
collector supplies source_origin_us = 1000 * Store.clock_origin,
target_origin_ms = 0, the expression equals the existing original receipt floor
minus Store.clock_origin. That collector must bind actual report-owner and Store
boot incarnations, reject preboot/future/expired evidence and retain all narrower
declared/owner lifetime bounds. Numeric equality here cannot prove that relation.

**REF-04 — Closed output and honest failures.** Return {:ok, result} with
exactly these eight JSON members:

| Member | Value |
| --- | --- |
| format | wotex-home.external-routine-fact@1 |
| scope | external_fact_projection_only |
| external_value_sha256 | Exact unprefixed lowercase Home ExternalValue SHA-256 from its checked export |
| source_proposal_sha256 | Exact unprefixed lowercase original Proposal witness from Input.project |
| mapping_ref | Exact id/version/sha256 Mapping reference from Input.project |
| correspondence_ref | Exact installed correspondence reference from Input.project |
| fact | Complete checked plain WRO Fact map |
| binding_basis | Complete checked wotex.routines.external-binding@1 record |

No field is added by a default; no opaque raw report, Home envelope, source
capture, credential, endpoint, PID, current-time read or authority token appears
in the result. Source identity and declared semantic data retain their explicit
Fact/Mapping scope. With equally available validated producer artifacts, the same
complete inputs yield equal results.

Failure returns only {:error, atom}; no payload, producer exception or caller
text is echoed. Codes are:

| Code | Meaning |
| --- | --- |
| invalid_external_fact | Malformed/forged native input, closed grammar or metadata, invalid known producer value |
| external_fact_limit | Invalid/excessive selected limits, aggregate/input/output bound or integer overflow |
| external_fact_unavailable | Missing required public API, reader capability or unavailable selected runtime inventory |
| stale_external_fact | Changed envelope/consumer/reader limits or a producer stale-basis/receipt correspondence refusal |
| unsupported_external_fact | Unsupported quantity/dimension/type/operator/semantic scope or missing installed correspondence |
| inexact_external_fact | Inexact scalar conversion or unaligned original exact receipt clock |
| external_fact_refused | Unexpected producer result, exception, throw, exit or unclassified refusal; no fallback |

Existing producer errors are reduced to these static codes. Preserve invalid,
unknown and stale qualities as producer Fact data rather than substituting
false/zero; retained/replayed/gap inputs retain their exact continuity/replay.
An unusable inert Fact may be returned but cannot establish a known predicate
outside the WRO evaluator's independent qualification rules.

## Retry, recovery and compatibility

No durable state or retained resource is allocated. Temporary compiled-inventory
readers retain their owner's bounded cleanup. Repeating equally validated inputs
returns equal data; there is nothing to refund, replay physically or restore.
Retained results are historical computations, never current fact tokens.
Changed envelope, consumer, reader limits, Mapping, source or code requires
regeneration from the original inputs. A caller may not relabel an old result.
Missing raw bytes/producer is unavailable/refusal, not permission to reuse a
previous successful result. A future Store collector must distinguish receipt
history from current freshness and preserve quarantine on restart/restore.

This addition changes no legacy Capability, Value, observation, rule source,
admission proof, original receipt, schema table or physical dispatch default.
It adds no automatic external Mapping installation or worldwide sensor enum.
Current Store fact use, reported-edge persistence, complete-set collection,
composition and broader admission require their own accepted integration
contracts, exact runtime correspondence and transaction/fault evidence.

## Implementation entry and acceptance

Before code, freeze priv/profiles/routine-external-fact.schema.json and independent
test/fixtures/profiles/routine-external-facts.json. The schema embeds local
producer Fact/Mapping/binding definitions and the closed Home result envelope;
it checks shape, not installation, digest truth or clock qualification. Original
fixture/profile/consumer references and expected Home/reader/routine values,
proposal hash, external identity, null UTC and signed receipt coordinate must be
independently committed. No runtime reads documentation or test fixtures.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| REF-T1 | 01/02/04 | Actual Home ExternalEnvelope/ExternalValue -> original WPF -> Input/Fact/binding -> routine Snapshot/Evaluation/Kernel, including integer/Boolean/enum and Home-converted coordinates | Native software |
| REF-T2 | 01/02/04 | Changed native inputs/data/hash, current envelope/consumer/reader limits, Mapping installation/semantic/profile/source or extra fields | Static refusal; no fallback/known value |
| REF-T3 | 03/04 | Independent signed floor vectors, 65-bit subtraction, exact mode, wrong epoch/coordinate, exclusive expiry, earlier expiry and missing UTC | Pure plus actual producer |
| REF-T4 | 01–04 | Narrow selected bounds, aggregate Mapping wrapper, absent public producer and isolated producer failure | Bounded payload-free refusal; no leaked caller text |
| REF-T5 | 01–04 | Exact selected consumer cohort plus independent extracted reader/routine artifacts; identity/original-coordinate mutants | Archive software |

Temperature example: original raw report 25 under a one-tenth profile yields
reader 2.5 degrees, Home consumer 2500 thousandths and routine Fact 250
centidegrees. The original -1001 us at origin 0 us/10000 ms yields receipt 9998
and, with freshness 1000, exclusive expiry at 10998. received_at stays null.
Reusing Home's converted 2500 with the original reader unit would yield a wrong
Fact; the independent expected 250 falsifies that shortcut. An unchanged profile
with the wrong Mapping source/clock or absent installation must refuse, while a
changed Fact profile under a valid external snapshot becomes unknown.

The independent oracle uses exact rational conversion, mathematical floor and
sorted UTF-8 JSON hashing, not the adapter's own result. Record exact sources,
locks, fixture digests, toolchain and executed commands. Pure/software/archive
success does not qualify a household source, clock, Store commit or device.
