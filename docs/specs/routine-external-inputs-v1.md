# Reviewed external routine inputs and current collection

Version: 0.1.14. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.20 H20-01/04/06, H20-T1/T3/T6/T8; WOH.18 H18-04/05/08;
WOH.11 H11-01/05. Implementation: partial, fresh runtime, pure Definition,
signed-review verifier, retained codecs, schema-38 history/migration/recovery and
measured native review context, computed retirement reserve and atomic durable
withdrawal. Evidence:
entry, native correspondence, historical package/original/graph checks and software trust-mechanics
checks pass. SQLite installation, current collection, EI-T1–T9 integration and
physical obligations remain open.

## Result and ownership

Home installs one exact reviewed external input definition per target/capability
slot and collects a bounded requested set under one current Store basis. An
installed definition binds the actual read declaration, source incarnation,
reader/semantic/unit correspondence, runtime and Store-owned receipt clock.
A later actual report can reach WRO Snapshot/Evaluation without relabeling Home's
converted value as the original reader coordinate. Unknown remains unknown.

This contract owns native Authority/Store context, install/revoke/status and
current collection, signed qualification of the input correspondence, immutable
operation/history encoding and its recovery domain. It does not broaden the
legacy FactReadModel, Capability or Value. It creates no rule admission, run,
step, causal root or command. Collection of a requested fact scope does not
prove collection of the complete active program set. Whole-set arbitration,
composed persistence/admission and client presentation retain their own owners.
No existing effect profile or default-disabled physical dispatch is widened.

Dependencies already implemented in the selected Home/WoTEx cohort:

| Owner | Required behavior |
| --- | --- |
| External target selection | Exact current Thing/resource, selection/binding/trust/policy revisions, active selector and approver, checked native source and actor-owned immutable profile closure |
| External observations | Immutable original report/value/SHA and current target/channel pointer, original Store receipt coordinate, retained sequence history and explicit post-boot selection |
| Consumed report lifetime | Store-only original owner/report/SHA/source clock pair, unchanged exclusive deadline and live same-source checks after consumption |
| ExternalFact and WRO.05 | Actual original WPF reinterpretation, exact installed Mapping, complete external binding, null receipt UTC, signed floor clock and bounded Fact conversion |
| Qualification.Evidence/Attestation/Artifacts | Closed exact cohort/case claims, Ed25519 case signatures and private artifact integrity; none alone grants qualification |
| RuntimeArtifacts/ProducerIdentity | Complete compiled application inventories with loaded-code correspondence; actual current native profile assertions, not historical archive placeholders |

The owning contracts are [target selection](external-target-selections-v1.md),
[observations](external-observations-v1.md),
[lifetime](external-report-lifetime-v1.md),
[projection](routine-external-facts-v1.md),
[qualification](WOH.11-hardware-qualification.md) and
[durable execution](WOH.14-durable-execution.md).
Generic reader/Mapping algorithms remain in WoTEx. Household qualification,
authors, grants, clocks and SQLite remain in Home. No new producer API is an
unexplained prerequisite; the selected public APIs are present.

## Native use cases and authority

All inputs below are closed plain objects/lists, without native structs, unknown
members or defaults. IDs are Home's existing 1–128 ASCII-byte IDs; epochs,
revisions and generations use their existing positive/nonnegative signed-64
bounds. Hex digests are unprefixed lowercase SHA-256 unless a producer reference
explicitly requires its sha256: prefix. No raw capture, endpoint, bearer or
physical hardware identifier is returned in an input context or collection.

Authority exposes these native methods; Store implements their guarded calls:

| Method | Input and result |
| --- | --- |
| external_routine_input_context(authority, bearer, target_id, capability_key) | Current exact review context described below; no retained lease or operation |
| change_external_routine_input(authority, bearer, input) | Install or revoke with scoped original; returns immutable receipt |
| external_routine_input_status(authority, bearer, authority_epoch, operation_id) | This actor's original immutable receipt; no producer/custody/current qualification needed |
| external_routine_facts(authority, bearer, scope) | One complete requested current input snapshot, including explicit unavailable/unknown items; no effect token |

Context/install/revoke/status require current qualify:profile, rule:review and
read permissions and an explicit whole-Thing grant. Current collection requires
rule:review and read plus grants for every requested target. Authenticate the
whole scope before reading any slot; an unauthorized member refuses the entire
call without a partial response. A signer key is not an operator bearer. No
permission, target grant or declaration changes as a side effect of installation.
The original selector must still have profile:manage and enroll:review, and the
original trust approver must still have profile:manage. Each must independently
retain an explicit grant for this target. These author checks precede private
custody/source reads; caller permissions cannot substitute for either author.
There is no new socket/CLI/model body accepting reports or clocks; native client
adapters require a separately specified closed framing extension.

New changes require an active writable controller, expected authority epoch and
no maintenance barrier. Context/current collection refuse store_unavailable for
an unhealthy writer and maintenance_active during maintenance. Original status
and exact original recovery remain independent of fresh producer availability,
provided the actor still has the permissions and target grant above.

## Exact review context and runtime

Context is a plain object with exactly these members, all required:

format, authority_epoch, store_boot_epoch, target_id, capability_key,
selection_revision, resource_revision, binding_revision, trust_revision,
policy_generation, selection_author, trust_author, source_owner_epoch,
source_selection_sha256, source_ref, source_epoch, source_generation,
source_method, source_trust, stable_id_sha256, report_owner_epoch, reader_limits,
declaration, reader, receipt_clock, runtime and runtime_sha256.

format is wotex-home.external-input-context@1. All selection/binding/trust/source
generations are positive; resource/policy counters are nonnegative. Store boot is
the current Home ID, source/report-owner/source epochs are hex32. Source method/
trust and stable_id_sha256 are the exact checked safe source summary, never the
raw stable ID. synthetic_lab sources refuse unsupported_external_input even
with signed claims; a synthetic physical case is never a source qualification.
declaration is the complete parsed retained read-declaration data
for this target/key. Its channel/consumer/semantic, unit, constraints, risk,
producer and freshness stay exact; its underlying retained record and full Thing
must match the current selected target. Context uses no global Store revision
as a long-lived CAS: unrelated arriving reports must not invalidate a physical
review. The mutable target/source/trust/policy/runtime counters below still bind it.

