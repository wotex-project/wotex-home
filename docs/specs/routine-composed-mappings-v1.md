# Installed mappings for composed routines v1

Version: 0.1.2. Updated: 2026-10-16. Status: accepted target.
Owner: WOH.20 H20-01/03/04/06/09; WOH.01 declarations; WOH.18 input custody.
Implementation: planned; no activation, dependency or dispatch change.
Evidence: source reconciliation and the limited generic feasibility probe below;
Home RCM-T1–T10 remain unexecuted obligations.

## Result and boundaries

A Home routine selects exact enrolled capabilities by opaque target/key and
reviewed declaration identity. Home derives its generic installed context;
an author never supplies executable Registry/Basis objects, endpoints or grants.
For example, a reviewed external temperature input can gate two absolute Light
power writes without turning that sensor's readable data into a writable device.

This contract owns the immutable source bundle, pure Home-to-WRO mapping,
native scalar Basis templates, external Mapping reuse and projection identity.
The [composed profile](routine-composed-profile-v1.md) owns source expansion
and calculation bounds. WRO.02 owns the generic source/compiler grammar;
WRO.01 owns exact values and units. Do not duplicate their parser, compiler or
unit conversion. The single Store separately owns current enrollment, authors,
input/target grants, profile qualification, complete active membership, facts,
admission, reservations and transport handoff.

All construction below validates supplied claims. It reads no Store, clock,
credential, private custody or runtime inventory and starts no worker. An
Authority preparation may supply measured data, but the committing Store must
measure and compare it again. Passing a projection's own claims back as its
current environment proves only internal correspondence.

Existing Rules.Rule/KernelMapping source and one-effect admission, portable v1
profiles, external read declarations, external-input packages, original receipt
identities and ordinary direct controls retain their formats and behavior.
No generic valid Program is accepted by an old activation route as a new rule.

## Dependencies and entry conditions

Use the selected public Compiler, Registry, Basis, Unit, InputMapping and
Input.binding_basis APIs, with the exact Profile/Limits in the composed profile
contract. WoTEx `973fb32c` implements the inspected generic seams; Home still
consumes routines `d1b2e87b`. No source pin is changed here.

Home's existing `Durable.Registry.decode_thing/1` and encode_thing/1 own exact
retained Thing bytes. `Rules.ExternalInput.decode/1` parses historical input
Definitions; reconstruct them through ExternalInput.new/3 before native reuse.
The [reviewed input contract](routine-external-inputs-v1.md) owns actual signed
installation/current source/runtime/receipt custody. The
[external Fact contract](routine-external-facts-v1.md) owns reconstructing the
original public reader Proposal and exact Input.project/4 join. A copied
Definition or historical signature supplies no current installation.

[Durable membership](routine-active-membership-v1.md) now specifies the complete
selected family and reviewed legacy replacement. [Independent clock bases](routine-clock-bases-v1.md)
specify qualified elapsed/UTC custody and Time@2. Their implementation/native
qualification, the complete current snapshot, run/step/root journal, composed
correspondence/admission and client/host contracts remain entry conditions for activation.
In particular, the current native execution writer implements Boolean power,
not the scalar write matrix below. Brightness/Kelvin require their own real
guarded execution/readback implementation and cohort qualification before use;
inert mapping success cannot select a worker or enable those writes.
The current native observation record lacks explicit reconnect/replay continuity
custody. Native snapshot inputs therefore do not support reported-edge triggers
under this version. A separately specified/implemented native continuity witness
is required to add that support; external reviewed continuity is retained below.

## Closed source bundle and supplied environment

**RCM-01 — Select exact meanings.** The source bundle is a plain string-keyed
object with exactly format, source, definitions, arguments and bindings.
format is `wotex-home.routine-source@1`. source is the complete WRO.02 root
Source; definitions is the complete child Source array, at most 63, sorted by
source id bytes and unique by id. arguments contains exactly the root's declared
parameter names and typed values. Root/child source ids, step ids, parameter
names and binding aliases are Home IDs: 1–128 ASCII bytes matching
`[A-Za-z0-9][A-Za-z0-9._:-]*`. Source revisions are canonical positive decimal
strings within signed-64, without signs or leading zeroes. Child calls select
that exact revision, never latest. Reject an old arbitrary revision label rather
than silently rewriting it into this new namespace.

