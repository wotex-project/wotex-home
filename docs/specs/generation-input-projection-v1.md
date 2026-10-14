# Bounded profile generator input projection

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-09/H18-T14/T15/T17; profile-authoring-v1 H18A-02/05.
Implementation: pure bounded projection implemented.
Evidence: [executed independent byte, boundary and Store cases](../provenance/generation-input-projection-2026-10.md).

## Purpose and ownership

Profiles.GenerationInput constructs one exact, bounded, private input document
for a later explicitly selected generator. It includes the installed producer
contract, an instruction, selected byte passages and explicitly selected fixture
examples. It excludes complete source originals and every unselected object.
Source instructions remain strings in data; this component supplies no tools,
transport, shell, provider credentials, Store, network, admission or activation.

This is a pure structural boundary, not permission to export. Authority and the
single Store must later prove actor ownership, current permission/epoch, original
operation, export policy and provider selection before each handoff. This value
cannot prove those facts, authenticate a provider or establish source truth.
No public route, runtime generator, schema migration or provider pin is added.
Existing manual authoring and review behavior remains unchanged.

The checked AuthoringContract owns installed grammar and current producer
reconstruction. AuthoringObject owns the WOHA kind-bound frame: its digest hashes
the complete header plus original bytes, separately from the payload SHA-256.
Custody handles include object_digest and positive signed-64 first_revision;
revision is an explicit caller assertion here and must later match Store history.
Fixtures remain independently reviewed examples, never generated test oracles.

## Closed inputs and bounds

`GenerationInput.prepare(contract, request, objects)` takes:

* An actual native AuthoringContract, revalidated through to_map/1. Its producer
  contract digest must equal request.contract_digest. Its complete producer JSON
  bytes, at most 262144, enter the projection; capture, installed Home policy and
  archive/runtime assertions remain outside it. Contract revalidation may refuse
  profiles_producer_unavailable, stale_profile_runtime or its owning errors.
* Request exactly contract_digest, instruction, passages, examples and limits.
  Digest is lower hex64. Instruction is UTF-8, 0..4096 bytes; Unicode Cc except
  LF/tab refuses, including NUL. No normalization or instruction execution.
* Passages: a proper list at most 32, sorted uniquely by
  (reference.object_digest, offset, length). Each row is exactly reference,
  offset and length. Reference is exactly object_digest and first_revision;
  digest lower hex64 and revision 1..9223372036854775807. Offset is integer
  0..262144 bytes, length integer 1..4096 bytes. Repeated source digest must use
  the same first revision. Overlapping distinct passages are permitted and count
  fully toward the aggregate. Empty list means no sources, with no default fetch.
* Examples: a proper list at most 32, sorted uniquely by object_digest, each an
  exact reference. Empty means no examples. An example must be a fixture frame
  containing UTF-8 JSON of at most 65536 bytes, depth eight, 4096 nodes,
  collections 256 and strings 4096; duplicate keys and invalid JSON refuse.
  Its decoded top-level object is exactly expected, id, report and selector;
  id is a Home ID. Semantic/selector/expectation assessment is owned by
  AuthoringFixtures and is not inferred from this structural check.
* Objects: a proper list at most 64, sorted uniquely by reference.object_digest.
  Each native row is exactly the atom-keyed map %{reference: reference,
  object: AuthoringObject}. Its references must equal exactly the union selected
  by passages/examples, including first revisions. Missing, extra, wrong-kind,
  changed frame/payload/hash or conflicting reference refuses as a whole. No
  path, URI, lazy loader, callback or arbitrary native object is accepted.
* Limits exactly max_passages, max_passage_bytes, max_passages_bytes,
  max_examples, max_examples_bytes and max_input_bytes. Every value is a positive
  integer; respective ceilings are 32, 4096, 131072, 32, 262144 and 1048576.
  There are no implicit limits. Each supplied limit may narrow its ceiling.

**GI-01 — Bound before traversal.** Refuse at the first over-budget list cell
without walking its tail. Validate request/native shapes and counters before
source extraction. Revalidate each selected object's complete frame and require
the declared digest/kind before reading its payload. Cut source bytes by offset
and length, without reading another object or extending a range. Selected slices
must end within the payload, be independently valid UTF-8 and contain no Cc except
LF/tab. A binary/non-UTF-8 original is permitted if its selected slice meets this
rule; unselected bytes are inert and remain excluded. Count actual selected bytes
and raw fixture bytes independently; JSON escaping must also meet max_input_bytes.

Malformed/unknown/struct/duplicate/order/range/text/example/native input refuses
invalid_generation_input. A missing/mismatching referenced object refuses
stale_generation_reference. Selected contract digest mismatch refuses
stale_authoring_basis. Positive values above a ceiling, over-budget collection,
aggregate, encoded input or producer JSON resource limit refuse authoring_limit.
All failures are atoms; no private bytes are interpolated into errors or logs.