reader is exactly profile_sha256, closure_sha256, capture_digest, compiler_ref,
reader_contract_ref, channel_id, affordance, semantic_ref, external_unit and
value_schema. Derive it from the actual rebuilt ExternalEnvelope projection's
selected supported channel and its definition; reader_contract_ref comes from
public Wotex.Profiles.Proposal.identity/0. Do not use a caller-authored projection.
Require the actual current native ProducerIdentity assertion, matching the
rebuilt reader/declaration. Legacy three-archive assertions remain historical
compatibility data and cannot seed this current input context.

Context preparation has a 10000 ms overall monotonic budget. Before each
five-second source, report-owner or custody call, require at least 5000 ms
remaining; exhaustion or owner failure refuses external_input_unavailable.
Read verified immutable objects without allocating a retained lease. Capture the
complete authenticated DB/source/custody/declaration/runtime basis, rebuild it
again before returning, and require exact equality. Repeat the source and
report-owner identities after private reads and freshly check all runtime groups
at closing. Changed opening/closing evidence refuses external_input_basis_changed;
absence on the opening pass refuses external_input_unavailable. Named corruption
and SQL failures retain their owning write-fencing behavior. No partial context
or asynchronous continuation is returned. Context creates no durable operation,
lease, revision, input installation or physical qualification.

receipt_clock is exactly the WRO six-member receipt-clock@1 floor_millisecond
alternative. Its source_epoch is the configured live report owner's epoch;
source_origin_us is canonical signed-64 decimal 1000 * Store.clock_origin;
target_epoch is Store.clock_epoch and target_origin_ms is 0. It is stable within
that Store/report-owner incarnation. Refuse overflow or absent owners; never
infer a clock pair from two processing-time samples. The report owner itself
supplies no grant or physical qualification.
Signed origin multiplication overflow refuses external_input_limit.

The new external-input runtime identity combines four bounded inventory groups.
Every group hashes actual complete app versions/module inventories through
RuntimeArtifacts; no hand-picked module list or loaded-code fallback is allowed:

| Group | Exact applications and digest domain |
| --- | --- |
| routines | RuntimeArtifacts.temporal_applications/0, its ten current applications; wotex-home.external-input-runtime:routines@1 |
| profiles | Actual ProducerIdentity.current/0, including current core/Runtime/Profiles BEAM inventories and source revision |
| transport | wotex_binding_mqtt, emqtt, gun, cowlib, wotex_udp; wotex-home.external-input-runtime:transport@1 |
| storage | exqlite, db_connection, telemetry; wotex-home.external-input-runtime:storage@1 |

Runtime data has exactly format wotex-home.external-input-runtime@1,
routines_sha256, profiles, transport_sha256 and storage_sha256. runtime_sha256
is SHA-256 of that format, newline and compact UTF-8 JSON of the ordered array
[routines_sha256, ProducerIdentity.values(profiles), transport_sha256,
storage_sha256]. Native current profile shape is mandatory. Capture each group
fresh, including closing checks; an enclosing Store inventory memo cannot supply
a new closing proof. Each group fits the existing eleven-application ceiling.
The conservative transport group is retained even for another admitted native
publisher. Narrowing it later needs independent correspondence evidence.

This binds BEAM behavior and versions, not ERTS, OS, SQLite NIF or physical
transport/device behavior. Those retain the signed exact cohort's runtime,
native_stack, firmware, host and topology obligations. Missing/changed app bytes,
version, module list or producer refuses runtime_artifact_unavailable; do not
reuse an old runtime identity to keep qualification current.

Rules.ExternalInputRuntime.current/0 returns {:ok, runtime, runtime_sha256} or
{:error, :runtime_artifact_unavailable}. Its profiles group obtains the actual
native ProducerIdentity.current/0 and independently compares fresh_digest/2 for
each of core/Runtime/Profiles under that assertion's existing digest domain.
Thus even its core subset cannot reuse an enclosing Store's opening inventory.
digest(runtime) is a pure closed-shape/native-assertion check returning
{:ok, runtime_sha256}; it never measures installed code. check_current(runtime,
runtime_sha256) freshly captures all four groups and requires exact equality,
returning :ok or {:error, :runtime_artifact_unavailable}. Malformed, historical
archive or mismatched input uses that same payload-free refusal.

## Input definition and representation

Rules.ExternalInput.new(context, mapping, registry) is the pure reviewed-data
constructor. It validates the supplied context shape/correspondence and uses
public Registry, InputMapping and Input.binding_basis APIs. It does not measure
current runtime or consult a Store; Store independently rebuilds the context.
The exact native value has data, document and sha256 fields. Reconstruct all
fields on reuse; extra native fields or a forged digest refuse.

Its exported data is exactly format wotex-home.external-input-definition@1,
context, mapping, registry and limits. Mapping and Registry are complete plain
producer values. Limits are fixed and fully present: max_bytes 262144,
max_depth 16, max_nodes 20000, max_string_bytes 8192, max_collection_size 128,
max_integer 9223372036854775807. They deliberately narrow the inert constructor's
ceilings. The entire definition and every embedded occurrence are charged;
no truncation, hidden defaults or runtime limit enlargement is allowed. Producer
max_integer applies to Mapping/Registry arithmetic; Home context counters and
retained declaration constraints keep their owning full signed-64 grammar. The
whole wrapper obeys the stated byte/depth/node/string/collection bounds.

