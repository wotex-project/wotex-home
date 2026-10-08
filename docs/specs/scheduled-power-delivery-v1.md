# Private scheduled power delivery v1

Version: 0.1.2. Implemented Authority composition, 2026-10-08.
WOH.14 owns execution, WOH.04 temporal authority and WOH.03 reports.

Authority delivers one retained scheduled boolean-power original without a
bearer or caller routing/clock. Trusted dispatch and a live power supervisor
are required before any capture. The Store derives current original author,
activation, complete temporal window, profile/resource and enrollment scope.
The capture owner resolves fresh private routing on its selected interface.
Held work publishes a fresh report through the final guarded occurrence scope,
then uses the existing Store-owned sixteen-original advancement. Only an actual
returned receipt matching the original principal/epoch/operation can proceed.
An original outside that batch returns `schedule_advance_deferred`; no queue or
dispatch success is invented. Qualification refusal terminalizes the occurrence
through the existing advancement semantics. A returned original already owned
by another claimant retains its actual receipt and starts no second exchange.
Matching reports close without a
power transport or causal spend.

Queued recovery discovers routing without refreshing the sealed report. The
Store joins the exact execution baseline to the current power report and
returns its producer epoch privately. Capture must retain that producer epoch;
a changed or superseded producer refuses before opening a power transport.
This prevents sending a command whose readback would require an unreviewed
source reset. Capture restart cannot refresh an old queued baseline into new
authority. Existing expiry/withdrawal and original cancellation remain separate.

The shared supervised executor derives identity from the actual Store receipt.
Capture epoch/sequence and clock coordinate packet correlation and readback;
they do not establish temporal authority. Store-owned clock/window, author,
qualification, baseline, serialization, causal and attempt guards remain at
claim and committed handoff. SetLightPower follows committed handoff, ACK is
intermediate and separate correlated GetLightPower supplies readback. Matching,
contradictory and missing readback retain observed, contradicted and uncertain
outcomes; ACK loss can still settle a matching report. Uncertain work is never
selected for blind replay. A window closed after queue refuses before claim;
subsequent Store advancement terminalizes that unsent occurrence without
refunding its committed reservation.

A trusted delivery refusal closes only an actual scheduled held or queued
original. It validates complete durable history and the maintenance barrier,
derives the root and current receipt phase from the Store, and atomically
journals rejection with removal of unsent work. Known guard reasons retain
their closed policy name; other internal failures become
`schedule_blocked:delivery_unavailable`. A repeated refusal returns the existing
rejection without a revision. Claimed, handed-off and terminal outcomes cannot
be recalled through this cleanup boundary. Existing causal spend is never
refunded. No caller obtains new effect authority from a refusal.

Nine additional actual SQLite/Authority cases passed on 2026-10-08: held/queued
closure for policy and generic failures, original identity and unchanged retry,
claim/handoff non-recall, substituted roots and malformed input, and held/queued
journal-fault rollback with the writer disabled. Every successful or rolled-back
closure checks complete snapshot integrity. The fresh-source test run used
locked dependencies and retained real socket tests.

This trusted composition creates no public route, schema, autonomous admission
proof or installed clock custody. The separately opt-in
[temporal owner](schedule-delivery-owner-v1.md) now supplies polling and Host
restart ownership. Physical dispatch stays disabled
by default and current exact device qualification remains mandatory.

Nine actual Authority/SQLite/scripted-transport cases cover the outcomes above,
immutable occurrence lookup and receipt identity, original causal spend,
no-send and qualification refusal, post-queue expiry, same-producer queued
recovery and changed-producer refusal before send. Complete snapshot integrity
is checked. Synthetic signed profiles and clock peers establish software
behavior only. The initial queued test exposed producer reset after send; the
implemented pre-dispatch continuity guard and corrected recovery cases pass.

On 2026-10-08 fresh-Home runs passed all nine delivery cases, ten scheduled
capture cases and 99 direct-power/causal-history cases. Real local socket tests
remained enabled; no socket-free option was used. Formatting, warnings-as-errors
compilation, workspace/indexed contract metadata, changed-document references
and Git whitespace checks passed. Native presentation and packaging are unchanged;
the delivered app remains bound to its earlier explicit-delivery commit until
the temporal host consumer is integrated and a new artifact is built.