bindings is a sorted-by-name array of at most 32 selectors with unique names.
Names equal the union of every binding declared in the root and supplied child
sources, including unused child sources. No missing or additional selector is
accepted. Distinct aliases may select one target/key, but cannot assert
inconsistent declarations or external installations for it. Every selector
has exactly these required members:

| Member | Type and meaning |
| --- | --- |
| name | Home binding alias |
| kind | native_read, native_write or external_read |
| target_id, capability_key | Exact Home IDs; no pattern, discovery or group expansion |
| declaration_sha256 | Bare lowercase SHA-256 of the entire exact retained Thing document |
| input | external_read: exact install_revision, generation, definition_sha256 object; other kinds: explicit null |

Input install_revision and generation are positive signed-64; definition_sha256
is the exact bare format-separated Definition hash already owned by ExternalInput.
The whole Thing hash is raw SHA-256 of Registry.encode_thing/1's exact bytes;
do not hash only the selected capability or normalize a historical document
through a different encoder. A change to any retained capability is visible.

The complete source bundle must fit 4194304 canonical UTF-8 JSON bytes and the
composed aggregate JSON limits. Each nested Source independently obeys the
32768-byte/16-depth source bounds. Empty definitions/arguments/bindings are
explicit and legal when the complete source needs none. Zero bindings cannot
authorize an effect. Arrays are already sorted where required; reject unsorted
arrays instead of rewriting an immutable input. Preserve source's own ordered
arrays, node IDs, parameter values and enum text exactly.

The native pure operation is `WotexHome.Rules.ComposedMapping.build/2`, taking
source bundle and supplied environment. Environment is a plain object with
exactly runtime_sha256, targets and external_inputs:

| Member | Closed representation |
| --- | --- |
| runtime_sha256 | Supplied bare lowercase SHA-256 of the complete composed runtime cohort; construction does not measure it |
| targets | Array of exact target_id, resource_revision, thing_document objects, unique and sorted by target_id; it covers exactly the selected targets |
| external_inputs | Array of exact target_id, capability_key, install_revision, generation, definition_document objects, unique and sorted by target_id/capability_key; it covers exactly the selected external pairs |

resource_revision is nonnegative signed-64; installation counters are positive.
thing_document is the existing exact Registry document, at most 65536 bytes;
decode and reencode it byte-for-byte, and require its ID and whole-document hash
to match the selector. definition_document is at most 262144 bytes and retains
its original owned wire. Native target/Definition reconstruction rejects extra
struct fields and every declaration/Mapping correspondence failure. Repeated
aliases share one environment record; an unused extra target/input refuses.
All embedded occurrences count against aggregate bounds, including JSON-escaped
document strings. No default or partial environment is accepted.

All objects reject unknown/atom keys, native structs, improper lists, duplicate
identities and malformed UTF-8. Typed integers reject floats and overflow;
hashes use exactly 64 lowercase hexadecimal characters. Byte admission rejects
duplicate JSON object keys before materializing a map. This native contract
does not enlarge existing socket request sizes or create a socket/CLI route.
The owning journal/client contracts must freeze historical encoding and framing
before durable retention or an external route is implemented.

## Supported semantic matrix

**RCM-02 — Preserve types, units and risk.** Both native kinds require an exact
valid `Semantics.Capability`, not a ReadCapability guessed to have the same
shape. native_read requires its declared read operation. native_write requires
both read and write, ordinary risk and an ordinary Light. The supported matrix is:

| Declared role/key | Native value and generic value | Permitted use |
| --- | --- | --- |
| Light/power | Boolean unchanged; null unit, empty enum | Snapshot predicate/wait and absolute native_write |
| Light/brightness | Integer fraction ppm unchanged | Snapshot predicate/wait and absolute native_write |
| Light/colour_temperature | Integer Kelvin unchanged, within declared min/max | Snapshot predicate/wait and absolute native_write |
| SmokeDetector/smoke_state | Exact enum ordered [clear, alarm]; null unit | Snapshot predicate/wait, read only |
| SmokeDetector/fault or self_test | Boolean unchanged; null unit, empty enum | Snapshot predicate/wait, read only |
| SmokeDetector/battery_fraction | Integer fraction ppm unchanged | Snapshot predicate/wait, read only |
| EnvironmentalSensor selected external channel | Exact reviewed boolean/integer/enum InputMapping and original Proposal | Read only; snapshot predicate/wait and eligible qualified external edge |