Require Mapping profile/closure/capture/compiler/Proposal/semantic/channel/
affordance/external-unit coordinates to match reader exactly; its source_ref,
source_epoch and source_class match the context and device_report. Its complete
receipt_clock equals the Store-derived context clock. Its Basis is read-only:
readproperty/observeproperty for a property or subscribeevent for an event,
output null; effects exactly resource_roles [], repeat never, stop unsupported,
supersession block_until_known, partial_possible false and unknown_possible true;
timing duration_ms/dwell_ms/cooldown_ms 0, positive deadline_ms at most 86400000
and uncertainty block; analysis exactly unsupported/null/[]; evidence.sources
exactly [device_report], completion correlated_report. Its implementation_digest
and compiler_digest equal sha256: plus context.runtime_sha256. Its byte_digest
is sha256: plus the public canonical JSON hash of the complete Basis body after
dropping its four digest members; public Basis.semantic_digest/2 owns the separate
semantic projection and validation. These choices describe a read and cannot
assert an effect completion. Select only semantics accepted by the current public
WRO constructor; a syntactically valid external unit is not conversion evidence.
The reader and declaration must have identical channel, semantic and value_schema;
the declaration target/key and native producer must match the context. An integer
declaration has ordered signed-64 constraints and the reader unit's exact quantity
kind/dimension, while retaining its separate Home scale/offset. A Boolean
declaration has a Boolean reader schema, null unit and null constraints; external
declarations retain the reader's exact unit and null constraints. Mapping projection
exact_integer requires reader schema type integer or number; boolean requires boolean;
enum requires string and its table's unique source codes to cover the reader's
explicit nonempty enum exactly. Unsupported reader schemas refuse qualification
rather than relying on a later observation to discover a type mismatch.
Basis freshness must not exceed the Home declaration freshness. Source-time and
continuity requirements remain explicit reviewed Basis policy. Sensitive inputs
remain read-only and cannot qualify a sensitive effect through this definition.

The exact Mapping, complete Basis and correspondence records must be present in
Registry. Registry identity aliases, mismatched versions/digests or missing
requires refuse. No example/reference fixture or ambient registry supplies an
installed meaning. Definitions with unfamiliar supported quantities use this
same data path; unsupported reader/routine quantities remain readable outside
routines and cannot become zero/false or a no-op.

Historical definition_document uses the array-only AuthoringWire grammar:
["wotex-home.external-input-definition.v1", context_chunks, mapping_chunks,
registry_chunks, limits_array]. Each inner document is the exact public canonical
JSON generated at construction, at most 131072 bytes, strict duplicate-free and
depth at most 16. DocumentChunks uses maximal UTF-8 chunks at most 4096 bytes.
limits_array follows max_bytes, max_depth, max_nodes, max_string_bytes,
max_collection_size, max_integer order. The whole ordered wire is at most 262144
bytes; its sha256 hashes format wotex-home.external-input-definition@1, newline
and those exact bytes. Historical decoding preserves inner bytes and verifies
closed Home shape, bounds, scope, hashes and canonical outer encoding without
calling a producer. It does not claim to rerun opaque producer algebra or prove
current installation. Hash verification here covers Home's own Definition/wire
identity and runtime claim; producer digest members remain opaque historical
claims until native reconstruction. Current native reuse regenerates the producer values and
requires exact correspondence with its original document and current context.

The constructor returns {:ok, %Rules.ExternalInput{data: data, document:
document, sha256: sha256}} or a named {:error, code}. to_map(value,
current_context) reconstructs the exact native value, requires exact equality
with the supplied current context and returns {:ok, data}; Store owns measuring
that context. encode(value) performs the same native reconstruction against its
own claimed context and returns {:ok, document}, without claiming current use.
decode(document) is producer-independent and returns {:ok, historical} with
exactly the plain string keys data, document and sha256; this plain object is
not a native constructor result. It cannot be passed off as an installed token.

## Signed external-input qualification

A programme in priv/qualification/external-routine-input-v1.json fixes eight
required case IDs, requirements, environments and the generic external_input
capability key. The actual target/key/Mapping are bound by the separate decision;
this programme key is a purpose label, not a new global sensor enumeration.

| Case ID | Requirement/environment | Required independent obligation |
| --- | --- | --- |
| ERI-identity | H11-01 / hardware | Exact physical unit, firmware, host binding, channel and source correlation; another device cannot supply this input |
| ERI-conversion | H20-01 / hardware | Independent raw/reader/Home/routine coordinates, quantity-kind, sign, unit, range and enum/Boolean interpretation |
| ERI-invalid | H20-04 / integration | Sentinel/invalid/unknown reports never become zero/false or a usable value |
| ERI-clock | H20-04 / integration | Original signed receipt, conservative precision, UTC trust/uncertainty and exclusive freshness/lifetime; no processing-time renewal |
| ERI-continuity | H20-04 / integration | First/gap/retained/replayed/null/duplicate/out-of-order and counter-reset behavior; no invented edge |
| ERI-reconnect | H18-08 / hardware | Actual source/host/device interruption and explicit replacement; old incarnation cannot become current |
| ERI-revocation | H20-06 / integration | Grant/author/trust/policy/declaration withdrawal prevents current known use without a mutating device call |
| ERI-offline | H18-05 / hardware | Qualified local read without vendor cloud/public DNS, preserving the independent device safety behavior |

Every case uses existing Evidence and Attestation grammar, exact cohort, matching
passed assertions, no exclusions/blockers, command-sequence/artifact references
and pinned case-reviewer signatures. The physical reviewer must check cited
private artifacts with Artifacts.verify/2 and inspect their physical provenance
and outcomes before signing; the writer never hashes up to a GiB of raw captures
inside SQLite. Code cannot infer that physical inspection from syntax/signatures.
A fixture signature exercises software trust mechanics and does not qualify hardware.

Qualification.ExternalInputDecision consumes exactly signed, definition,
cohort and attestations. signed has decision and signature. The closed decision
has format wotex-home.external-input-decision@1, outcome allow_external_input,
definition_sha256, programme_sha256, cohort_sha256, evidence_set_sha256 and
reviewer_key_id. Signature is canonical unpadded URL-safe base64 Ed25519 (86
characters). Signing payload is ASCII WOH11-external-input-decision-v1, NUL and
deterministic Erlang encoding of that exact decision map. Case signatures retain
their existing separate domain. Cohort digest uses Evidence.cohort_digest/1;
evidence-set digest uses the deterministic Erlang encoding of attestations sorted
by case_id, SHA-256. Reject duplicates, missing/extra cases, wrong environments,
changed cohort/digests, unknown keys and signatures with altered content.

