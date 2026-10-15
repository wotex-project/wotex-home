# Explicit external source selections

Version: 0.1.3. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.18 H18-04/05/08/H18-T11/T12; WOH.03 H03-02.
Implementation: pure checked source/reader/consumer-policy selection implemented.
Evidence: [independent identities and exact archive cases](../provenance/external-source-selection-2026-10.md).

## Result and ownership

A host explicitly supplies the complete source identity assertion, checked
reader/capture and accepted per-channel consumer/policy configuration needed
for a later generic target selection. This pure native value binds those
inputs without selecting a device endpoint, loading code, authenticating a
physical source or creating a grant. It cannot replace current source-owner
custody, operator review, durable selection or report correlation. There is
no source/model/sensor enum and no cloud dependency.

The [inspection owner](external-inspections-v1.md) owns checked ReaderSelection,
including actual explicit capture, installed bindings/contract references,
reader ceilings and archive assertions. The [value owner](external-values-v1.md)
owns each closed five-field Home consumer and its exact unit/quantity checks.
The [read declaration](external-read-declarations-v1.md) joins a selected channel
to a consumer and household policy. The [shared representation](generic-read-semantics-v1.md)
retains its exact read metadata. This source value is the missing host input
between catalogue trust and target-specific declaration preparation; an earlier
catalogue inspection capture cannot be substituted for a different target.

## Closed inputs and bounded construction

Profiles.ExternalSourceSelection.new/3 takes source, ReaderSelection and channels.
All inputs are explicit and the producer is required during construction.

Source contains exactly source_ref, stable_id, source_epoch, source_generation,
method and trust. Source_ref and stable_id are Home IDs (ASCII 1–128 bytes);
stable_id is private host custody, never a model-authored physical identity.
Epoch is lower hex32 supplied by the actual source owner; generation is positive
signed-64 and changes on owner/configuration succession. Method is exactly
operator_configured, legacy_tofu, physical_button or qr_install_code. Trust is
exactly unauthenticated_local, authenticated_device, bridge_attested or
synthetic_lab. These are explicit host assertions. Their syntax does not verify
pairing, a TLS peer, child-device authenticity, source age or physical evidence.
No value is inferred from method, fingerprint, URI or confidence.

Channels is a nonempty proper list at most 32, strictly sorted by channel_id,
unique by channel ID and policy.capability_key. Each row contains exactly
channel_id, consumer and policy. Channel is a Home ID. Consumer is the complete
five-field record accepted by ExternalValue.consumer_identity/2. Its exact
reference must appear in the checked reader's installed home_contracts;
semantic_ref is verified later against the actual target closure. Policy is
exactly capability_key, evidence_ref, risk_class and freshness_ms: two Home IDs,
risk ordinary or sensitive, freshness integer 1..86400000 ms. No thing_id is
included yet; the reviewed target operation supplies it before read declaration
preparation. Reusing a consumer reference with different explicit semantic/
coordinate contents across channels is permitted and bound by its distinct
content SHA; no label lookup chooses a consumer implicitly.

**ES-01 — Check every supplied host input.** Reconstruct ReaderSelection through
its public to_map/1 and validate each consumer through the shared public
consumer_identity/2 under the reader's identical limits. Before consumer/unit
construction, bound complete JSON inputs containing source, reader.inputs and
channels through public core JSON.encode/2: at most reader.max_bytes (ceiling
262144), reader.max_depth plus one (ceiling nine), reader.max_nodes (ceiling 4096),
collection 256 and strings/keys 4096. A native ReaderSelection itself is not
serialized as an arbitrary struct. Unknown/struct fields, malformed IDs/epochs/
counters/method/trust/policies/order/duplicates refuse invalid_external_source.
Resource excess refuses external_profile_limit; missing producer API refuses
profiles_producer_unavailable. Inherited reader/consumer errors retain their
owning typed outcomes. An uninstalled consumer reference refuses
unsupported_external_source. No defaults, discovery or fallback are introduced.

The one additional depth level belongs only to this complete-input wrapper:
ReaderSelection and each consumer still pass their unchanged reader limits
before use. In particular the installed MQTT selector's nested path-item schema
must fit after wrapping. Canonical bytes and identities are unchanged for
previously admitted sources; no reader, decoded value or report limit increases.
SourceOwner's byte accounting and RetainedSource's complete-input witness use
the same plus-one wrapper allowance. Historical decode applies nine only to
that input witness, then separately decodes its identical reader and channel
witnesses at their existing depth eight. Other retained JSON containers remain
at eight. Nested source-only data cannot borrow an unbounded producer envelope.