All other combinations refuse unsupported_composed_mapping. Native HSV/XY
values remain available to their existing readers/direct controls; this scalar
profile does not split them into independently writable axes or coerce them.
Arbitrary external structured values remain readable where their reader permits,
but require an exact executable/analysis successor before routine use. No enum,
state or physical unit is inferred from a label. Source effect steps must use
native_write bindings and reported_match completion. There is no external write,
Action, toggle, relative movement, compensation or implicit diagnostic command.

The exact fraction Unit has dimension fraction, name ppm, scale_n 1,
scale_d 1000000, offset_n 0, offset_d 1, min 0 and max 1000000. The exact Kelvin
Unit has dimension temperature, name K, scale_n 1, scale_d 1, offset_n 0,
offset_d 1 and the capability's exact min/max. Boolean/enum units are null.
Never send normalized fractions as 0–1 floats, reinterpret Celsius as Kelvin,
round a native input or widen a declared domain to compile an argument.
Generic Unit conversion remains the public producer's exact rational operation.

Risk is inherited from the complete retained declaration, not from the fact that
a value is scalar. Sensitive read inputs grant no authority over a detector's
alarm/self-test or another target. The committing use case must authenticate
the original author and current actor with explicit whole-Thing grants for
every read/write target, including those in unchosen and unused child sources.
Write controls and current physical qualification are separate from read grants.

## Exact native installed context

**RCM-03 — Build consumer-owned contracts.** Each contract body has exactly
format `wotex-home.routine-contract.v1`, id, version `1` and obligations in the
exact order below. Its semantic_digest is `sha256:` plus SHA-256 of Wotex's
sorted-key compact JSON of that body. Registry records have id/version/digest
and an empty requires array. These obligations describe host requirements;
including their hashes in a registry does not prove the host performs them.

| id | Ordered obligations |
| --- | --- |
| wotex-home.composed-security | current_authenticated_actor, current_original_author, exact_input_target_grants, exact_output_target_grants, current_installed_basis, single_store_commit |
| wotex-home.composed-lifecycle | inert_proposal, held_before_queue, root_step_reservation_before_queue, handoff_before_transport, no_uncertain_retry, no_refund, preserve_partial_unknown |
| wotex-home.composed-scalar-report | current_qualified_device_report, exact_typed_equality, exclusive_original_receipt_expiry, no_protocol_inference, no_causation_inference |

**RCM-04 — Native Basis template.** One Basis is derived per distinct native
selector tuple (target, key, kind, declaration hash). Repeated
equal tuples reuse one Basis. Basis id is `urn:wotex-home:routine-basis:` plus
bare SHA-256 of the canonical array [wotex-home.native-routine-basis@1, target,
key, kind, declaration_sha256, runtime_sha256]. Version is `1`.
All below members are required; no implementation chooses a default:

| Basis member | Exact derived value |
| --- | --- |
| format | wotex.routines.basis@1 |
| affordance | type property; name exact capability key; operation readproperty for native_read, writeproperty for native_write |
| value | Matrix's boolean/integer/enum type, exact Unit or null, exact enum list or empty list |
| output | null; transport output is not a canonical observation |
| security_contract, lifecycle_contract | Exact composed-security/composed-lifecycle references above |
| required_contracts, annotations | Empty array and empty object respectively |
| evidence | sources [device_report]; freshness_ms exact capability freshness; require_source_time false; continuity snapshot; completion reported_match; exact composed-scalar-report reference |
| effects | native_write: resource_roles [target], repeat never, stop separate_effect, supersession block_until_known, partial_possible true, unknown_possible true; native_read: same values except resource_roles empty and stop unsupported |
| timing | deadline_ms 86400000; duration_ms/dwell_ms/cooldown_ms zero; uncertainty block |
| analysis | classification unsupported, profile null, properties empty |