Use the Store's existing qualification_case_keys and qualification_decision_keys,
each at most 32 pinned key IDs/public keys. Require distinct decision/case reviewer
IDs AND distinct public-key bytes, not two aliases for the same signer. Empty
keys return qualification_unavailable. The decision binds the exact current
Definition; a LIFX decision or general profile approval cannot fill it.
Store installation must rebuild the context, verify every signature and compare
the complete Definition before committing. Runtime, Store/report/source boot,
selection/resource/trust/policy or semantic drift requires a fresh explicit
review decision. Reusing still-applicable signed case artifacts is an accountable
reviewer decision, never an automatic requalification by hash replacement.

ExternalInputDecision.programme/0 returns {:ok, cases, programme_sha256} from
the exact shipped programme bytes or {:error, :qualification_unavailable}.
Read at most 16385 bytes and refuse any programme over 16384 bytes or with a
different pinned SHA-256, even when its parsed case meanings look equivalent.
signing_payload(decision) returns {:ok, payload} after closed-shape validation.
verify(signed, definition, cohort, attestations, case_keys, decision_keys)
reconstructs the native Definition, validates the exact case set and returns
{:ok, decision}. It does not sample a current Store or inspect raw artifacts;
Store must first compare the Definition with its independently rebuilt context.
Malformed claims, key aliases or signature/correspondence failures return
{:error, :invalid_external_input_decision}; empty trusted key maps or an absent
programme return {:error, :qualification_unavailable}. The verifier does not
produce a mutable qualification flag or automatically install its result.

The reviewed package map is exactly format
wotex-home.external-input-package@1, definition_document, signed, cohort and
attestations. definition_document is the exact Definition wire above; every
other value has the closed grammar just described. It retains exactly eight
attestations sorted by case_id. Its package_document wire is
["wotex-home.external-input-package.v1", definition_chunks, signed_chunks,
cohort_chunks, attestations_chunks]. The last three inner documents are public
canonical JSON of the closed signed map, cohort map and attestation list;
each is at most 65536 bytes and uses the same maximal DocumentChunks encoding.
The complete package is at most 262144 bytes including all escaped/chunked
occurrences. Its sha256 is the unprefixed SHA-256 of its format, newline and exact
package wire. Historical decoding validates all closed Home/Evidence/Attestation
shapes, Definition identity, decision/package scope and exact canonical outer
wire/hash correspondence; it does not verify a current signature without the
host-pinned keys or reinterpret producer data. Live verification revalidates the
complete native Definition and all signatures against those actual keys.

Rules.ExternalInputPackage.encode(package) validates historical correspondence
and preserves the exact Definition wire while generating the other three inner
documents through the public JSON producer, returning {:ok, package_document}.
It checks representations, not current
keys or source authority. decode(package_document) calls no producer, current
programme file or reviewer key and returns {:ok, historical} with exactly plain
string keys data, document and sha256. The immutable v1 case definitions and
programme SHA are compiled historical data; current programme/0 still rereads the
actual shipped file for live verification. Historical validation requires the
exact sorted eight passed cases/cohort, canonical signature representations,
decision/Definition/programme/cohort/evidence-set identities and distinct reviewer
IDs. Signature trust and distinct public-key bytes require live verification.

verify(package_document, current_context, case_keys, decision_keys) decodes the
whole historical package, compares its full claimed context, reconstructs the
native Definition and requires its exact original document and a byte-identical
current canonical package encoding, then calls the
separate decision verifier. Success returns the same historical metadata; Store
still owns measuring current_context and installing any result. Named refusals
are the existing closed external-input errors plus invalid_external_input_decision
and qualification_unavailable. Context mismatch is external_input_basis_changed.
Encoding/decoding retained input/outcome/receipt history never calls this live
verifier, samples a runtime or requires a current producer/key/source.

The sanitized complete package is retained in this domain's bounded SQLite
history; raw captures and private keys are not. This differs from the LIFX
write-qualification claim file and does not change that format or custody owner.
The package alone cannot restore live authority: current keys, source/Store boot,
bytes and context are independently required, and restore remains quarantined.

## Scoped operations, schema and invalidation

Change input has exactly authority_epoch, operation_id, target_id, capability_key,
expected_install_revision, expected_generation, action and package_document.
action is install or revoke. Install has the complete sanitized reviewed package;
revoke has null package_document. Expected slot counters are nonnegative signed-64;
a missing slot starts at 0/0. Revoke requires an installed slot. Original namespace
is current principal/authority epoch/operation ID. A different install revision
refuses stale_external_input_revision; a different generation refuses
stale_external_input_generation. Check revision before generation. Return an exact
original after current actor/scope authentication and before
fresh signature, source, producer, clock or capacity work; changed input under
that original is external_input_conflict. There is no automatic eviction/refund.

Before implementation freeze input/package/outcome/receipt codecs and schema 38,
with actual schema 37 as predecessor. Add exactly these tables:

| Table | Columns in declaration order |
| --- | --- |
| routine_external_input_operations | principal_id, authority_epoch, operation_id, input_document, outcome_document, receipt_document, revision |
| routine_external_input_history | target_id, capability_key, revision, generation, action, cause_revision, outcome_document |
| routine_external_input_current | target_id, capability_key, history_revision, install_revision, generation, state |

Operations PK is principal/epoch/operation; revision is unique authority-journal
FK. History revision is PK/journal FK; generation is unique per slot. Current PK
is target/key, with journal/history FKs and one shared enrolled Thing target.
state is installed or revoked. Install sets install_revision to its own operation
revision; revoke/withdraw retains the last installation revision as history.
Actions are install/revoke/withdraw. User operations have null cause_revision;
withdraw records the positive revision of the owning target/trust/author cause.
Each history row has its own external_input_installed, external_input_revoked or
external_input_withdrawn journal event with target entity ID, even when several
slots retire in one enclosing transaction. No prior receipt is rewritten.

All three tables use SQLite's ordinary rowid representation. All columns are
NOT NULL except history cause_revision. Identity, action, state and document
columns have TEXT affinity; counters/revisions have INTEGER affinity. Operations
principal_id references principals(principal_id). History target_id and current
target_id each reference enrolled_things(thing_id). History additionally has
UNIQUE(target_id, capability_key, revision), so both current foreign keys are
scoped to that exact slot: (target_id, capability_key, history_revision) and
(target_id, capability_key, install_revision) reference that history triple.
History cause_revision references authority_journal(revision). No cascading
deletion, explicit index, trigger, view or alternate head is added.

