# Authenticated installed authoring contract export

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-09/H18-T13/T16 and WOH.15 authoring operator delivery.
Implementation: authenticated Store/Authority, private framed route and CLI read implemented.
Evidence: [executed exact-byte/current-basis and socket/CLI cases](../provenance/authoring-contract-export-2026-10.md).
Native presentation and manual-original construction remain separate successors.

## Result and inherited boundaries

An authorized author reads the installed public WPF authoring grammar, exact
Home limits/consumer references and current principal/authority/revision basis
before constructing a manual candidate original. A contract export is an inert
read, never a custody import, candidate, trust decision, selection, lease or
grant. No capture values, hardware identity, publisher PID, endpoint, credential
or private source/draft bytes are exported.

[Installed runtime](installed-profile-runtime-v1.md) supplies Host's checked
AuthoringContract; [profile authoring](profile-authoring-v1.md) owns its export
and complete basis hash. WPF Contract.export/4, encode/1 and identity/1 define
the exact grammar bytes and semantic identity. Raw bytes are separately bound
by contract_raw_sha256. The existing basis_sha256 includes producer identity,
Home references, limits and consumption policy; it is not physical evidence.
Store alone supplies principal_id, active authority_epoch and store_revision.

## Closed output and operation

**CE-01.** Authority.authoring_contract_export/2 forwards current credential to
Store.authoring_contract_export/2. Before producer or configuration work, Store
requires writable current state, active controller and current profile:manage.
Invalid/missing/revoked credentials use existing invalid_credential,
unauthorized or permission_denied outcomes. Retired source, quarantined recovery
mode and damaged Store/controller retain their typed refusal. Missing installed
AuthoringContract refuses authoring_unavailable. Existing maintenance does not
forbid this inert read; later import/assessment still applies its own guards.

Reconstruct the native AuthoringContract through to_map/1 against actual current
producer bytes. Return exactly format, principal_id, authority_epoch,
store_revision, summary and contract_base64. Format is
wotex-home.authoring-contract-export@1. Principal is a Home ID, epoch positive
signed-64, revision nonnegative signed-64, all from this serialized Store read.
Summary is the existing exact eight-field contract summary: format,
contract_sha256, contract_raw_sha256, producer, home_contracts, limits,
consumption_policy and basis_sha256. The document is nonempty UTF-8 WPF public
Contract.encode/1 bytes, at most 262144, encoded URL-safe Base64 without padding,
at most 349526 characters. It must decode/re-encode identically and match the
summary's full raw SHA. No default contract, neighboring file, ambient schema
or old archive/runtime assertion is substituted on failure.

**CE-02.** The private framed route authoring_contract_export has exactly
api_version integer 1, operation and credential; no arguments or optional keys.
Success is the existing api_version/outcome wrapper with one body key
authoring_contract. Existing 65536-byte requests and 1048576-byte responses
remain unchanged. CLI command authoring-contract takes no arguments and emits
that explicit JSON read response through current socket/credential handling.
There is no automatic file publication or original submission. Existing current
transport authentication and profile:manage remain mandatory wherever the
shared Authority read is consumed; no new pairing, signer or credential flow.

## Retry, drift and recovery

Export creates no durable rows, revision, quota reservation or lease. Repeated
reads may observe a new revision, epoch or installed basis; callers preserve
the complete selected export and take a fresh current basis before constructing
or confirming a mutation. A lost reply is a read transport failure and may be
retried, never an outcome_unknown mutation. An exported revision is not a CAS
reservation. Restart/revocation/configuration succession cannot authorize use
of the old export; every later operation rechecks its original current guards.
Historical candidate/review originals remain readable without this installed
export and cannot be rewritten to the new producer basis.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| CE-T1 | 01 | Two independent fixture families under actual pinned runtime: decode exported bytes, compare frozen WPF semantic/raw identities, complete summary, current principal/epoch/revision and unchanged Store revision across repeats. Capture/private payload or invented basis fails. | Actual Store/public producer |
| CE-T2 | 01 | Current permission failure precedes absent installation; valid manager gets authoring_unavailable when unconfigured, forged/current-changed contract refuses. Retained object/candidate history remains available and no new row appears. | Store |
| CE-T3 | 02 | Actual framed socket and CLI export match Authority bytes/basis; extra fields/version/arguments reject. Lost read reply maps to transport failure, no mutation uncertainty/status advice. Widened frame or automatic publication fails. | Socket/CLI software |

Native decoding/presentation and ergonomic manual-original construction are
separate successors. This read qualifies no installed host, transport mapping,
physical report or device effect. Focused format/compile/catalogue and affected
authoring/export tests are required; full milestone gates remain separate.