Compute byte_digest as `sha256:` plus SHA-256 of the whole canonical body
without its four digest fields. Compute semantic_digest with public
Basis.semantic_digest/2. implementation_digest and compiler_digest are both
`sha256:` plus supplied runtime_sha256. Register that exact Basis reference
with requires equal to the security, lifecycle and report references in that
order, then validate the full Registry/Basis through public constructors.

The unsupported analysis member makes no installed Basis model/property claim.
It does not waive Home's separate positive composed source/Store correspondence
requirement or turn an unsupported WRO model request into an admissible result.
That future proof must bind this complete value and make no unsupported device
behavior or physical-success claim. A proof needing an installed device model
cannot obtain one from this mapping.

The installed deadline is stable for this semantic profile. The actual step
deadline is still the minimum of that bound and the root/invoked-child inherited
deadline under WRO.02; a shorter explicit run duration never becomes 24 hours.
Do not derive a different native Basis from each routine's duration. Collection
requires equal installed Basis, binding basis and Fact for the same Thing/
affordance/operation across all members; per-routine installed deadlines would
make two otherwise valid routines on one property incoherent. A separately
authored per-effect timeout syntax needs a producer/consumer successor, rather
than an unknown extra Source member or a hidden Basis rewrite.

Thing IRIs are exactly `urn:wotex-home:thing:` plus unpadded URL-safe Base64 of
the raw Home target ID bytes. Preserve the injective mapping used by the existing
kernel join. Native write's target resource role maps to that same IRI. Native
read has no resource roles. WRO proposals still include the resolved whole Thing
domain; two writes to one light's different keys cannot acquire independent
physical channels through this mapping.

**RCM-05 — Reuse complete external mappings.** Require EnvironmentalSensor and
the exact retained ReadCapability record. Decode the supplied Definition,
reconstruct with ExternalInput.new/3 and require its exact original document.
Its context target/key and resource revision must match the actual supplied
Thing record, selector and environment. Decode that capability's exact retained
ReadDeclarationCodec record and compare its complete data with context.declaration.
Its hash/install counters must match input. Preserve its entire validated
Mapping, Registry and Basis, including
unit/range, original source/epoch, profile/closure/capture/compiler/correspondence
identities, report contract and receipt clock. Do not rebuild it from a simplified
Home scalar declaration or replace its implementation digests with the composed
runtime. Those digests and the complete composed runtime have different scopes.

Context binding uses the Mapping's exact legacy_basis_ref, actual mapped target
IRI and empty resource_roles, as the read-only InputMapping contract requires.
No external Binding may resolve a second Thing. Derive its snapshot binding
later through public Input.binding_basis/3; keep its external profile_digest and embedded Mapping.
Never substitute the installed Basis semantic digest for that external profile.

Merge full external Registry records with the native contract/Basis records.
Deduplicate only completely equal records with the same id. If the same id has
a different version, digest or requires array, refuse composed_registry_conflict.
Do not choose arrival order, trim an unused reference, rename a qualified Mapping
or silently install another contract version. Deduplicate equal Basis records
by id; unequal records at one id refuse likewise. Sort the resulting Registry
and Basis arrays by id bytes and validate the complete closure, including unused
records. Individual Definition reconstruction keeps its own stricter limits;
the merged context additionally obeys the composed aggregate limits.

## Compilation and identities

**RCM-06 — Bind every selection into the Program.** Build bindings for the
union of all supplied sources, preserving each alias. Generic binding records
have exactly basis (id/version/semantic_digest), thing_id and resource_roles.
definitions and arguments are the exact supplied complete values; no extra
prototype, current-value argument or dynamically selected child is inserted.

For each alias derive an origin record with exactly name, kind, target_id,
capability_key, resource_revision, declaration_sha256, input_install_revision,
input_generation and definition_sha256. The last three are null for native
bindings and exact selected installation values for external bindings. Origins
are sorted by alias. Hashes here identify claims; they authenticate no author.

Let C mean Wotex's compact recursively sorted-key JSON under composed Limits,
H mean lowercase SHA-256 of bytes and newline mean the single byte 0x0a:

