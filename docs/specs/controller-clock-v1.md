# Controller recovery clock v1 mechanism

Version: 0.1.3. Accepted mechanism authored before its consumer, 2026-10-07.
This private foreground mechanism supplies bounded current UTC for controller
transfer. It starts no device transport and cannot establish a clock issuer's
real accuracy merely from a signature or a successful software fixture.

## Explicit issuer custody

The receiving operator installs a canonical immutable 0400 policy outside the
arrived archive. Its parent is canonical private 0700 custody. There is no
default issuer, archive-derived key or automatic OS wall-clock confidence.
Policy is compact JSON with exactly nine ordered members:
`["wotex-home.controller-clock-policy.v1", issuer_id, public_key, generation,
procedure_ref, policy_digest, maximum_response_ms, maximum_age_ms,
maximum_error_ms]`. Public key is 32 Ed25519 bytes encoded as 43 canonical
unpadded URL-safe Base64 characters. IDs use the existing bounded Home ID
grammar; policy digest is 64 lowercase hexadecimal characters. Generation is
an integer from 1 through the signed 64-bit maximum. Response bound is 1–60,000
ms, maximum age is 1–600,000 ms and is greater than the response bound plus twice
the error bound. Error bound is an integer 0–1,000 ms. The procedure must actually
qualify the issuer's UTC error and the receiving monotonic clock's accumulated
error over that entire age. The policy records an explicit installed trust
decision; parsing it is no evidence that its qualification procedure passed.

## Original boot challenge

A private clock owner monitors the foreground operator, pins the original
owner/policy files and runtime, and creates one unpredictable boot challenge.
It publishes one immutable request in a new private child directory, under the
existing 64-entry receiving-root ceiling. Request JSON has eight ordered members:
`["wotex-home.controller-clock-request.v1", destination_owner_id, runtime_digest,
challenge_id, issuer_id, issuer_generation, policy_digest, issuer_policy_digest]`.
Issuer-policy digest is SHA-256 of the complete canonical installed policy
document, binding key, generation, procedure and all response/age/error bounds.
The owner and digest values use
the existing 64-character grammar and challenge uses the existing bounded ID
grammar. It retains original request-start monotonic time and a response deadline
derived from the current explicit policy. Files cannot reconstruct that state
after restart, and another caller cannot approve a response or renew a deadline.

Signed record JSON has ten ordered members:
`["wotex-home.controller-clock-record.v1", destination_owner_id, runtime_digest,
challenge_id, issuer_id, issuer_generation, policy_digest, issuer_policy_digest, procedure_ref,
observed_utc_ms]`. UTC is an integer from 0 through the signed 64-bit maximum
minus 600,000. The issuer signs the bytes
`"wotex-home.controller-clock-record.v1" + NUL + canonical_record_json` using
Ed25519. Package JSON is exactly
`["wotex-home.controller-clock-package.v1", record_array, signature]`, with a
64-byte signature encoded as 86 canonical unpadded URL-safe Base64 characters.
All request/policy/package documents are at most 4,096 bytes and re-encode
identically. Unsupported versions, extra members, noninteger numeric values,
noncanonical signatures and mismatched policy/scope are refused. Pure signature
verification is inert and cannot create clock confidence.

The trusted operator approves the exact original request digest and signed
response before its original local response deadline. Current owner, runtime,
policy identity/bytes and signature correspondence must still match. The owner
publishes the original response under immutable custody and records response
receipt monotonic time. Exact retry returns the original result without renewing
either deadline; a substituted response conflicts. Restart requires a new
challenge, and a response for an earlier challenge is unavailable.

## Conservative current UTC

Let `s` be original request-start monotonic time, `r` original response-receipt
monotonic time, `n` current monotonic time, `u` the signed observed UTC and `e`
the installed whole-horizon error bound. Current trusted UTC is the interval
`[u + (n-r) - e, u + (n-s) + e]`, because the signed observation happened during
the original request/response interval. Reject negative/overflowing intervals,
clock reversal, expired original request age, changed owner/policy/runtime or
replaced custody. A missing response or failed guard reports unknown confidence.
Neither OS UTC nor file timestamps enter this interval.

The private transfer review owner accepts this exact three-field trusted clock
shape: `confidence`, `earliest_utc_ms` and `latest_utc_ms`. Trusted point providers
retain their existing exact two-field shape with `now_utc_ms`. Preparation uses
the latest bound as issue time and earliest bound plus the original TTL as expiry,
refusing a nonpositive window. Every current signature/review window must contain
the entire interval, including both endpoints (expiry remains exclusive).
Original monotonic review expiry is independent and cannot be extended by time
status or another signed response. A wide response interval may delay usable
approval; it never becomes false millisecond precision.

Required software cases cover canonical bounds and signatures, every substituted
scope/policy field, old challenge replay, caller identity, unchanged original
deadline, missing/currently withdrawn custody, identical-byte replacement,
runtime change, response delay, interval arithmetic/overflow and both-endpoint
expiry. Real issuer UTC accuracy, host monotonic behavior, installed identity
and key custody remain separate qualification obligations.

The pure closed clock policy/request/record/package codec and inert signature
verifier are implemented. Nine tests cover exact canonical encodings and domain
separator, every substituted signed scope, complete timing-policy commitment,
wrong key/signature, integer and finite bounds, noncanonical JSON/Base64,
unsupported versions and historical signature audit without boot timing.
The separate private clock owner is now implemented. Eleven process tests cover
actual signed challenge custody and conservative interval arithmetic, operator
identity, unchanged original deadlines, conflicting/bad response, new-boot replay
refusal, runtime withdrawal, identical-byte owner/policy/request/response
replacement, real response/whole-age expiry, negative/overflow refusal, root and
missing-policy guards, redacted status, operator death and finite receiving-root
capacity. All twenty focused clock tests pass. UTC and issuer keys in these
cases are disposable synthetic evidence. No OS UTC source is trusted; transfer
interval consumption and command-line setup remain next.
