# Native certificate clock owner evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1 with Elixir 1.19.6 /
OTP 28.5.0.6 and Swift 6.4, targeting macOS 15 with warnings rejected.
The [owning contract](../specs/native-certificate-clock-v1.md) preceded code in
`832c558`; `b474c84` and `bba0562` refined custody, retirement and timestamped
projection before implementation. Owner implementation is `a0dd67f`, following
the [inert foundation](native-certificate-clock-2026-10.md) in `e0fabc7`.
This is partial NC-T2/T3 software evidence. Shared Setup/driver composition and
positive installed signing/source/clock qualification remain open.

## Implemented boundary

The parameterless production owner can install its private volatile generation
only after actual protected-self signing and fixed account custody. It has no
runtime, path, clock or successful backend constructor seam. Begin and Import
retain one original five-second continuous deadline. The process-global operation
slot survives timeout/cancellation until its actual worker returns; a late result
cannot install a generation or confidence. Current sampling has a separate
per-owner nonblocking slot held through actual signing checks, with source file
and timing checks between current runtime validations. Periodic checks perform
source timing/custody work without scheduling more signing workers.

File mechanics retain descriptor and named-path seals, exact policy/request/
response bytes, owner, complete mode, single-link inode and nanosecond file times.
Directory/ancestor seals retain inode, ownership, mode and ACL without treating
ordinary unrelated entry timestamps as identity. Reads reject symlinks, FIFOs,
hard links, mutation ACLs and unsafe custody. Publication is immutable, bounded
and synchronized; an uncertain post-publication check cannot create confidence.

The volatile generation preserves the original request instant and accepted
answer. Wall time is a rolling and cumulative continuity veto, never UTC evidence.
Withdrawal cannot be reversed by restoring files or settings. A source-aware TLS
clock recomputes a current projection at each use, retains its observation instant
and advances bounds with outward rounding/drift after subsequent validation work.
Its expiry never exceeds the original source age or fifteen seconds. Existing
TLS chain, SAN, full-leaf pin, system-time validity and framing checks remain.

## Executed checks and limits

`mix woh.native.certificate.clock.owner.smoke` compiled all **84 non-main
production Swift sources** and the focused fixture, then passed actual private
file custody, volatile generation/withdrawal, original deadlines, retiring
capacity and actual unsigned production refusal. Its compiler, executable,
cache and private files live in one temporary root removed by `after` on success
or failure.

Positive file/generation cases use a separate unsealed mechanics seam and an
explicit disposable CryptoKit signing seed matching a frozen foundation public
key. Those helpers cannot be installed in the private production owner. Cases
cover fresh nonce requests, canonical request bytes, immutable accepted copies,
identical answer retry with declining original age, stale-digest refusal before
input I/O, changed accepted answer conflict, invalid live-answer consumption,
old-answer/fresh-challenge refusal and runtime mismatch before publication.

Replacement checks cover identical-byte policy/request/response inodes, root
and ancestor directories, mode changes, hard links and symlinks. A mutation ACL
installed through the actual platform `chmod`, a FIFO without a writer and a
contending root `flock` refuse. Restoring the original mode cannot reactivate a
withdrawn generation. Injected failure after immutable response publication
leaves historical bytes but no usable sample. Capacity at 64 retained children
refuses without deleting history. Strict response/age expiry, cumulative tiny
wall corrections, rollback and explicit withdrawal refuse; previously returned
fixture TLS clocks also refuse after withdrawal. A delayed source callback
checks that time after projection observation is included in delivered bounds.

Held actual job workers return timeout/cancellation to the caller while their
global slot remains occupied. Another production owner's Begin refuses capacity
until actual retirement; late values are discarded. Foreign invalidation and
retirement tokens cannot revoke or free the active slot. A pre-cancelled job
never enters its worker. These are actual job/gate checks with controlled work,
not an installed blocked Security-framework call or timer/wake qualification.

The actual parameterless owner starts unavailable, and repeated unsigned Begin
refuses through its real protected-self gate before account files. No fixture
backend can turn that refusal into success. Successful installed ownership,
current platform sampling contention, timer/wake withdrawal and actual issuer
UTC/elapsed accuracy require their own installed evidence.

Regression commands also passed:

- `mix woh.native.certificate.clock.smoke`: six independent OpenSSL signatures,
  18 interval vectors, 66 continuity vectors and closed document/scope/timing
  refusals.
- `mix woh.native.controller.tls.smoke`: 35 independent trust, frame, deadline,
  cancellation, installation identity and real Authority pairing/delivery cases.
- `mix format --check-formatted`, `mix compile --warnings-as-errors` and
  `git diff --check`.

The catalogue checker passed 22 working contracts and 21 contracts exported
from the staged index. All 363 staged Markdown local references resolved.
Only the owning catalogue versions were staged; unrelated research stayed out
of these commits. The export's temporary tree was removed after checking.

No Keychain credential, Home Store, issuer or device is accessed by the owner
fixture. No full application suite, Dialyzer, release, firmware or physical
campaign was run. The shared application still has no default producer until
its Setup/driver composition is implemented. Dependency locks, sibling source
revisions, schema and default-disabled physical dispatch are unchanged.

## Artifact cleanup

All final focused command handles terminated. Private clock/compiler/cache roots
and the completed moduledoc agent scratch were removed; `_build/native` is empty.
The small locked incremental Mix/dependency caches are retained. Thirty empty
older Home scratch trees and fourteen obsolete dependency-symlink-only scratch
trees were also removed after inspection. No Docker image or container was
created by this slice. A read-only Docker inventory found no containers; existing
images, build cache and other projects' database volumes were preserved. The
filesystem had approximately 28 GiB free at the final inventory.
