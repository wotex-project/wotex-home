# Transaction-bounded runtime inventories v1

Version: 0.1.1. Implemented software boundary, 2026-10-09.
WOH.07 owns runtime correspondence and WOH.14 owns publication and withdrawal.

One guarded Store execution transaction may reuse a complete compiled Home/UDP
inventory while preparing its decision. The fixed closure is `wotex_home` and
`wotex_udp`; existing application/module/artifact limits, complete SHA-256 bytes,
loaded/file consistency, old-code refusal and digest domains remain unchanged.
A fresh complete inventory opens the invocation. Subset requests retain their
original application order and domain commitments. Other application requests
use the ordinary independent reader. No retained receipt can populate this scope.

Active one-use [poll preparation](schedule-poll-v1.md) uses the same scope
inside its own Store transaction. A current lifecycle-head/generation query
selects whether preparation needs the inventory; it proves no permission,
clock or effect. The writer still repeats complete history, current activation,
author, artifact, cursor, clock and timezone. An inactive generation follows
the ordinary unscoped path and can return only inactive status, with no poll
reference. It needs no runtime inventory for that negative result.

Preparation closes the fresh complete comparison before releasing its
savepoint. Only a committed successful snapshot can become a caller-bound
in-memory poll slot. Observed runtime loss retains withdrawal against the exact
current generation, restores tentative changes and returns a refusal with no
slot or occurrence. SQL failure rolls back the barrier and disables writes.
The scope never accompanies the prepared basis; eventual consumption repeats
the independent current guards, final window and original five-second lifetime.

The Store validates complete authority history and creates its existing power
savepoint before opening the scope. Every SQL query, original author/epoch/grant,
declaration, profile custody, invariant, override, clock, report, capacity,
serialization and causal check still executes. The scope caches compiled-runtime
identity only. It caches no rows, clock reading, permission or effect decision.

After decision preparation and enclosing history validation, a fresh complete
inventory must equal the opening inventory. This closes reuse before the
existing final execution guards. Those guards independently read current
artifacts, authority and the Store clock as before; time consumed by closing
the scope is included in their actual half-open occurrence-window check.
There is no code inventory or positive result carried between queue, claim,
handoff, reply, retry or restart. Nested scopes refuse. Exceptions, throws and
catchable exits remove the invocation context. Temporary readers and parsed
checksum reuse retain their separately bounded [reader contract](runtime-artifact-readers-v1.md).

## Observed loss and original phases

An unavailable, changed or inconsistent closing runtime cannot publish the
prepared positive decision. The internal result includes that unpublished
decision solely for Store refusal accounting; no adapter or worker receives it.
The Store retains a withdrawal for the exact current schedule generation,
captures its actual original, restores the power savepoint and rebuilds the
withdrawal against the restored phases. Returning files cannot revive a loss
already observed by this invocation. A previously fenced generation is never
fenced again in place of a successor. SQL/corruption failures remain failures.

Advancement returns actual retained receipts after restoration, rather than
tentative queued or no-send values. New tentative admission leaves the original
root unspent; committed queue/claim spend remains spent. A tentative handoff
cannot manufacture an uncertain outcome after restoration. Previously committed
handoffs retain their existing uncertainty and non-replay semantics. Failure
while publishing or rebuilding withdrawal rolls back the complete transaction
and disables the writer. This uses the existing schema, identities, journal
links and [withdrawal mechanism](power-commit-v1.md).

These checks assume the trusted release/update boundary. They do not make a
live code upgrade atomic, attest native libraries/OS state or defend a hostile
VM. Maintenance and controller-stop barriers remain required for updates.
No admission profile, temporal proof scope or physical-dispatch default changes.

## Minimum-window probe

The independent moving-clock UDP probe exercises actual Authority, Store,
capture, queue, claim, committed handoff and readback for a one-second source.
It uses synthetic signed device and clock evidence. Run it explicitly on a
controller test environment with the selected locked dependencies:

```sh
WOTEX_HOME_GIT_DEPS=1 WOTEX_HOME_MINIMUM_WINDOW_PROBE=1 EX_MAUDE_BUILD_CNODE=0 \
  mix test test/wotex_home/durable_enrollment_test.exs --only minimum_window_probe
```

