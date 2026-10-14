# Authenticated generator policy and original operators

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18A-02–05/H18-T15/T16/T17; WOH.15 H15-03; WOH.14 originals.
Implementation: actor-scoped metadata, private socket/CLI operations and typed
response validation implemented. Evidence: [executed software cases](../provenance/generation-operators-2026-10.md); provider/native/signed delivery remains.

## Result, owners and inherited boundary

An authenticated profile author can inspect their installed export-policy
metadata, prepare an inert original, start one explicit initial/repair attempt,
read either original/status and cancel its preparation through the private socket
and CLI. Adapters invoke the implemented Authority/Store use cases unchanged.
There is no adapter-side generation, provider selection, automatic repair,
profile approval, enrollment, target selection, observed device state or effect.

[Preparations](generation-preparations-v1.md) own source/fixture selection,
current policy, immutable preparation receipt and nonrenewing lifetime.
[Attempts](generation-attempts-v1.md) own export reservation, temporary workers,
current response guards, exact candidate/assessment retention, explicit repair
and uncertain outcomes. Their current profile:manage actor, epoch/revision,
normal writable controller, maintenance, owned references, installed producer/
policy/provider, byte integrity, capacity and original deadline checks remain
Store decisions. Existing manual authoring and original namespaces are unchanged.

Keep API version integer 1, canonical unpadded URL-safe encoding of the 32-byte
bearer, strict duplicate-member/depth rejection, request body at most 65536 bytes
and response body at most 1048576 bytes. Frames use the existing unsigned 32-bit
big-endian byte length. Endpoint parent is private 0700, socket 0600 and peer UID
must match the owned endpoint. Generation routes do not accept a host path,
endpoint, PID, callback, provider credential or installation policy from callers.

## Closed requests and responses

Each wrapper contains exactly api_version, operation, credential and the listed
additional fields. Unknown fields/version/operation refuse
unsupported_operation_or_fields before Authority or provider work. Input is the
exact native dictionary of its owning canonical ordered codec, not an alternate
schema. All choices and limits remain explicit; adapters add no defaults.

| Operation | Additional fields | Successful response member |
| --- | --- | --- |
| authoring_generation_options | none | authoring_generation_options |
| authoring_generation_prepare | input (GenerationPreparation) | authoring_generation_receipt |
| authoring_generation_status | authority_epoch, operation_id | authoring_generation |
| authoring_generation_start | input (GenerationAttempt) | authoring_generation_attempt_receipt |
| authoring_generation_attempt_status | authority_epoch, operation_id | authoring_generation_attempt |
| authoring_generation_cancel | authority_epoch, operation_id | authoring_generation |

Success is exactly api_version 1, outcome ok and the named member. Missing
actor-owned original is exactly api_version/outcome not_found. Refusal is exactly
api_version/outcome error/reason, with the existing bounded lowercase underscore
code string. Status epoch is positive signed-64 and ID uses the existing
1–128-byte ASCII Home grammar. No raw model input, source/draft bytes, credential,
host path, provider process or private monotonic coordinate is returned.
Candidate status includes the owning bounded assessment/handles; independently
reviewed fixture/source success remains separate. Owned draft/bundle bytes use
the existing explicit authoring-object-read/private output path.

## Actor-scoped installed policy metadata

**GO-01 — Describe native policy without granting export.** Authority and Store
add authoring_generation_options/2. The read requires current profile:manage,
normal active writable Store and a valid native policy installation. It works
without a producer, custody bytes or provider RPC. It creates no revision,
lease, preparation or provider call and renews no time. Maintenance does not
prevent this configuration read; actual new work still refuses maintenance.

The returned dictionary is exactly format wotex-home.generation-options@1,
principal_id, authority_epoch, store_revision and policies. Actor ID and current
epoch/revision come only from authenticated Store metadata. Policies are at most
32 rows, sorted uniquely by provider.id, only for that actor. Each row is exactly
provider (the existing four-field id/model_id/adapter_sha256/locality dictionary),
provider_sha256, policy_sha256, remote_export, passages, examples, limits and
provider_present. Ranges/examples/limits are the existing maximum permitted
selection metadata, never text or whole documents. Reconstruct each native policy
and its two digests before returning it. Another actor's rows are excluded.

provider_present is boolean true only when the exact installed native provider
capability reconstructs and its local PID is currently alive; this performs no
RPC. It is a point-in-time host declaration, not authentication of a remote
model, schema support, available capacity, source byte availability or permission
to export. No fallback or hidden policy is inserted. Empty installation returns
policies []; missing/dead provider leaves its policy row present/false. Obtain
the actual installed grammar/current basis through authoring-contract and submit
the explicit new preparation; neither this read nor cached metadata replaces
the Store's repeated guards. A nonwritable/retired/quarantine Store refuses this
current configuration read, while existing-only status keeps its owning rules.

## Mutation, uncertainty and recovery

**GO-02 — Forward originals once.** Preparation/start/cancel are durable mutations.
The adapter's ordinary five-second exchange deadline remains unchanged. Guard
timeout, caller loss, worker failure or a dropped reply is outcome_unknown; it
cannot prove a Store call rolled back or that a model stopped. Killing an
exchange worker does not restart, cancel or replay a provider attempt. A committed
Store-owned generation remains independent of a socket/CLI caller's lifetime.

Preparation/start repeat the exact original file through the owning Store codec;
immutable receipts resolve before current policy/provider/file recomputation.
Cancellation names the preparation, never a generated draft or successor attempt.
Status is an existing-only authenticated read, not a command to resume work.
Source/permission/policy/contract/epoch/deadline changes retain their owning typed
refusal or retired result. Generation_unavailable never selects another model.