SQL CHECK constraints require integer-typed positive authority epochs,
generations and revisions; current install_revision <= history_revision; and
positive cause_revision < revision only for withdraw. For install/revoke,
cause_revision is null. Actions/states have the closed enums above. Installed
current rows require history_revision = install_revision; revoked current rows
require history_revision > install_revision. Documents are nonempty text and
their UTF-8 byte ceilings are input/outcome 524288 and receipt 4096. Home ID
grammar, exact signed-64 bounds and canonical document contents are repeated by
semantic validation rather than inferred from SQLite affinity. Retained table
DDL is fixed by this migration; whitespace normalization is permitted, semantic
DDL changes, missing autoindexes and additional domain indexes/triggers refuse
even when all three tables are empty.

Integrity walks history by ascending revision, independently for each target/key.
The first row is install at generation 1; every subsequent generation is exactly
the preceding generation plus one. Install/revoke rows correspond one-to-one to
their scoped operations and exact outcome bytes. Receipt revision/generation and
input expected_install_revision/expected_generation agree with the preceding
slot (0/0 only when missing). Revoke and withdraw require an installed predecessor
and preserve its exact package and Definition SHA, changing only outcome action.
Install replaces the installation revision with its own; every other transition
retains the preceding installation revision. The current relation is exactly the
latest history row for every slot, with no missing or additional head. Every
operation has an existing principal and an epoch no later than meta's authority
epoch; every history row is at or before meta's revision. The complete set of
external-input journal events equals the complete history relation.

A withdrawal has no user operation and cites the first applicable durable loss
after its installed predecessor, before its own history revision. Applicable
causes are target selection/replacement/revocation or enrollment loss for that
target; external profile approval/revocation advancing the globally bound policy;
revocation of the installer, selector or approver; removal of any such author's
whole-Thing grant; or controller source retirement/destination acceptance.
Beginning host maintenance is also a durable loss: retire installed slots in
that same transaction using host_maintenance_started as their cause. Ending
maintenance requires an explicit fresh input review/install to restore use.
This retirement occurs before any later controller-retirement operation, whose
existing receipt remains expected_revision + 1 and the final retired Store
revision. Input withdrawal must never append revisions after that retirement
receipt or alter its historical identity. Original maintenance receipts and
barrier revision remain immutable; status reports the resulting global revision.
Native target-grant revocation resolves its principal/target through its retained
native operation rather than parsing a concatenated journal entity. An installed
head or later explicit user change cannot skip an earlier applicable loss.
Regranting an author never removes that loss. Transient source/producer/runtime
absence has no invented journal cause; current use must still refuse it.

The internal ExternalInputs collaborator exposes schema/0 and tables/0 for the
single schema/recovery owners, validate/1 for this complete retained graph and
capacity/5 with nonnegative prospective operation/history/slot/byte increments.
validate_if_current/1 checks schema 38, skips the absent domain for schemas 4–37
and refuses an unreadable or unsupported schema. Store repeats it before and
after every transaction; corruption rolls back and fences further writes.
It borrows Store's handle and opens no transaction or connection. Validation
normalizes malformed domain data to corrupt_external_inputs; prospective
capacity returns external_input_capacity and propagates actual SQL errors.
These historical primitives do not authenticate a caller or install a package.

The same collaborator's retirement_reserve(db, excluded_slot) returns
{:ok, %{history_rows: count, bytes: count}} for the exact prospective withdrawal
footprint of currently installed heads. excluded_slot is null (Elixir nil) or one
valid {target_id, capability_key} tuple that a new user change will replace.
Each included head charges one history row and the UTF-8 byte size of its exact
retained outcome re-encoded with action withdraw. No user operation or receipt is
reserved. Invalid exclusion is invalid_external_input; malformed retained heads
are corrupt_external_inputs; SQL failures propagate. This computed read retains
no reservation row, lease or authority, and does not require live producers.

withdraw_invalidated(db) runs only inside the owning Store transaction after its
durable mutations and schedule invalidation, before final history validation and
COMMIT. Schema 38 examines installed heads in lexical target/key order and finds
each first applicable retained loss through the current global revision. For
each affected slot, append one withdrawal journal/history row, increment its
generation, retain its last install_revision and exact package, and mark its head
revoked. Allocate new global revisions in that lexical order; immutable cause
receipts keep their original revisions. No affected head is omitted and no user
operation is created. Schemas 4–37 are unchanged; unsupported/unreadable versions
refuse corrupt_external_inputs. With no applicable loss it writes nothing.
Unrelated loss events and transient owner/runtime absence create no withdrawal.
Quota or counter exhaustion refuses external_input_capacity or revision_exhausted
and rolls back the entire owning change as a policy denial. Any withdrawal SQL
or graph failure rolls back the cause and all affected withdrawals and fences
the writer. A later retry cannot retain half of a retirement batch.

Outcome has exactly format wotex-home.external-input-result@1, action, target_id,
capability_key, definition_sha256 and package_document; install retains its exact
package, revoke/withdraw retain the last installed package and definition identity.
Receipt has exactly format wotex-home.external-input-receipt@1,
authority_epoch, operation_id, target_id, capability_key, revision, generation,
install_revision, action, input_sha256, outcome_sha256 and store_boot_epoch.
The canonical input array is ["wotex-home.external-input.v1", authority_epoch,
operation_id, target_id, capability_key, expected_install_revision,
expected_generation, action, package_chunks_or_null]. Outcome array is
["wotex-home.external-input-result.v1", action, target_id, capability_key,
definition_sha256, package_chunks]. Receipt array is
["wotex-home.external-input-receipt.v1", authority_epoch, operation_id, target_id,
capability_key, revision, generation, install_revision, action, input_sha256,
outcome_sha256, store_boot_epoch]. Hash input/outcome bytes with their respective
wire format tag, newline and exact wire bytes. All decode/encode operations
require exact ordered-array equality and inherited AuthoringWire bounds;
DocumentChunks preserves the package bytes. Input/outcome wire ceilings are
524288 bytes each, receipt 4096, package 262144. Exact inner/outer hashes and actor/scope/
action/generation links must agree with operation/history/current/journal rows.
Freeze independent vectors before code rather than invent a migration in a helper.

