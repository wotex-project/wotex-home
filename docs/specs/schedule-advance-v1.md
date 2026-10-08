# Store-owned scheduled work advancement v1

Version: 0.1.0. Implemented schema-27 execution transitions, 2026-10-08.
WOH.04 owns temporal admission, WOH.14 the single writer and WOH.16 recovery.

The trusted internal Store call `advance_schedule` takes no bearer, principal,
operation ID, device timestamp or proposed effect. It selects retained
[scheduled requests](schedule-effects-v1.md) under their original author and
uses the Store's private clock and current qualification custody. It grants no
new authority and exposes no public polling route. An autonomous timer, host
supervision and composed runtime proof remain separate work. Physical dispatch
remains disabled by default.

One transaction first observes sticky authority-basis withdrawal and then
selects at most seventeen pending temporal requests in original consideration
order. It processes at most sixteen and returns `has_more` when another exists.
Only held, queued and claimed work participates. Handed work and terminal
receipts retain their uncertainty and original causal spend. An unchanged pass
does not advance a revision. A discovered withdrawal commits its existing
generation barrier even when it leaves no requests to advance.

A held request enters the existing ordinary absolute Boolean-power queue path
with the retained original principal, current review/manage/control permissions
and target grant. Maintenance, exact declarations/profile/invariant/runtime,
qualified clock scope, installed timezone, entire due/late window, operator
override, physical qualification, fresh reported baseline, effect-domain,
attempt and causal limits remain mandatory. Scheduled report freshness comes
from the exact observation/current/journal correspondence and Store-stamped
receipt boot and monotonic time. Caller device timestamps cannot supply it.
Old-boot, future, untimed, stale and synthetic reports cannot admit execution.

Each held admission uses a savepoint. A policy refusal rolls back any tentative
queue publication and causal reservation before terminally rejecting the held
request with `schedule_blocked:<reason>`. An actual SQL or integrity failure
rolls back the entire batch, including earlier closures. Queue, no-send closure,
claim and durable handoff repeat temporal guards and the exact reported baseline
after their SQL publication and before commit. Expiry or freshness loss during
publication therefore cannot leave a partial queue, claim, handoff or spend.

Queued and claimed requests whose retained temporal authority has expired or
changed are terminally rejected and their execution rows removed. Their causal
reservation stays spent. Old-boot held work is terminalized without acquiring
fresh-clock authority; same-owner UTC definition recovery remains separate from
the authority of an already consumed occurrence. A later fresh report, restored
grant, clock correction or repeated pass cannot reopen a closed coordinate.
Handed work is never treated as unsent merely because its window expires.

The immutable consideration and effect-operation receipt remain unchanged.
Subsequent normal request status records queueing or terminal refusal. There is
no schema migration, new root, cursor rewind, retry, refund or transport I/O in
this advancement mechanism. Exact archive and transfer provenance retains the
existing schema-27 validation and quarantine rules.

Software cases exercise actual private-clock queueing without a bearer,
old-boot report refusal despite fresh caller timestamps, queued/claimed expiry
with conserved spend, untouched handed work, old-boot held closure, a real
seventeen-request batch with rollback on its second closure, failure after causal
reservation, expiry during tentative admission, and independent post-publication
expiry/report-age loss at claim and handoff. No-send closure repeats the same
window and baseline guards. Original receipts and snapshot integrity are checked
after both successful and rolled-back transitions. These cases do not qualify
an installed host, physical light, clock source or target-storage power loss.

On 2026-10-08 the locked full Mix suite passed 1135 tests with zero failures;
four opt-in component cases were skipped. Real socket and foreground-host cases
ran. The affected transition suites passed 186 tests before the six additional
publication-race cases, whose focused run also passed. Warnings-as-errors
compilation, formatting, all 20 workspace contract metadata checks, all 19 staged
contract metadata checks, changed-document references and Git whitespace
validation passed. The existing support-file load-filter warning remains
unrelated to this mechanism.
