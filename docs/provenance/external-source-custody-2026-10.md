# External source custody software evidence

The [owning custody contract](../specs/external-source-custody-v1.md) was
committed in f8ae7dd, refined for retirement/caller semantics in 56e2f95 and
publisher loss in 08c95a7, then implemented in 9b7863a. It retains checked
host source assertions and transient original-scoped snapshot leases. It has
no Store connection, bearer, transport, report publication or physical authority.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- The exact three-archive `--profile-consumer` command recorded in
  [trust evidence](external-trust-2026-10.md) passed 59 cases in 9.4 seconds.
  The consumer freshly compiles 30 selected Home modules with warnings as
  errors. Archive and consumer-lock identities are unchanged.
- `mise exec -- mix test` selecting external_source_owner_test,
  external_value_unavailable_test and portable_profile_review_session_test
  passed 11 cases in 0.5 seconds. These selected cases exercise process
  custody and cold optional-producer refusal, not sockets or physical I/O.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No whole-app/native suite, Dialyzer,
  packaging, dependency update or physical qualification was run.

Source-owner module SHA-256 is
4b4d3b1c1c1df3a057b0755371908ca30cbad361823c857e5304810ac68521aa;
archive custody-case source SHA-256 is
3724e170bb2240f28d63e7025406460c4c40561accfb41adaea308ca98bf7f43.

Twelve process cases extend the previous 47 archive cases. Actual checked
sources cover publish, original hold/replay, private status, checkout, stable
deadline/guard, caller ownership, finish and cancellation. Exact republish
preserves a checkout. Replacement invalidates pending and checked-out leases;
caller death drops the private snapshot/monitor and releases capacity. Expiry
works through calls and through the actual periodic timer without a status
request. Publisher death terminates the actual owner. Restart changes its
incarnation and cannot revive an old token after identical republish.

Capacity checks execute the inclusive actual input-byte boundary, 32 checked
sources, concurrent lease refusal and 1024 retained retired originals. Refused
publication/generation changes preserve current sources and lease originals;
scope replay remains available at capacity. Foreign publisher, wrong principal,
conflicting original, malformed options/ref/native data and invalid registration
name refuse. Removing the actual public core JSON module leaves metadata,
checkout and retirement available while new publication refuses unavailable.
No private stable identity, capture or consumer body enters the safe summary.

The first harness attempt failed on a test syntax typo before assertions.
Cold configuration checks found that invalid options reached a linked process;
they now refuse before linking. Publisher monitoring initially caused the
default supervisor to attempt dead-PID restarts at teardown. The explicitly
temporary child now requires a new publisher installation. The timer fixture
was corrected to allow the declared periodic interval and retain the separate
publisher monitor while checking checkout-monitor removal. All final cases passed.

This process is not yet installed in Host or joined to a durable external target
transition. The next owning specification must freeze selection/enrollment/current
encodings, grants/invalidation, historical integrity and recovery before code.
Snapshot custody establishes software lifetime/correspondence, not physical
source authentication, qualified reads or observation freshness. Existing
generic current use remains fail-closed; all commits remain local on main.