Rules.ExternalInputOperation exposes encode/decode for changes,
encode_outcome/decode_outcome and encode_receipt/decode_receipt. Encoders return
{:ok, document}, decoders {:ok, data}; every refusal is a closed external-input
code. All six operations are producer-independent and require canonical outer
wire, exact closed shape and bounded retained package correspondence. An install
input's package target/key/authority epoch must equal its own. Missing-slot
expectations are exactly 0/0; otherwise both are positive. A revoke input has null
package and positive expected counters. Outcome target/key and Definition SHA
match its retained package for install, revoke and withdraw.

validate_original(input_document, outcome_document, receipt_document) returns
{:ok, original} with exactly plain string keys input, outcome and receipt, or a
closed refusal. It repeats all decoding and checks input/outcome SHA, matching
epoch/operation/slot/action, receipt generation = expected_generation + 1 and
expected install revision < new revision. Install retains the exact input package,
sets install_revision = revision and uses its Definition's Store boot; selection,
binding and trust revisions must precede installation. Revoke retains the old
installation revision and may carry a new Store boot/authority epoch, because
retiring old authority needs no renewed qualification. Withdraw has no scoped
user-operation receipt and is checked through history/cause links by Store.
Principal ownership and actual journal/current/history row links remain Store
Integrity responsibilities; this pure join neither queries nor writes SQLite.

Retain at most 1024 user operations, 4096 history rows and 1024 current slots;
combined input/outcome UTF-8 bytes across operations and history are at most
16777216. Check inclusive prospective count/byte totals before preparation and
inside the transaction. Original replay precedes capacity charging. Capacity
refuses external_input_capacity; it does not evict a no-repeat original.

New install/revoke admission additionally charges the computed retirement reserve
for every installed head after that prospective change. A new install therefore
needs its actual operation/history bytes plus one extra history row and the exact
withdraw outcome bytes; replacement removes the old slot's reserve and charges
the new one. Revoke removes its slot's reserve but still charges its own actual
operation/history bytes. Repeat admission before preparation and in SQL, after
original lookup. New installation generations stop at signed-64 maximum minus
one, reserving the next generation for retirement. No schema change or altered
historical codec follows: capacity/5 and historical validation retain their actual
row/byte ceilings, so retained originals remain readable independently of this
write-admission reserve. Mandatory withdrawal consumes the reserved footprint;
it does not charge a user operation or require a fresh source/key/runtime.

**EI-01 — Install once against the actual current basis.** Recheck actor/grant,
authority/maintenance, slot CAS, complete target/source/reader/declaration and
physical-review package. Prepare immutable bytes and source/runtime evidence
outside SQL. One Store transaction repeats mutable current rows, appends one
journal/operation/history, advances current slot/generation, then runs a final
source/runtime/clock/context guard before COMMIT. Refusal rolls back every row,
revision and pointer. No external caller supplies a trusted prepared context.

**EI-02 — Revoke/withdraw without reviving old authority.** Explicit revoke needs
current operator permissions/grant and slot CAS, but not an available producer,
source or reviewer key. Target replacement/revocation, trust/policy/dependency
withdrawal and selector/installer/approver loss retire affected slots in the same
owning Store transaction. Clear current effective use, retain immutable packages
and origins, and fence future dependent unsent composed work through its later
owner. Current collection still repeats every guard if proactive retirement has
not yet observed a transient host/source/runtime loss. Regrant, restart, copied
packages or replay of an old install do not reactivate a slot.

SQL errors and corrupt_external_inputs disable writes; payload-free named policy
denials leave the writer usable. New own denials are invalid_external_input,
external_input_limit, external_input_unavailable, unsupported_external_input,
external_input_conflict, external_input_basis_changed, external_input_capacity,
external_input_not_installed and invalid_external_input_decision, alongside
stale_external_input_revision, stale_external_input_generation,
qualification_unavailable and runtime_artifact_unavailable. Invalid/revoked bearer
is unauthorized; missing permission or whole-Thing grant is permission_denied;
wrong epoch is stale_authority_epoch; an exhausted revision/generation is
revision_exhausted; missing active target is target_unavailable. An active
maintenance barrier is maintenance_active and an unhealthy writer is
store_unavailable. Unclassified inner failures
must not be wrapped as semantic policy success or expose exception/caller text.

## Complete current requested collection

scope is a proper nonempty list of at most 32 exact target_id/capability_key
objects, unique and sorted lexically by that pair. It contains no Mapping, fact,
report ID, source clock, permission or invented timestamp. Store authenticates
all targets before lookup and derives every context/definition from current
installed rows. One call has a 10000 ms overall preparation budget; before a
five-second owner call require at least 5000 ms remaining. Exhaustion or a hung/
failed owner refuses the complete call, without a partial positive snapshot or
background continuation. Other per-document/producer limits remain in force.

**EI-03 — Rebuild from actual custody.** For every slot, repeat current target
selection, explicit this-boot marker, active selector/approver/installer permissions
and grants, trust/policy/resource counters, source owner/incarnation/selection,
private immutable records, current native producer assertions, reviewed package
and full runtime. Rebuild the actual selected envelope/consumer and original
ExternalValue; compare the complete retained observation outcome. A structural
rehashed value is not live interpretation. No report body or Store handle reaches
a model/transport worker.

**EI-04 — Keep original receipt, expiry and continuity.** Match the durable current
pointer to its immutable report/receipt/journal and the live consumed lifetime's
owner/report SHA/source/channel/sequence. Its original receive coordinate must
project to the exact retained received_store_ms under the current Store boot.
Require nonnegative, nonfuture original receipt and current owner incarnation.
Compute the conservative Store elapsed owner deadline using the same floor
clock. Fact expires_ms is the minimum of owner deadline, receipt plus declaration
freshness, receipt plus reviewed Basis freshness and any narrower original bound;
check signed integer addition before use. Null received_at remains explicit.
Never use processing time, source UTC, default owner TTL or another report as a
receipt witness. Equality at the resulting deadline is stale.