- source_sha256 = H(wotex-home.routine-source@1 + newline + C(source bundle)).
- mapping_sha256 = H(wotex-home.composed-mapping-basis@1 + newline +
  C([source_sha256, runtime_sha256, origins, merged Registry, merged Bases,
  generic bindings])).
- Generic context.compiler_basis = `sha256:` plus mapping_sha256.

This order has no self-reference: native Bases bind the supplied runtime hash,
not mapping_sha256 or the future Program hash. The mapping hash binds exact
external Definition identities even if two Definitions happen to select equal
legacy Basis descriptors. Context also retains the full merged offline closure.

Call Compiler.compile/4 with the unchanged root source, this complete context,
Profile and Limits; project the complete Program through Compiler.to_map/3.
Apply the composed profile's counting/binding-use checks before returning.
No native snapshot binding may be an edge trigger; refuse
unsupported_composed_mapping. An external edge additionally requires its exact
installed Basis and external Mapping to support WRO's observable type and
continuous qualification; malformed/unsupported edges do not compile to manual.
Due/countdown source fields remain inert claimed schedule id/digest until the
separate current temporal contract joins their exact retained source/window.

Success is {:ok, projection}, a plain object with exactly format
`wotex-home.composed-mapping@1`, scope composed_mapping_claims_only,
source_sha256, runtime_sha256, mapping_sha256, bindings (the origin array) and
program (the complete generic Program). It contains no bearer, endpoint, PID,
private capture, principal grant, clock sample or current authorization token.
Full input and output must fit the composed aggregate bounds, with every copy
charged. A generic Program's ir_digest is not the source bundle or mapping hash.

`WotexHome.Rules.ComposedMapping.validate/3` takes bundle, independently supplied
environment and projection; rebuilds the entire result; and returns :ok only
on exact equality, otherwise {:error, invalid_composed_projection}. Construction
refusals remain their named errors below. Comparing only hashes or selected
effect leaves is insufficient, even when a forged Program is rehashed.

## Current fact obligations inherited by the collector

**RCM-07 — Preserve original evidence.** Pure mapping builds no Fact. A future
Store collector must authenticate the complete original-author/current-actor
scope before private reads, then recheck current source, qualification, runtime,
declaration/resource and installed input histories at closing and final use.
The existing 32-pair requested collector and legacy FactReadModel receipts do
not certify global active membership; chunking them cannot create such a receipt.

For external data consume the actual current qualified collector result and
original reader/Mapping witnesses. Preserve receipt_epoch, receipt_ms and the
earliest owner/consumer/Basis expiry; use the original floor-millisecond clock
without processing-time renewal. Missing/stale/replayed/retained/wrong-source
data remains unknown or baseline as its owner specifies. Source time requiring
trust still requires the current qualified complete UTC interval. Receipt UTC
stays null where no original UTC witness exists.

Native snapshot facts require the exact immutable journal/current-row join,
current profile/declaration, production quality and original Store receipt
epoch/coordinate, distinct from an adapter's reported receipt timestamp.
Expiry is original Store receipt plus capability freshness, checked for overflow;
only receipt_ms <= now_ms < expires_ms is usable. This is deliberately exclusive
at the upper bound, as WRO Facts require. It does not change legacy previews'
inclusive boundary. Missing timing, old boot, future receipt, synthetic_lab,
unknown quality or lost qualification cannot become a usable scalar.
Convert the native value only by RCM-02, preserving Boolean/enum text and exact
integer units. A malformed retained/journal link remains corruption, not unknown.
For the same physical observation and installed Thing/affordance/operation,
reuse one complete Fact and binding basis across aliases/programs; neither Fact
IDs nor metadata may depend on an alias, program or evaluation arrival order.

Before no-send satisfaction, the Store must also apply the current whole-Thing
effect-domain exclusion: a queued, claimed, dispatching, protocol-accepted or
unknown execution can still invalidate the apparent match. A matching snapshot
does not settle or remove that other execution. The step's own unsent held
reservation may remain charged, but a report alone does not cancel a queued
intent, skip a handoff marker or bypass an override/current authorization guard.
The journal contract must define the atomic satisfied transition and its allowed
predecessor states; this mapping supplies no synthetic handoff/ACK receipt.

