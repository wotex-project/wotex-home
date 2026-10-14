# Generic external read declarations

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-08/H18-T11/T12; WOH.01 H01-05/H01-T6.
Implementation: planned. Evidence: missing.

## Result and boundaries

Home derives an inert read declaration for one supported external channel using
an independently supplied host consumer contract and explicit household policy.
A new quantity does not require a vendor/model/sensor enum in this algorithm.
The declaration is preparation for later current target selection and canonical
observation admission. It does not create an enrolled Thing, authorize a report,
issue a grant, qualify hardware or admit a routine. Existing executable Light/
SmokeDetector declarations and their durable table shape remain unchanged.

The [v2 envelope](device-profile-mappings-v2.md) owns exact byte/capture/installed
producer correspondence. The [value contract](external-values-v1.md) owns the
closed five-field consumption contract, supported integer/Boolean/external
values, exact public WPF unit conversion and preserved quality/provenance.
The [trust contract](external-trust-v1.md) owns current local approval; this
pure declaration cannot replace its current policy/author checks. Host policy
and source evidence remain assertions until their owning durable review and
physical qualification transitions actually accept them.

## Inputs, identity and output

Profiles.ExternalReadDeclaration.new/5 takes checked ExternalEnvelope, complete
host consumer contract, household policy, channel_id and identical eight-field
reader limits. All are explicit; there is no environment, Store, credential,
clock, network or source lookup. Channel is a Home ID. Policy contains exactly
thing_id, capability_key, evidence_ref, risk_class and freshness_ms. The three
IDs are Home ASCII IDs of 1–128 bytes. Risk is ordinary or sensitive; freshness
is an integer 1..86400000 milliseconds. No defaults or role/display label imply
meaning, risk or accepted physical evidence.

The consumer contract is exactly reference, semantic_ref, value_kind, unit and
constraints, with the bounds and identity from the value contract. Expose
ExternalValue.consumer_identity/2 as the same checked public constructor seam
used by report consumption: it returns the existing contract_sha256 and errors,
not a second schema/unit validator. Missing public producer APIs remain
profiles_producer_unavailable. A forged or malformed consumer is
invalid_external_value and resource excess external_profile_limit.

**ED-01 — Derive from the checked channel.** Revalidate the entire native
envelope through ExternalEnvelope.to_map/2. Regenerate its producer projection
through public WPF Projection.to_map/2; never read an unchecked native plan.
Selected channel must be present in the summary's included home_contracts with
exact consumer reference and in the regenerated supported channel plans.
Its semantic reference must equal consumer.semantic_ref. It must offer at least
one readproperty, observeproperty or subscribeevent operation. Excluded, unknown,
mismatched or unsupported channel refuses unsupported_external_declaration.
No write operation appears in the resulting Home declaration.

Integer consumers require the selected checked definition's value_schema.type
integer or number, non-null checked source/target WPF units and exact equal
quantity_kind and dimension. Boolean consumers require value_schema.type boolean
and null source unit. External consumers preserve the checked producer schema
and original unit; supported structural/numeric/resource mechanics remain WPF's
responsibility. Unit/dimension equality does not authenticate physical meaning.
No numeric value is converted during declaration; actual reports still pass
ExternalValue.project/4 and its range/exactness/quality guards.

The result data is exactly format wotex-home.external-read-declaration@1,
thing_id, capability_key, evidence_ref, risk_class, freshness_ms, channel_id,
operations (exactly [read]), semantic_ref, contract_ref, contract_sha256,
value_kind, unit, constraints, value_schema, envelope_sha256,
projection_sha256, consumption_sha256 and producer. Integer unit/constraints
are the checked consumer coordinate/range; Boolean unit/constraints are null;
external unit is the selected definition's original unit and constraints null.
Value_schema is the checked producer definition's original schema, not a claim
that converted integers have the same source bounds. Source/consumer distinction
is explicit through value_kind/unit/constraints. Producer contains only the
three archive identities. No selector, source bytes, capture fields or credential
is returned. Format, policy, channel, all semantic/consumer/closure identities
and output fields participate in SHA-256 of UTF-8
wotex-home.external-read-declaration@1, newline and public canonical core JSON.
Output fits min(65536, reader.max_bytes), depth eight, 4096 nodes, collection 256
and string 4096. Unknown/struct policy fields refuse invalid_external_declaration;
resource excess refuses external_profile_limit. There is no durable receipt.

**ED-02 — Recheck original and current policy.** Native declaration has exactly
inputs, data and sha256 plus its struct tag. Inputs is exactly envelope, contract,
policy, channel_id and reader_limits. to_map/5 takes native value and current
envelope, contract, policy and identical limits. Rebuild from every retained
input and compare every native field before comparing the newly supplied current
declaration digest. Forgery refuses invalid_external_declaration; changed current
policy/contract/envelope/limits refuses stale_external_basis. Successful export
returns exactly data and sha256. Equal reconstruction has no time/freshness effect.

## Failure, compatibility and implementation entry

Pure retries rebuild the same value; restart discards it. It cannot serve as an
approval token or quarantine activation record. Later durable target/observation
owners must bind exact current trust, accepted policy, enrollment, source custody,
actual Store clock, grants and physical qualification independently. Firmware,
capture, units, accepted meaning, risk, freshness or raw closure replacement
requires new preparation and reviewed durable succession, never an old label.
Counters/reset/wrap/energy direction and risky automation remain separately
qualified source/continuity policy; this declaration cannot infer them.

Public producer errors stay payload-free: resource/numeric limits map to
external_profile_limit, missing API to profiles_producer_unavailable and other
invalid projection/unit correspondence to unsupported_external_declaration.
Inherited envelope and consumer constructor errors retain their typed outcomes.
This slice changes no schema, host configuration or dependency pin. Freeze
independent output/digest vectors for two quantities before code; then implement
the shared consumer identity seam and generic declaration without any quantity
name branch. Installed policy delivery and current durable usage remain later work.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| ED-T1 | 01/02 | Independent temperature and unfamiliar density: exact policy/consumer/channel yields frozen declaration/hash and only read. A sensor-name branch, wrong unit/range/schema or hidden grant fails. | Pure/software |
| ED-T2 | 01 | Wrong channel/semantic/contract, excluded channel, wrong quantity dimension, Boolean source unit, unknown/struct/native fields and policy bounds. Any accepted unsupported correspondence fails. | Pure/software |
| ED-T3 | 02 | Forge native data/input/digest; change current raw closure, capture, contract, policy or limits. Accepting old basis or renewing any report fails. | Pure/software |
| ED-T4 | 01/02 | Producer absent and resource limits; external schema/unit preservation and independently typed Boolean source. A local substitute, unbounded output or write capability fails. | Pure/software |