Use ExternalFact.project/4 on the reconstructed native value and exact current
installed Mapping, with Store-derived metadata and original clocks. Fact thing_id
is the injective KernelMapping.thing_iri/1 of the original Home target ID. Fact id
is home:external-input: followed by SHA-256 of
wotex-home.external-input-fact@1, newline and compact UTF-8 JSON of
[target_id, capability_key, install_revision, report_owner_epoch, report_id,
report_sha256]. Affordance comes from the checked reader/Mapping; source_class is
device_report, source_id/source_epoch are the exact original selected source,
profile_digest is sha256: plus the external profile SHA. Receipt epoch/coordinate
and capped expiry come only from the original relation above. received_at is null,
derivation_digest null and contributors []. Convert a non-null canonical uint64
sequence only when it fits WRO max_integer; never truncate or invent it.

Null original source_time requires null metadata source_time/basis/uncertainty,
unknown trust and a null Mapping observation.source_time_basis. For non-null time,
copy its UTC and trust, use the reviewed Mapping's exact source_time_basis, and
ceil its supplied nonnegative uncertainty_us to milliseconds with checked WRO
bounds; null uncertainty stays null. Source UTC never fills received_at. Map
continuous to continuous/fresh, baseline to baseline/fresh, gap to lost/fresh,
retained to lost/retained and replayed to lost/replayed. Unknown continuity has no
projection. Preserve sequence, quality and all independent witnesses. Baseline may supply a current snapshot value under its Basis but
is not an edge; gap/retained/replayed/unknown/null or oversized sequence cannot
invent continuity. Producer refusals never become false/zero. This collector
creates no edge memory; reported-edge persistence is a later composed-run owner.

**EI-05 — Publish one current basis or refuse.** Before returning, repeat the
complete DB/auth/grant/installation/source/runtime/context basis for the entire
scope and sample one final Store elapsed time. A changed basis refuses the whole
collection as external_input_basis_changed; no arrival-order winner or omitted
member is allowed. The one final sample decides freshness of every returned
Fact; an earlier prepared Fact cannot claim freshness after its expiry. Retained
unknown/unusable Fact qualities may be returned with their exact data, for WRO's
independent three-valued evaluation. Missing original/basis/qualification produces
an explicit unavailable item, never a manufactured reader Proposal or Fact.

Result is exactly format wotex-home.external-input-snapshot@1, scope
qualified_external_input_snapshot_only, authority_epoch, store_revision,
store_boot_epoch, sampled_ms and items. Items preserve scope order and have
exactly target_id, capability_key, install_revision, selection_revision,
resource_revision, report_revision, report_ref, owner_expires_ms, binding_basis,
projection and reason. Missing revisions/references/projection/binding are null,
not synthesized. report_ref is null or exact owner_epoch/report_id/report_sha256.
projection is null or the complete eight-member ExternalFact result. A current
qualified binding may remain present while no report exists. Whole result obeys
the fixed selected JSON bounds above, including every repeated Mapping; overflow
refuses external_input_limit rather than returning a truncated set.

reason is null only when collection guards pass and a usable fresh ordinary
snapshot report is available. Other static reasons are input_not_installed,
input_revoked, input_author_unavailable, input_basis_changed, input_unqualified,
source_unavailable, runtime_unavailable, producer_unavailable, missing_report,
old_store_boot, expired, missing_sequence, retained, replayed, gap, baseline_required,
invalid, unknown, stale and unsupported_external_input. Original unusable Fact
projection may be preserved when correspondence still checks; otherwise projection
is null. The result never asserts predicate truth, physical causation, complete
active membership, admission or permission to send.

## Integrity, migration, backup and retry

**EI-06 — Preserve exact history and quarantine.** Schema 37 migration adds empty
new tables. No old approval, source, report, fixture or LIFX claim is promoted.
Historical decoding/Integrity checks exact table columns/indexes/FKs, original
hashes and canonical bytes, history/current/journal causal links, slot counters,
quotas and retained Definition/package shape without requiring current producer,
keys, source or private raw artifacts. Corruption is corrupt_external_inputs and
fences Store startup/writes; current signature/runtime checks remain separate.

Backup and recovery inventories include all three actual tables and sanitized
package bytes for schema 38. Earlier schemas declare empty new tables. Include
external_input_operation_rows, external_input_history_rows,
external_input_current_rows, external_input_installed_rows and
external_inputs_reactivate false. Each count is an integer from the actual table
or zero for an earlier schema; installed counts only state=installed and is not
a claim of current usability. Retained input packages require independently
configured reviewer keys for current use. No
reviewer key, live lifetime pair, source owner, private raw artifact or Store
boot authority is restored. Inclusive, database-only and normalized transfer stay
quarantined. A source/Store restart requires fresh current selection and review
against its new clock context; old scoped receipts remain history and cannot add
this-boot markers. Lost replies recover the original before signing/installing
again. Cancellation/refusal does not refund a retained original or silently retry
an uncertain enclosing effect.

