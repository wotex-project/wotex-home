# Controller-owned temporal delivery v1

Version: 0.1.2. Implemented opt-in software owner, 2026-10-09.
WOH.04 owns temporal admission, WOH.14 durable execution and WOH.08 Host lifecycle.

One `Schedules.Delivery` process considers current admitted work through
Authority without a connected client. The Store supplies a caller-bound,
one-use snapshot; calculation runs outside its writer and publication repeats
the current guards. A failed or abandoned calculation cannot retain a poll
slot as authority. The owner holds no bearer, SQLite handle, reports, device
identity or private routing. Its retained state contains Authority references,
bounded delivery options, scan revisions, a cleanup flag and diagnostic result
names.

The trusted interval is 100–1,000 ms, defaulting to 100 ms. A next timer is armed
only after the previous pass and at most one delivery finish. Delayed work does
not produce catch-up timer bursts. An actual newly considered held occurrence
is delivered directly through its retained effect principal/epoch/operation,
before scanning older pending work. The owner retains no occurrence identity or
report between ticks, and this priority does not move the cleanup cursor or
finite revision cutoff.

After that attempt, the next tick skips new consideration and performs one
ordinary pending-work scan step. A bounded Boolean flag reserves this cleanup
step even when fresh delivery fails. New arrivals therefore cannot indefinitely
defer older work or extend the current scan. A coordinate becoming due during
cleanup is considered on the following consideration tick under the then-current
Store clock and missed-work policy; the owner never extends its late window.
Pending selection uses original creation revisions with a finite Store revision
cutoff. Store occurrence cursors and current due/late windows determine work,
not the timer or adapter clock. An inactive schedule remains idle without new
history. Trusted dispatch must be enabled before consideration or capture.

Delivery reuses [private scheduled power delivery](scheduled-power-delivery-v1.md).
Held work obtains a fresh scoped report before advancement. Queued work retains
its sealed baseline and producer continuity. Every command still requires
current temporal window, original author/grants, resource/profile qualification,
effect-domain serialization, causal and attempt guards at claim and committed
handoff. ACK remains intermediate; independent readback supplies the reported
outcome. Claimed, handed-off, observed, contradicted and uncertain work is not
selected for a second exchange, including after owner restart.

A failed delivery asks the Store to close only an actual unsent scheduled
original. Rejection, unsent-row removal and history commit together; spend is
never refunded. A claim/handoff raced by another worker cannot be recalled.
Receipt uncertainty and the existing monitored worker lifecycle remain the
execution owner's responsibility. Clock loss blocks an occurrence; returning
qualified UTC time can permit future interval ticks without reviving that
rejected original. Countdown continuity loss retains its existing sticky
withdrawal semantics.

Host starts this owner only when both trusted `:schedule_delivery_enabled` and
`:lifx_power_dispatch_enabled` settings are true. Both default to false. The
restart order is Store, profile custody/reviews, review gate, optional capture,
optional temporal owner, optional explicit consumer, power supervisor and API.
Losing capture or the temporal owner stops downstream workers. Store failure
restarts the complete dependent tree. Starting the owner creates no installed
clock custody, public control route, physical qualification or autonomous
admission proof. Native background-controller registration remains independent.

The scope remains one current admitted Boolean-power schedule. Multi-schedule
composition, qualified autonomous admission, installed clock and sleep behavior
remain obligations. [Private power routing](power-routing-budget-v1.md) now
uses a closed 500-ms owner budget. The complete flow still misses the source
grammar's minimum one-second late window because the remaining guards consume
substantial time. A moving-clock default-window UDP case passes, and exact
minimum-window expiry refuses without a set. Authorized preparation or more
efficient guarded composition and positive minimum-window latency evidence
remain required; production never widens the original occurrence window.
The delivered app must be rebuilt from this committed source before packaging
evidence can cover the new Host child.

On 2026-10-08 fresh-source checks passed seven actual Authority/SQLite/scripted
owner cases, fourteen Host cases including real private socket lifecycle, and
52 occurrence, clock-owner and consideration cases. Owner cases cover timer
creation without a client, matching and missing readback, restart non-replay,
failed capture closure, expiry during capture, disabled/inactive owners,
closed options and clock loss followed by recovery. Host cases verify both
flags and downstream worker shutdown while retaining Store. Real socket tests
remained enabled; no socket-free option was used. Formatting, warnings-as-errors
compilation, contract metadata, changed references and Git whitespace checks
passed. An invalid-start test initially needed exit trapping, and the interval
clock-loss expectation was corrected to preserve future-tick recovery; the
final seven-case run passed. No installed clock or physical device was qualified.

On 2026-10-09 all thirteen actual Authority/SQLite/scripted owner cases passed,
including fresh delivery ahead of sixteen expired roots, observed/uncertain
restart non-replay, a new arrival during the reserved cleanup step, preservation
of its finite cursor/cutoff, complete backlog closure, unavailable capture,
journal-failure rollback and a competing claim obtained during fresh capture.
Every retained original and causal reservation remains accounted for, with
complete snapshot integrity checked. Fourteen Host cases and both independent
UDP window cases passed; default moving-window handoff was observed at 2,144 ms,
and exact one-second expiry refused without a set. Real sockets remained enabled.

An early failure check counted an unrelated rejected explicit request; it now
selects the actual fresh temporal root. Timer checks use elapsed-time deadlines.
A private read-only observer measured steady cleanup progress at about one
root per second; the full sixteen-root scan needs more than fifteen seconds
under these fixture guards and uses a bounded thirty-second test deadline.
This establishes finite software cleanup, not installed latency or
minimum-window usability. Formatting, warnings-as-errors compilation, contract
metadata, changed-document references and Git whitespace checks passed.
