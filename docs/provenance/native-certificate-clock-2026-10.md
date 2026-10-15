# Native certificate clock foundation evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1 with Elixir 1.19.6 /
OTP 28.5.0.6 and Swift 6.4, targeting macOS 15 with warnings rejected.
The [owning clock contract](../specs/native-certificate-clock-v1.md) was committed
before code in `832c558`; inert implementation/acceptance is `e0fabc7`.
This is NC-T1 and isolated NC-03 arithmetic evidence. Actual source ownership,
permanent withdrawal, TLS producer and Setup integration remain unimplemented.

## Executed boundary

`mix woh.native.certificate.clock.smoke` compiles three Swift sources: the
existing canonical pairing-array helper, the actual clock source codec/lease
and its independent fixture. The final run passed **six independent signatures,
18 interval vectors and 66 continuity vectors**, plus closed-document,
scope/signature and strict original response/age refusals.

The committed Python generator uses the system OpenSSL 4.0.3 Ed25519 signer,
without importing the Swift codec, runtime or arithmetic. Its fixed disposable
fixture seeds do not represent any installed issuer key. Only public policy,
request/record/signature documents and independent expected integer results are
retained. Running the generator again in a private temporary directory produced
byte-identical fixture bytes: SHA-256
`d480f6016d57842fa59e140ee77ebc3160e1fbe2344effacc894b0c1c6c80d9d`.

Vectors cover zero/error/drift bounds, delayed response, upper UTC headroom,
underflow, strict age/response expiry, original monotonic reversal and
ceiling-rounded drift. UTC endpoints include installed error/discontinuity and
the fixed two-ms sampling allowance exactly once. Signature verification joins
the complete policy digest, original runtime/challenge and purpose-specific
record before pure arithmetic. Mutations cover every policy/request/record
member, wrong key/signature, changed role/domain, extra fields, integer bounds,
noncanonical JSON/base64, booleans/nulls/floats/negative native values, depth,
array/string/document ceilings and invalid runtime-fact shapes. Errors are
closed codes and retain no input documents.

Continuity vectors compare elapsed wall/continuous differences only; they
establish no UTC. A rolling two-ms correction can pass while an independently
checked cumulative delta refuses. A future actual owner must retain and compare
both anchors and make withdrawal irreversible. These pure Booleans cannot
substitute for that state machine, file custody or actual signing.

The first fixture run failed because a mutation incorrectly expected positive
`Int64.max` issuer generation to refuse. The contract allows the entire positive
signed-64 range. The corrected negative uses zero and a separate positive
round-trip checks the maximum; the final run passes. No contract bound was
relaxed to satisfy the fixture.

## Validation and remaining work

Root formatting, warnings-as-errors compilation and Git whitespace checks pass.
The documentation-only task-header patch preserves every non-documentation byte
and one following blank line; its AST/reference/format checks pass. The
catalogue checker passes 22 working contracts and all 21 contracts exported
from the staged index. All 255 staged Markdown local targets exist. Unrelated
research changes remain excluded from these commits.

The production driver still has no default certificate-clock producer. No new
file owner, issuer transport, signing success seam, Keychain operation, Store,
TLS request, mutable clock confidence or Setup action is introduced by this
foundation. NC-T2–T5 require the actual owner/concurrency/current-source and
installed source/host evidence, as ordered by the contract. Existing physical
dispatch defaults, schema, API permissions, dependency locks and sibling source
revisions are unchanged. No full suite, Dialyzer, release, firmware or physical
campaign was run for this pure addition.

The native task removes its private compiler/cache/executable root on both
success and failure. The independent generator and regeneration check remove
their temporary key/message/output directories. The completed documentation
agent scratch is removed after patch application. No PNG preview, Docker image
or container was produced. Shared dependency caches are retained for focused
incremental checks; unrelated work and Docker volumes are preserved.

## CI state inspected during this slice

[Run 38587021806](https://github.com/wotex-project/wotex-home/actions/runs/38587021806)
remains the latest completed hosted run and tested older source `3449ac76`.
Its core/Nerves issues already have [focused local remediation](current-host-ci-remediation-2026-10.md);
current source and paired recovery were subsequently extended and checked by
their owning slices. No new hosted/macOS 15 success is claimed from this audit.
No ref was pushed or workflow dispatched; the user owns every push.

## Subsequent owner stage

The later [owner evidence](native-certificate-clock-owner-2026-10.md) records
fixed-file/generation and bounded retirement implementation after this foundation.
Its unsealed helper checks and actual unsigned refusal do not establish installed
positive source ownership or issuer accuracy. The statements above describe
the foundation commit's boundary, rather than the later implementation status.
