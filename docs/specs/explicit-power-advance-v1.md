# Original explicit power advancement v1

Version: 0.1.1. Implemented trusted Store boundary, 2026-10-08.
WOH.14 owns execution; WOH.03 owns the qualified device path.

`Authority.advance_explicit_power` addresses one retained principal, authority
epoch and operation. The Store requires its original `explicit_request` causal
root with a positive creation revision and the original author's current
permissions. It neither accepts nor issues an operator bearer. A different
principal or epoch cannot borrow the request. Scheduled and migrated legacy
roots return `not_explicit_request`; absent originals return `not_found`.
This is an internal authority operation, with no public API or CLI route.

Advancement composes the same direct-power admission writer used by
authenticated admission. Maintenance, current permissions and target grants,
declaration, resource, profile, exact qualification custody, fresh report,
effect-domain serialization, invariant, override, rule provenance, generation,
causal reservation and attempt limits remain mandatory. Explicit rule
invocations retain their existing rule guards. Adapter boot/time inputs keep
the ordinary explicit-report semantics; they do not establish a Store clock or
temporal confidence.

A fresh matching report can close the original as `already_reported_no_send`
without control qualification. It creates no execution row or causal spend.
A required effect can queue only with current qualification. The enclosing
Store guard is derived from the actual receipt and repeats its explicit
origin and complete current author/basis after publication and history checks.
A final policy refusal restores tentative queue or no-send work. SQL failures
roll back the whole transaction and disable writes; restart validates history
before accepting new work. Current schedule withdrawal still uses the existing
savepoint/barrier rules. No spent root is refunded.

An unchanged queued retry returns its original receipt without reserving again.
Credential rotation preserves the existing withdrawal of outstanding work;
this internal path cannot revive it. Author/grant withdrawal and cancellation
also remain terminal for the affected original. Restart preserves queue and
receipt identity but does not itself perform a device effect.

Software validation uses actual Authority/Store calls and SQLite transactions,
including credential withdrawal, original lookup and restart; wrong identity,
epoch and malformed inputs; stale, future and wrong-boot reports; qualification
custody loss; explicit-rule overrides; scheduled-root separation; actual
schema-13 migration; final author and grant loss at queue/no-send publication;
and two aborted queue publication boundaries. Synthetic signed qualification
fixtures establish these guard checks only. They do not qualify hardware,
installed custody, storage power loss or a host delivery loop.

On 2026-10-08 the 19 focused cases passed, then all 78 selected direct-power
and causal-history cases passed with the focused cases included. The separate
authority, request, maintenance and power-executor suites passed 80 tests.
Each run freshly compiled Home with the locked dependencies. The broader
guard run initially refused an overlong macOS temporary socket path; its
successful rerun used a short private temporary directory and included the
real Unix socket case. No socket-free exclusion was used. Formatting,
warnings-as-errors compilation, contract metadata and Git whitespace checks
passed. These are software checks within the stated scope.

This boundary is a prerequisite for controller-owned delivery of explicit
requests. It selects no pending work, installs no timer, opens no transport and
sends no packet. The separate
[controller delivery boundary](explicit-power-delivery-v1.md) now supplies
Store-derived selection, fresh enrolled routing and report capture, supervised
delivery and the existing committed handoff/readback path. Physical dispatch
remains disabled by default; installed and physical qualification remain open.