## Output and identity

**GI-02 — Preserve a complete projection identity.** Native output has exactly
document, sha256 and summary plus its struct tag. It retains no complete source,
object, request, contract native value or fixture native map. Document is compact
public Wotex.JSON canonical UTF-8 JSON with exactly:

```
{"format":"wotex-home.profile-generation-input@1",
 "contract":{"sha256":WPF_contract_digest,"document":original_contract_text},
 "instruction":original_instruction,
 "passages":[{"reference":handle,"payload_sha256":raw_source_SHA,
              "offset":byte_offset,"length":byte_length,"text":exact_slice}],
 "examples":[{"reference":handle,"payload_sha256":raw_fixture_SHA,
              "document":original_fixture_text}]}
```

Arrays preserve checked order. Strings preserve exact UTF-8 bytes, including
NFC/NFD distinctions; JSON escaping is representation only. The contract digest
and source payload hash do not claim export authorization or physical identity.
Sha256 hashes UTF-8 `wotex-home.profile-generation-input@1`, newline, then the
exact document bytes. Summary is exactly format
wotex-home.profile-generation-input-summary@1, input_sha256, input_bytes,
contract_sha256, passages, passage_bytes, examples and example_bytes (counts).
Summary includes no text, handles, path, endpoint, provider, private identity,
capture or bearer. Inspect of the native value exposes only summary.

Public canonical encoding applies max_input_bytes, depth eight, 4096 nodes,
collections 256 and strings 262144. Raw example JSON is retained as a string
after structural checking; it is never rewritten from decoded numbers or units.
No generated draft, repair diagnostics or candidate bytes enter this initial
projection. A later repair contract must bound and authorize those inputs.

## Failure, retry and implementation entry

**GI-03 — Keep computation separate from handoff.** This component starts no
process, performs no transport or private custody I/O and changes no durable state, deadline, attempt, grant,
profile, Store revision or custody quota. Equal explicit inputs yield equal
documents and summaries; changed selected bytes/revision/range/instruction/
contract change the projection identity. A changed limit that still admits the
same projection does not change its identity: limits constrain preparation,
whereas the later durable operation must bind the entire request and limits.
Contract revalidation retains the producer owner's packaged artifact checks.
Source bytes outside selected slices affect payload correspondence hashes but
never enter the document. No cancellation, retry or restart calls a provider.

Do not retain or hand off a prepared projection after permission, export policy,
source ownership/revision, installed contract or provider selection changes.
Durable authorization/operation receipts, host-wide capacity, monotonic deadlines,
per-provider egress, cancellation, unknown handoff and original recovery remain
explicit prerequisites to installing any generator route. Every handoff needs
its own current Store checks; this value cannot stand in for them. Documents
are private artifacts, never ordinary diagnostics or OTP crash/status output.

Before implementation freeze an independent Python oracle using existing exact
contract export vectors, WOHA framing and hashlib. Include two independent
quantities, byte-ranged Unicode, a canary outside the selected source slice,
inert prompt-injection text and exact fixture JSON bytes. Implement through the
consumed producer APIs; missing APIs have no local encoding fallback.

## Acceptance

| Case | Requirements | Stimulus and expected observation / falsifier | Level |
| --- | --- | --- | --- |
| GI-T1 | 01–03 | Two installed contracts and independent framed source/fixture vectors match exact Python bytes/hash/summary; no unselected canary or private native data appears; input and frame originals remain unchanged. Any coercion or disclosure fails. | Pure/software |
| GI-T2 | 01 | Unknown/struct/improper/over-budget collections, duplicate/unsorted handles, conflicting revision, wrong kind/frame/hash, missing/extra object, bad UTF-8/control/range and malformed/duplicate-key/deep fixture JSON refuse atomically. | Pure/software |
| GI-T3 | 01/02 | Exact byte/count/aggregate/encoded limits pass; one beyond refuses; multi-byte split refuses, Unicode variants stay distinct, overlap counts fully, selected injection remains inert text and raw numeric fixture bytes stay exact. | Pure/software |
| GI-T4 | 02/03 | Repeated preparation is exact; changed selected basis changes identity, forged contract refuses, Inspect redacts text; actual Store/custody revision and file inventory do not change. No provider invocation or new process is observed. | Pure/software |

These cases establish structural input isolation only. They do not establish
provider confinement, export permission, semantic correctness, installed host
delivery or physical qualification.

## Sources and decisions

[Authoring owner](profile-authoring-v1.md),
[manual candidates](authoring-candidates-v1.md),
[source passages](native-source-passages-v1.md),
[producer adoption](producer-cohort-adoption-v1.md). Consumed WoTEx source is
ba8ea373244ce57987f47a731b8eca3ccae9b45f from mix.lock. Home owns selection/export
policy; generic producer JSON/contract mechanics remain in WoTEx. No producer
change is required for this projection.