Native records provide no qualified source UTC age, receipt UTC, replay or
reconnect-continuity witness for the new executable profile. Do not invent them.
Such snapshots may serve current-state predicates, waits and qualified absolute
reported-match satisfaction; they cannot establish a reported edge. The complete
native Fact metadata/encoding and its current collector guards must be frozen
in the active-set contract before live collection is implemented. A codec's
success alone cannot qualify a current-state satisfaction receipt.

## Failure, retry and recovery

**RCM-08 — Fail without substitution.** build/2 returns only {:ok, projection}
or {:error, code}, with no payload, private source text or producer exception.
Errors are invalid_composed_mapping (shape/native/canonical failure),
composed_mapping_limit (byte/depth/node/count/integer bound),
unsupported_composed_mapping (unsupported type/operation/edge/contract),
composed_mapping_basis_changed (selector versus supplied declaration/input
identity mismatch), composed_registry_conflict (unequal same-id closure), and
composed_mapping_unavailable (missing public producer or required native API).
Apply byte/depth/node admission bounds before materializing documents, then
closed shape and native reconstruction, selector identity comparison, closure
merge and generic compilation in that order. Compare selectors in alias order;
equal records do not make an unequal same-id record acceptable. For mixed
failures, return the first failure in this sequence, without an error payload.

Producer limit_or_json_error, integer_overflow, node_bound, predicate_bound,
parallel_bound, invocation_bound, effect_bound, wait_bound, duration_bound,
path_bound, definition_bound and expansion_bound map to composed_mapping_limit.
A well-bounded malformed generic shape, missing child/binding/parameter,
recursive invocation or inconsistent claimed digest maps to
invalid_composed_mapping. A well-shaped unsupported construct, incompatible
type/unit/operation or out-of-domain typed argument maps to
unsupported_composed_mapping. Missing producer APIs map to
composed_mapping_unavailable. Unexpected exceptions or unrecognized producer
refusals map to invalid_composed_mapping, without exposing their text.
No partial result or legacy fallback follows. validate/3 adds invalid_composed_projection.

No state exists in these helpers to cancel, recover or refund. Equal complete
inputs produce the same result. A lost pure reply can be recalculated; this is
not replay of a durable operation. Changed input installation, source epoch,
receipt-clock incarnation, declaration, resource or complete runtime needs a
fresh measured environment and correspondence before live use. Do not rewrite
old Program/source/receipt bytes to make a retained run current after restart.

Historical parsing, cancelled work, source replacement, transfer, backup and
quarantine stay with the owning journal/recovery contract. Producer absence may
block fresh construction but must not prevent that contract's producer-independent
original/history reads. Restored Definitions do not install mappings or qualify
sources. No physical effect, implicit stop or compensation follows a refusal.

## Acceptance and review traces

A normal planned trace is: review an exact external integer-temperature input;
select its installation and two native Boolean outputs by whole declaration
hash; derive the public context and Program; then obtain separate composed
admission and a complete current Store snapshot. This helper ends at the inert
Program. A planned adverse trace replaces that external installation after
preparation while keeping its legacy Basis equal. Full Definition/origin and
mapping/compiler identities still differ; the old projection refuses and no
held/root/queue record is created. These traces are requirements, not evidence.

Before implementation, freeze closed bundle/environment/projection schemas,
canonical hash/Unit/Basis vectors and full source fixtures. The independent
oracle must generate raw document/hash/ppm/Kelvin expectations without calling
Home or producer construction/digest helpers. Native Store acceptance later
must measure the real environment instead of supplying its own claimed fixture
as current evidence.