This performance probe is opt-in because it asserts real elapsed time rather
than deterministic semantics. A slow invocation fails the probe; production
still skips an expired occurrence without widening its window. Ordinary CI
retains the default-window delivery and exact one-second expiry/no-set cases.
An early fresh-source prototype reached the peer at 853 ms. Five subsequent
fresh-Mix one-second runs of the implementation produced two positive handoffs
at 995 and 982 ms and three failures: final guard clock reads reached 1,003,
1,017 and 1,009 ms with no set packet. This is insufficient minimum-window
margin or reliability. Default-window delivery reached the peer at 966 ms in
the separate 132-case execution/delivery run. These are local software samples,
not installed-host, minimum-window load, clock/sleep or physical qualification.
Supported host/resource cohorts need their own repeated latency evidence;
further minimum-window preparation work remains required.

After extending reuse to active poll preparation, five local fresh-Mix probes
all reached the independent peer within one second: 901, 890, 896, 884 and
901 ms. This removes the repeatedly observed miss in that local sequence;
it does not qualify supported host/resource loads, installed clocks or
autonomous/composed admission. The earlier failed runs remain historical
evidence. No window, freshness bound or routing deadline was widened.

Pure checks cover complete identity, subset ordering, nested refusal, unwind
cleanup, changed full bytes with unchanged code checksum, missing artifacts,
loaded drift, application metadata and independent reads after scope closure.
Actual SQLite cases cover queue/claim/handoff byte drift, enclosing current
guards, original spend, immutable receipts, restored custody and withdrawal
publication/replay faults. Autonomous/composed admission and physical gates
remain separately required.

On 2026-10-09, all 132 selected actual SQLite, restored-withdrawal,
original-specific, composed report/admission, delivery and owner cases passed
in 157.6 seconds, including both mandatory independent UDP window cases.
Real sockets remained enabled. Three byte-drift cases specifically change
complete retained bytes without changing the BEAM code checksum at queue,
claim and handoff, retain one withdrawal, preserve original spend and validate
complete snapshot integrity. The separate pure affected run passed 35 cases.
An initial isolated-VM test command supplied its second code path as a script;
separate `-pa` arguments fixed it. The first new queue fixture called a
handoff-only token helper; correcting that setup made the selected matrix pass.
Neither harness correction changed production guards or deadlines.

The nine-suite domain run then passed all 196 artifact, request, explicit rule
activation, temporal admission/lifecycle, Store, causal-root, supervised power
execution and clock-owner cases in 54.3 seconds. Together with the selected
enrollment run, 328 distinct cases passed. Formatting, warnings-as-errors
compilation, all twenty working contract metadata checks, 69 changed-document
local references and Git whitespace checks passed. No socket-free exclusion
was used. Native presentation, packaging and physical qualification are
unchanged. The opt-in performance failures above remain unresolved evidence,
rather than passing semantic or installed-host acceptance cases.

Active poll preparation subsequently passed all 19 selected preparation,
owner and mandatory UDP cases in 56.9 seconds; default-window handoff was
observed at 920 ms. Four added actual Store/SQLite cases cover missing opening
custody and changed complete closing bytes with unchanged loaded code, with
successful withdrawal and injected publication failure for each. Returning
custody leaves no reusable poll, consideration, scheduled root or effect;
successful barriers remain suspended and failed barriers restore the original
revision while stopping writes. Inactive polling also returns no slot while
the retained runtime file is missing. Every case checks complete snapshot
integrity and original activation identity.

The five-suite occurrence, profile archive, temporal admission/lifecycle and
clock-owner run passed all 102 cases in 90.5 seconds, for 121 distinct affected
cases with the selected enrollment run. Real sockets remained enabled; no
socket-free flag was used. The first new test compilation warned about a
known disjoint literal comparison in generated fixtures; compile-time branch
selection removed that warning without changing production behavior.

After adding inactive-path selection, three final-source one-second probes
also passed, at 939, 906 and 893 ms. Thus all eight preparation-scope attempts
passed locally, with 884–939-ms handoffs; they exercise this synthetic interval
source, not every calendar/countdown or supported host/resource cohort.
Formatting, warnings-as-errors compilation, all twenty working contract
metadata checks, 58 changed-document local references and Git whitespace
checks passed. No dependency or physical-dispatch setting changed.