## Native output, privacy and correspondence

Native ExternalSourceSelection has exactly inputs, data and sha256 plus its
struct tag. Inputs is exactly source, reader and channels and retains private
host stable identity/capture/consumer bodies only in host memory. Data is exactly
format wotex-home.external-source-selection@1, source_ref, stable_id_sha256,
source_epoch, source_generation, method, trust, reader_basis_sha256 and
policy_sha256. Stable_id_sha256 hashes UTF-8
wotex-home.external-stable-id@1, newline and the original stable_id bytes;
it is correspondence metadata, not a physical attestation. Policy_sha256 hashes
UTF-8 wotex-home.external-source-policy@1, newline and public canonical JSON
of the exact ordered channels. Sha256 hashes UTF-8
wotex-home.external-source-selection@1, newline and canonical JSON of complete
inputs represented as source, reader.inputs and channels. Data omits stable_id,
capture fields, selectors, unit/schema bodies, endpoints and credentials.
It never carries a Store connection, bearer, module name or executable callback.

**ES-02 — Reconstruct native values.** to_map/1 rebuilds all explicit inputs,
compares every native input/data/hash field and returns exactly data and sha256.
Extra/forged native fields refuse invalid_external_source. Repeated calls do not
renew a capture, source epoch, clock, lease, approval or generation. A changed
source identity/epoch/generation/trust/method, reader/capture/producer/limits or
channel consumer/policy has a distinct complete basis. Failed reconstruction
cannot be replaced with a payload-only summary.

## Durable selection and source-owner entry conditions

This pure slice changes no schema or runtime option. Before current target use,
the [accepted source-custody contract](external-source-custody-v1.md) owns
the explicit process/port
installation, bounded snapshots/leases/deadlines, principal/original scope,
owner/configuration succession, physical report correlation and cleanup. The
source owner receives no principal bearer or Store connection. Authority must
authenticate profile:manage plus enroll:review for new target enrollment before
requesting a source snapshot. The operator can reference only an already held
source_ref; data cannot install a ReaderSelection, consumer policy or endpoint.

The durable external target successor must define exact original input/outcome/
receipt encodings and the next actual schema before code. New selection must
recheck current approved trust author/revision/separate policy generation,
actor-owned raw closure, actual held target source/capture/policy, epoch/CAS,
maintenance and previous selection/resource/enrollment basis at preparation and
commit. Recompile target-specific declarations through public WPF APIs; preserve
catalogue approval capture and new target capture as distinct histories. New
Things receive no grants. Declaration expansion/meaning changes cannot silently
widen existing distributed grants. Replacement/revocation must invalidate
dependent reports, freshness, qualification and unsent work atomically; uncertain
handed-off outcomes remain uncertain. Original replay must precede source/byte/
producer work; metadata-only revoke remains possible without them.

The source-custody process is implemented with separate executed evidence;
Host installation and the durable target contract remain unfinished entry conditions,
not implied capabilities of this value. Current generic ProfileGuard continues
to refuse profile_selection_unavailable until that lifecycle is implemented.
Canonical external report/Store-clock admission remains a further owning
transition, including source continuity, replay, sentinel, risk and qualification.
Missing physical/protocol qualification keeps physical dispatch disabled.

## Acceptance

Freeze independent complete-input, policy, stable-ID and basis identities before
code. Use actual checked archive readers, not invented installed registrations.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| ES-T1 | 01/02 | Both independent quantities and a multi-channel explicit host source match frozen identities and expose only the safe summary. A sensor-name branch or private stable/capture/consumer leakage fails. | Pure/software |
| ES-T2 | 01 | Unknown/struct/deep/big input, policy bounds, duplicates/order, uninstalled consumer and invalid source fields. Any accepted implicit policy/endpoint/default fails. | Pure/software |
| ES-T3 | 02 | Forge native fields or change source/capture/reader/consumer/policy basis. Unchanged complete identity or accepted forged summary fails. | Pure/software |
| ES-T4 | 01/02 | Missing producer and narrowed reader limits refuse. Construction creates no Store revision, grant, source process, lease or physical packet. | Pure/software |