| Case | Requirements | Setup and expected observation / falsifier | Evidence level |
| --- | --- | --- | --- |
| RCM-T1 | 01–02 | Every supported scalar/read/write tuple, zero-binding noop and actual existing Thing/Definition round-trip; missing/extra/unsorted/duplicate aliases, 33 selectors and malformed native values refuse without a partial result | Pure native/schema |
| RCM-T2 | 02–04 | Independent full Boolean/ppm/Kelvin/enum Basis/contract/hash vectors agree byte-for-byte; 1 ppm stays integer 1, Kelvin endpoints remain exact, 0/1000000 ppm succeed and out-of-domain/float/wrong-unit inputs refuse | Independent pure |
| RCM-T3 | 01, 04–06 | Same Home ID maps injectively to the existing IRI; whole Thing changes, read/write alias differences, unused child and actual arguments alter the right full identities. Different root durations retain one installed native Basis and collect coherently on the same property with distinct inherited deadlines | Pure native/Collection |
| RCM-T4 | 02, 05–07 | Real reviewed external integer/Boolean/enum Definitions preserve the complete installed Mapping and external profile/clock witnesses; equal legacy Basis with changed Definition/install generation refuses old projection | Pure/native Store |
| RCM-T5 | 03–06 | Merge equal Registry/Basis records once; same id with changed revision/digest/requires or unreachable cycle refuses; reversing external source arrival cannot select a winner or rewrite a signed Mapping | Pure native |
| RCM-T6 | 02, 06–07 | Action/external writes, sensitive writes, native edge, HSV/XY coercion and unsupported external quantity refuse; qualified external continuous edge retains exact source/epoch/baseline semantics | Pure plus collector software |
| RCM-T7 | 06, 08 | Change/re-hash every projection, origin, compiler/mapping/runtime field and nested Program; full regeneration detects each mismatch. Missing actual public producer refuses; no fallback evaluates | Pure/native mutation |
| RCM-T8 | 01, 06–08 | Exact and one-over source/aggregate byte/depth/node limits count all embedded document copies; unchanged smaller legacy rule/input formats remain unchanged; no socket body grows | Pure/native boundary |
| RCM-T9 | 01–02, 07 | Actual Store races author/actor/input/output grant, declaration/profile/source/runtime and installation changes between preparation, commit and final use; zero stale reservations/sends. An unused child target also requires authority | Actual SQLite/controlled transport |
| RCM-T10 | 07–08 | Receipt at expiry is unknown, original pre-expiry report can satisfy only under current qualified guards, stale/old-boot/reconnected native samples create no edge, restore/producer-absent history creates no installation or send | Independent fact/Store software |

These obligations contribute to H20-T2/T3/T4/T8; they do not complete the parent
cases or qualify hardware. Record exact source, lock, runtime, fixtures, commands
and results for each executed scope. Physical/sleep/installed-clock evidence
and per-cohort scalar write/readback qualification remain separately required.

The 2026-10-16 specification review executed a disposable public-API feasibility
probe through `mise exec -- mix pkg wotex-routines run --no-start` at WoTEx
973fb32c (its pinned Elixir 1.20.2/OTP 29.0.4 lane). For each of power true,
brightness 1 ppm and colour_temperature 6500 K within 1500–9000 K, it built the
RCM-03/04 contract/Basis templates, compiled two manual members with durations
1000/2000 ms, and called public Collection@2 regeneration and Arbitration.
All three cases retained two proposals, run and step deadlines 1000/2000,
one compatible group and both original contributors. This confirms only that
the generic public seam can represent the corrected stable-Basis design;
it did not construct the Home bundle/environment wrapper, measure an installed
runtime, run a Store or test the planned Home implementation. The disposable
probe source hash was 6152983d734bd8f4a74d3099496279dd2a56e0d621495069dc5f562bffbb435a;
its temporary script was removed. It is not retained acceptance evidence and
does not discharge RCM-T3 or replace the reproducible entry fixtures above.

## Sources and decisions

Source reconciliation used Home `07823e44`: Semantics.Capability/Value/Thing/
ReadCapability, Durable.Registry, Rules.KernelMapping/ExternalInput/ExternalFact,
Durable.Store.Access/FactReadModel/ExternalInputCollection/ExecutionWriter; and
WoTEx `973fb32c`: public Unit/Basis/Compiler/InputMapping/Input/Collection APIs.
No cached dependency file was edited and no vendor wire behavior is inferred.
Thirty-two selectors bound the whole immutable closure, matching the existing
single requested scope's size without misrepresenting that scope as a global
snapshot. Scalar construction deliberately remains distinct from execution
qualification. Missing native continuity is an explicit producer-of-evidence
obligation, not permission to label a fresh DB read a fresh physical edge.
