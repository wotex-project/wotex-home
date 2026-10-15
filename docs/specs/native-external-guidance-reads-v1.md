# Native external-profile guidance reads

Version: 0.1.3. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09/H08-T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08/H18-T6/T8/T11/T12.
Implementation: explicit local SDK reads and closed typed decoders implemented.
Evidence: [executed independent-peer and Store checks](../provenance/native-external-guidance-2026-10.md).
The [selected guided consumer](native-external-profile-guided-v1.md) is implemented
with [executed evidence](../provenance/native-external-profile-guided-2026-10.md).
Signed paired delivery remains a subsequent consumer.

## Result and owners

The native SDK reads the four authenticated bodies defined by
[Home guidance](external-profile-guidance-v1.md), returning typed, immutable,
redacted comparison metadata. This owns their closed native decoder, exact
read-only request shapes and identity bracketing. It allocates no operation,
source lease, pending journal entry or approval. Selected driver composition,
guided editing/confirmation and signed paired delivery remain separate consumers.
The SDK accepts an existing private local socket and32-byte credential; it never
chooses either, reads Keychain or falls back from a paired selection.

The [existing local SDK](native-external-profile-reads-v1.md) owns private socket,
peer, frame and controller identity mechanics. Requests keep api_version1 and
the exact credential/operation/fields. Native JSON is bounded by the existing
1048576-byte strict duplicate/depth parser. No generic arbitrary-operation or
mutation transport is introduced. Errors keep the existing bounded lower ASCII
reason grammar (1–128 bytes, first lowercase letter, then lowercase/digit/underscore).

## Inputs and identity checks

**NGR-01.** Offer context, sources, target(target_id) and
artifact(inspection_ref). Validate credential length, target ID or all five
reference fields before any request. IDs are1–128 ASCII bytes, first alphanumeric,
then alphanumeric/dot/underscore/colon/hyphen. Digests are lower hex64; all
epochs/revisions are positive S64, except the explicitly nonnegative counters.
Reject bool/float/string/overflow coercion. Reference has exactly authority_epoch,
operation_id,revision,input_sha256,result_sha256; never change its historical epoch.

Each call sends identity, one fixed guidance request, then identity. On malformed
domain data or refusal stop immediately. A missing artifact still sends final
identity before returning nil. Successful before/body/after identities must share
deployment,owner,authority epoch and principal; Store revision must be equal
throughout. Body principal/epoch/revision match the bracket. A changed identity
or watermark raises nativeGuardConflict; do not retry or silently refresh.
Historical reference epoch may differ from the current authority epoch, but its
receipt revision cannot exceed the body's current Store revision.

## Closed bodies

**NGR-02.** Require the exact success envelope api_version,outcome,named member.
Only artifact accepts the exact api_version/outcome=not_found envelope. Each body
has exactly the common format,principal_id,authority_epoch,store_revision,
policy_generation and its owning additional fields. Common policy is0–1024,
not greater than Store revision. Format is the exact owning @1 string. Compact
native JSON of each body must fit the owning4096/32768/8192/65536-byte ceiling.
Typed values and nested values redact reflection; retain safe fields only.

- Context: maintenance normal with revision0, or maintenance with positive begin
  revision no greater than Store revision. Reader is exactly state,basis_sha256,
  reason: available/digest/null, or unavailable/null with
  external_reader_unavailable or profiles_producer_unavailable.
- Sources: available/lowerhex32 owner/null reason and0–32 strictly sorted/unique
  source_ref rows; or unavailable/null owner/empty rows/external_source_unavailable.
  Rows contain exactly source_ref,source_selection_sha256,reader_basis_sha256,
  source_epoch,source_generation,method,trust,policy_sha256. Method is
  operator_configured/legacy_tofu/physical_button/qr_install_code; trust is
  unauthenticated_local/authenticated_device/bridge_attested/synthetic_lab.
  Source generation is positive S64; source epoch lowerhex32. No stable identity/hash or capture is
  accepted. Availability with an empty list remains distinct from unavailability.
- Target: requested target ID must match. State absent requires all four counters0,
  null artifact and trust0. Selected/revoked requires positive selection revision,
  selection generation and binding revision, generation no greater than selection
  revision, nonnegative resource revision equal
  generation minus1, binding not greater than selection, and a digest with positive
  current trust revision. Selection/trust cannot exceed Store revision. Selected
  binding equals selection; revoked may retain an earlier binding. Do not infer
  current approval from target state or the retained digest.
- Artifact: inspection_ref must equal the exact requested reference. Accept only
  the existing native manifest format,id,version,objects. ID uses Home grammar;
  version is three canonical decimal UInt16 components. Objects are envelope,
  profile then0–32 sorted definitions. Every row has exactly kind,reference,
  object_digest,payload_sha256,payload_bytes. Envelope reference is null; others
  use exact id/version/sha256 references with the pinned Home URI grammar.
  Definitions have unique reference IDs, strict id/version order and distinct
  object digests across the closure. Payload sizes are1–65536 each, profile plus
  definitions at most262144 bytes. Canonical full manifest fits32768 bytes.

**NGR-03.** Verify artifact_digest independently as SHA256 of UTF-8
`wotex-home.external-artifact@1\n` followed by compact JSON of ordered object
arrays [kind, reference-or-null, object_digest, payload_sha256, payload_bytes],
where reference is [id,version,sha256]. Preserve lowercase digest and exact array
ordering; do not hash the native map, include manifest id/version in this hash,
or substitute payload/object/reference digests. Full canonical manifest is
[format,id,version,object-arrays]. No raw payload/capture is returned. Manifest
correspondence proves neither present bytes nor current trust/selection.

## Failure and acceptance

No state is persisted. Cancellation, missing/changed owners, retirement,
revocation, restart and restore remain actual Store decisions. Each explicit
retry is a fresh read; a cached success is not an authorization seal. Timeouts and
malformed responses cannot become a mutation-uncertain receipt or partial value.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NGR-T1 | 01–03 | Exact independently written requests/bodies using both existing quantity manifests and safe source vectors, available/unavailable and absent/selected/revoked variants. Digest, private-field leakage or decoder coercion fails. | Native/framed independent fixtures |
| NGR-T2 | 01/02 | Wrong credentials/IDs/ref before IO, extra/missing/duplicate data, malformed enums/counters/order/size, server reasons and missing artifact. Extra request, normalization or partial output fails. | Real private peer |
| NGR-T3 | 01 | Changed before/body/after principal, epoch, owner or revision, historical ref and lost reply. Stale acceptance, auto retry or mutation fails. | Independently sequenced peer |
| NGR-T4 | 01–03 | Both families through actual Store/Authority/socket, compare typed manifest/digest and unchanged revision/leases. Pure fixture or build success alone does not establish this level. | Actual local software |

Record executed cases and remaining gates separately. These reads do not establish
guided UI, signed installation, actual protocol publisher identity or physical
qualification. No dependency or producer changes are required.
