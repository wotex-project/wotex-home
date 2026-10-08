# Controller-owned temporal delivery v1

Version: 0.1.0. Implemented opt-in software owner, 2026-10-08.
WOH.04 owns temporal admission, WOH.14 durable execution and WOH.08 Host lifecycle.

One `Schedules.Delivery` process considers current admitted work through
Authority without a connected client. The Store supplies a caller-bound,
one-use snapshot; calculation runs outside its writer and publication repeats
the current guards. A failed or abandoned calculation cannot retain a poll
slot as authority. The owner holds no bearer, SQLite handle, reports, device
identity or private routing. Its retained state contains Authority references,
bounded delivery options, scan revisions and diagnostic result names.

The trusted interval is 100–1,000 ms, defaulting to 100 ms. A next timer is armed
only after the previous poll and at most one delivery finish. Delayed work does
not produce catch-up timer bursts. Selection uses original creation revisions
with a finite Store revision cutoff; newly arriving work cannot extend that
scan. Store occurrence cursors and current due/late windows determine work,
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
remain obligations. Current private routing discovery uses a two-second
window, which can outlast the source grammar's minimum one-second late window.
The current complete-window checks refuse expired work rather than widening
that contract. Faster bounded routing or an authorized preparation design and
corresponding latency evidence remain required before that minimum is usable.
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