After uncertain prepare, query authoring-generation-status with its original
epoch/ID and retain the exact preparation file. After uncertain start, query
authoring-generation-attempt-status with its original epoch/ID and retain the
exact attempt file. After uncertain cancel, query authoring-generation-status
for that preparation. Missing status does not authorize a new operation ID;
explicit exact retry still uses the same original and current credentials.
These socket operators add no SQL table, receipt encoding or schema migration.

## CLI inputs, response validation and outcomes

**GO-03 — Preserve exact files and typed replies.** New commands are:

```
authoring-generation-options
authoring-generation-prepare ORIGINAL_FILE
authoring-generation-status EPOCH OPERATION_ID
authoring-generation-start ORIGINAL_FILE
authoring-generation-attempt-status EPOCH OPERATION_ID
authoring-generation-cancel EPOCH OPERATION_ID
```

Retain --socket/--credential-file descriptor and same-user peer checks. Original
paths are absolute, at most 1024 bytes, private 0600 regular single-link files,
verified by descriptor before/after bounded reading. Preparation file is at most
131072 bytes of native JSON; attempt file at most 8192. These file ceilings allow
escaped native dictionaries without widening the canonical 32768/2048-byte
operation codecs or the 65536-byte socket request. Reject duplicate/deep JSON,
unknown/native fields and malformed/inconsistent original through the existing
Frame document decoder and exact owning encoder. The file's decoded values and
canonical operation identity are preserved; lexical JSON whitespace grants no
distinct original. Validation occurs before connecting. No upload, private
instruction command argument or provider credential file is added.

GenerationOperator is a pure representation/response checker shared by CLI and
future SDK work. It has no Store/provider/file port. Closed successful wrappers
must match the requested operation and member. Preparation/start receipts must
round-trip their exact owning codec and match input epoch/operation,
revision=expected_revision+1 and SHA of the canonical original. Preparation also
matches input provider/policy SHA; start matches preparation SHA and attempt.
Other digest fields remain checked metadata assertions, never export authority.

Preparation status/cancel is exactly original, state and cancellation_revision.
The original codec must validate and match requested epoch/ID. State is prepared,
expired, retired or cancelled; cancellation_revision is null except for cancelled,
when it is an integer above original revision and within signed-64. Cancel
success must be cancelled. No status is promoted into a new receipt disposition.

Attempt status is exactly original, result, result_revision and state. Original
must validate/match requested epoch/ID. Null result/revision permits only running,
unknown or cancelled. Nonnull result must round-trip GenerationAttempt's result
codec, have result_revision above original revision within signed-64, and state
equal result.disposition. Candidate metadata remains inert, even compatible.
Options must reconstruct its closed actor/provider/policy/range/limit grammar,
digests and ordering without a provider call or producer. Malformed/extra/float/
wrong-identity responses refuse invalid_generation_response; do not print the
unvalidated body. Error/not_found wrappers are closed too. Reason is 1..128 ASCII
bytes matching [a-z][a-z0-9_]* and is data, never converted to an atom or evaluated.

CLI status/options malformed reply is a read failure (exit 1). A malformed or lost
prepare/start/cancel reply is uncertain (exit 3), prints only the named recovery
command/epoch/ID and keeps the original file. Neither path prints bearer,
instruction, source text, raw provider body or unvalidated response. Valid ok,
definite error/not_found and bad usage retain existing exits 0/1/4/2. Generation
success means only the typed receipt/status above; it is not physical success.

## Acceptance and implementation entry

Use current schema37 Authority/Store, owned two-family source/fixture vectors,
scripted native GenServers and independently frozen ordered operation/receipt
vectors. Freeze options and wrapper shapes before code. Exercise a real private
Unix socket, unchanged current credentials and exact CLI private files; in-process
route checks alone do not establish transport behavior.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| GO-T1 | 01–03 | Actor-only sorted policy read, dead/absent provider/producer/files, exact independent policy SHA and unchanged revision/call count; credential/PID/text leak or inferred readiness fails. | SQLite/process/framed |
| GO-T2 | 02/03 | Both families through real socket and CLI prepare/start/status, manual-parity retained candidate and explicit repair; extra provider call, altered original or implicit activation fails. | Socket/SQLite |
| GO-T3 | 02/03 | Discard actual prepare/start/cancel replies, query original and exact retry after endpoint restart/withdrawal; wrong ID/renewed deadline/provider replay or false rollback claim fails. | Socket/process/restart |
| GO-T4 | 01–03 | Foreign/revoked/unprivileged actor, extra wrapper/native field, duplicate/deep/float body, changed original, invalid/symlink/hardlinked/wrong-mode/oversized file; no revision/provider mutation or raw log. | Framed/filesystem/SQLite |
| GO-T5 | 02/03 | Exchange worker/caller timeout and stopped Store, fake peers returning wrong receipt identity/hash/revision/member/state/result/order; mutating ambiguity exits3, reads exit1, response/credential remains unprinted. | Process/socket |

The installed provider/process authentication and confinement, immutable native
policy delivery, signed paired generation and native presentation remain separate
delivery gates. Default provider/policy installation stays empty and no external
model is contacted by these software fixtures. Full aggregate-pool milestones
remain owned by the attempt contract. Consumer operator policy belongs in Home;
the consumed producer APIs/pins and generic ExBooking/WoTEx contracts are unchanged.
