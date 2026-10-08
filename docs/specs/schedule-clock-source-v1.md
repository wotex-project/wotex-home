# Purpose-specific temporal clock source v1

Version: 0.1.2. Implemented inert signature codec and conservative lease
calculation, 2026-10-08. WOH.04 owns temporal confidence; host clock custody,
actual source qualification, Store generation fencing and dispatch integration
are separate obligations. No public clock-upload route or default trusted
source is established by this slice.

Compact canonical UTF-8 arrays use four distinct format names:
`wotex-home.schedule-clock-policy.v1`, `schedule-clock-request.v1`,
`schedule-clock-record.v1` and `schedule-clock-package.v1`, with the same
`wotex-home.` prefix on all four. Documents are at most 4096 bytes, arrays at
most sixteen members, nesting at most three and strings at most 128 bytes.
Objects, floats, negative encoded integers, noncanonical bytes and expanded
fields refuse. Binary public keys, nonces and signatures use canonical unpadded
base64url for exactly 32, 32 and 64 decoded bytes.

Policy's thirteen ordered fields are source ID, issuer ID, public key, issuer
generation, procedure reference, qualification digest, purpose-specific runtime
digest, maximum response milliseconds, maximum age milliseconds, maximum UTC
error milliseconds, monotonic drift ppm, maximum detected discontinuity
milliseconds and `monotonic_policy: invalidate_on_discontinuity`. IDs and
digests retain their existing closed forms. Generations are positive signed-64
integers. Response is 1–60000 ms; total age is 1–600000 ms and strictly greater
than response plus twice the UTC error. Error and discontinuity are 0–1000 ms;
drift is 0–1000 ppm. The qualification digest is an original host/source
assumption, not a parser's newly minted evidence.

Request's twelve ordered fields are deployment digest, owner digest, authority
epoch, Store boot epoch, clock generation, runtime digest, random original
32-byte challenge nonce, source ID, issuer ID, issuer generation, qualification
digest and SHA-256 of the complete canonical policy document. A signed record
repeats those fields and adds procedure reference and observed UTC milliseconds.
Observed UTC follows the schedule's supported 1970–9999 range with required
headroom. The package carries its format, complete ordered record array and
signature. The signing payload is the exact record format name, one zero byte
and the canonical record document. Verification repeats all request fields and
policy joins before Ed25519 verification. Recovery clock documents and domains
are independently unusable for temporal qualification.

The pure lease binds exact request/policy/package bytes and original host-owned
start/receipt monotonic coordinates. Receipt must precede the original response
deadline; status cannot extend either deadline. For response elapsed `r`, UTC
error plus permitted undetected discontinuity `e`, drift `p` and observed instant `u`, the sample at receipt is
`[u - e - ceil(r*p/1000000), u + r + e + ceil(r*p/1000000)]`. Future elapsed
time widens both endpoints using the existing
[clock sample](schedule-source-v1.md) integer-ceiling drift calculation. Sample
age is reduced by original response elapsed; the complete lease expires
strictly at start plus policy age. UTC underflow/overflow refuses establishment.

Current calculation rebuilds the entire lease from its original signatures,
timing and policy, checks exact deployment/owner/epoch/boot/generation/runtime
scope, then advances its original sample. Altering cached bounds or timing,
changing scope, rollback, expiry or malformed fields refuse. A host-owned
monotonic-versus-OS-wall delta comparison can withdraw continuity when rollback,
sleep or correction exceeds the declared detection allowance plus drift. A
passing comparison supplies only a Boolean; OS wall values never establish
trusted UTC. Custody, actual monotonic/source qualification and an owner's
irreversible withdrawal after a detected discontinuity still belong to the
host integration, not these pure functions.

The discontinuity allowance is included in both uncertainty endpoints and is
checked cumulatively against the original wall/monotonic anchor by the host
owner. Updating a rolling observation cannot conceal multiple small changes
whose cumulative offset exceeds the declared allowance. Exact private custody
and Store boot ownership are implemented in the
[temporal clock owner](schedule-clock-owner-v1.md); durable occurrence and
dispatch fencing remain separate work.

Ten focused cases validate four independently generated Python cryptography
Ed25519 records and sixteen integer uncertainty vectors, every signed scope
substitution, full timing-policy commitments, exact input bounds, malformed
framing, cross-purpose refusal, response/age deadlines, sample tampering,
ownership/restart refusal, withdrawal-only wall comparisons and UTC limits.
Combined clock-record/recovery-codec regressions pass 27 tests. Synthetic keys,
identity digests and UTC values establish software correspondence only.