The full schema-38 snapshot commitment covers the actual 62 user tables and 68
non-internal schema objects (six existing explicit indexes, no new explicit
index). The schema-object enumeration ceiling is 69, preserving room for one
additional retained non-domain schema object, including a controlled SQL fault
trigger in acceptance fixtures. Hash every object's exact type/name/table/SQL;
never omit that object from source/quarantine correspondence. Input-domain DDL
and index checks still refuse additional objects on those three owned tables.
The existing row/byte ceilings remain unchanged. For the normalized v1
retained transfer commitment, omit all three input-domain tables when no input
history exists at or before the source retirement revision. This preserves
existing schema-37 commitments after an empty migration. Otherwise include exact
operation/history rows through that source revision and reconstruct each current
head from its latest history through that revision, including the last install
revision in that slot. Later acceptance/withdrawal never changes this projection.
The pre-transfer and post-acceptance retained commitments must remain identical;
adding empty tables, later heads or a new boot never authorizes reactivation.
Linux package declarations, current image/status gates and independent packaged
probes follow the explicit [schema-38 host successor](linux-update-schema35-v1.md#schema-38-external-input-successor);
historical schema-37 package verification grants no cross-schema update.

## Implementation entry and acceptance

Commit this contract before code. Freeze programme, Definition/context/runtime,
review-package/input/outcome/receipt/snapshot schemas and independent canonical
wire/hash/signature vectors. Use existing three reader quantities and independent
unit/clock arithmetic. Generic producers are selected from Home's locked cohort;
synthetic runtime/signing data must be labeled and cannot claim installed evidence.
Deliver current runtime/definition/decision, then schema/history, actual Store
install/invalidation/recovery, then requested current collection in logical commits.
Run focused tests per slice and the owning mechanism milestone after integration.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| EI-T1 | 01/03/04 | Actual current readers, reviewed integer/Boolean/enum/unfamiliar supported quantity and multi-channel target; independent full Definition/wire/result, units and clocks | Native and Store software |
| EI-T2 | 01/06 | Complete fixed programme, separate reviewer keys, missing/extra/failed/fixture-in-hardware claims, aliases/same public key, signature/cohort/runtime/Mapping mutation; zero implicit qualification/effects | Software trust mechanics |
| EI-T3 | 01/02/06 | Actual SQLite original-first install/revoke, actor scope/CAS/capacity, lost reply, producer-free history/revoke, selector/installer/approver/grant/trust/source withdrawal | Durable software |
| EI-T4 | 01/02/05 | Change every mutable current/final binding, actual SQL publication/withdrawal failure; all operation/history/current/revision rows roll back, policy denial stays writable | Durable software |
| EI-T5 | 03–05 | Whole authenticated 1/32 scope, duplicate/33/foreign member, mixed known/unknown, missing source/custody/producer/report, late expiry and complete basis drift | Store software |
| EI-T6 | 03/04 | Actual report-owner lifetime, -1001/-1/0/1/65-bit relation, UTC null, exact expiry, null/max/duplicate/out-of-order/gap/retained/replayed sequence, boot/reconnect replacement; no positive edge | Native and durable software |
| EI-T7 | 01/03/05 | Every runtime group's bytes/version/module inventory/absence changes at opening/closing; historical assertions cannot seed current context; no smaller-scope fallback | Isolated runtime software |
| EI-T8 | 02/06 | Deep original/package/slot/history/journal corruption, schema 37 migration, exact quotas, encrypted inclusive/database-only/normalized quarantine and source/Store restart | Durable/recovery software |
| EI-T9 | 01–06 | Independent extracted reader/routine package consumer and identity/unit/clock/qualification mutants, plus existing ordinary read and unconditional-effect regressions | Archive/software |

These software cases do not fill the programme's hardware obligations, installed
host validation, physical safety checks or the complete WOH.20 acceptance suite.
The later composed execution contract must consume this exact current basis,
collect all eligible active programs and repeat relevant guards at commit, claim
and final physical handoff; this snapshot is not a substitute for that work.

The runtime helper now implements current/0, digest/1 and check_current/2.
Eight focused entry/runtime cases pass, including every one of twenty complete
application members under byte/version/module-list drift inside a warmed Store
inventory guard, and actual missing application metadata. This establishes only
the bounded runtime foundation of EI-T7, not a Store installation/collection
guard or completion of EI-T1–T9. [Executed evidence](../provenance/routine-external-inputs-2026-10.md)
records the isolated scope, cleanup and remaining work.

Pure Definition construction/reconstruction, producer-independent historical
decoding and the signed-review verifier now pass twenty focused cases including
five entry cases. Actual native integer, Boolean and enum readers supply their
read-only correspondence; the independent frozen Definition/wire/hash and nine
signature payloads stay unchanged. Validly re-signed missing/extra/failed/duplicate,
cohort/environment drift and same-key reviewer aliases refuse. Historical parsing
still refuses write operations and cannot manufacture a native current token.
These are EI-T1/T2/T7 foundations, not current Store qualification or completed
integration cases. Retained package/input/outcome/receipt codecs and the exact
original join now pass thirty-three focused codec/Definition/review/entry cases.
All four encodings match the independently frozen bytes. Historical package and
original recovery work with actual producer paths and the current programme file
removed. Revoke can retain old installation history under a new boot/epoch;
current verification requires exact canonical package bytes and signatures.
These are EI-T3/T8 representation foundations. The separate ExternalInputs
collaborator now supplies exact DDL, prospective quotas and retained graph checks;
eighteen focused real-SQLite cases plus the thirty-three existing cases pass.
Distinct authors, two slots, durable first-loss/native-grant links, canonical
originals, SQL constraints, Unicode byte accounting and transaction rollback are
covered. A fresh VM validates actual SQLite history with producers and the current
programme file unavailable. Schema 38 now integrates startup and pre/post-write
Integrity, transactional migration, exact backup inventories/counts, encrypted
quarantine and source-revision normalized recovery. Seventy-seven focused
history/migration/recovery cases and twelve selected earlier-schema migrations
pass. A separate probe loads the actual preceding schema-37 recovery code and
confirms its retained hash equals the current code before and after an empty
migration. Twenty-two portable package/update/probe cases pass under the explicit
Linux schema-38 cohort; Linux-only and installed execution remain unverified.
Native Authority/Store context now rebuilds the actual selected private reader,
authors/grants, source and clock under the shared preparation budget. Repeated
source/custody/runtime checks, actual Store restart, original replay, owner timeout
and corruption fencing have focused software coverage. Isolated Store probes
change complete artifact bytes in one member of each runtime group during private
preparation; all refuse, including profile drift discovered before final inventory.
The shared preamble clears prior byte checks without reading unrelated portable
custody before context authentication, even with an active schedule. Computed
retirement reserve and Store's atomic first-loss withdrawal batch are implemented.
Sixty-five focused history/withdrawal/maintenance/controller cases pass, plus an
additional actual end-maintenance/restart/original-replay probe. Two-slot ordering,
all durable loss classes, three separate authors, exact native grant receipts,
second-withdrawal SQL rollback, counter exhaustion and a 160-slot actual-byte
quota refusal are covered. These use structurally retained, unqualified legacy
history and do not establish actual native Mapping installation. Original-first
install/revoke with reserve admission, complete current collection and their
actual-native integration remain next. No fixture establishes physical qualification.
