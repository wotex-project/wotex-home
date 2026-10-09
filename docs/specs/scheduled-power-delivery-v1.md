# Private scheduled power delivery v1

Version: 0.1.5. Implemented Authority composition, 2026-10-09.
WOH.14 owns execution, WOH.04 temporal authority and WOH.03 reports.

Authority delivers one retained scheduled boolean-power original without a
bearer or caller routing/clock. Trusted dispatch and a live power supervisor
are required before any capture. The Store derives current original author,
activation, complete temporal window, profile/resource and enrollment scope.
The capture owner resolves fresh private routing on its selected interface.
Held work publishes a fresh report and advances that exact retained
principal/epoch/operation through
[one guarded Store transaction](scheduled-refresh-admission-v1.md).
Read scope remains current before publication, before advancement and after
enclosing history validation against the actual receipt. Final refusal restores
tentative reports as well as admission and spend before retaining withdrawal.
Other pending originals cannot occupy a batch position ahead of this selected
occurrence. The Store derives its actual scheduled root and receipt; no new
request, caller time or proposed effect enters this operation. It repeats the
existing admission and enclosing final execution guards. Qualification refusal
terminalizes the original through the existing advancement semantics. A returned
original already owned by another claimant retains its actual receipt and starts
no second exchange. Matching reports close without a power transport or causal
spend. The separate sixteen-original maintenance pass remains available.

A known author/grant refusal detected after inner queue or no-send publication
is retained before restoring the enclosing checkpoint. The Store observes any actual
activation withdrawal, restores tentative admission/spend, retains the withdrawal
against the original phases and closes only the actual selected unsent identity.
A terminal or already owned receipt is returned as stored. A malformed identity,
explicit root or missing original cannot enter this refusal context. Final
publication/replay failure rolls back the complete operation and disables the
writer; neither partial acceptance nor discarded tentative receipts are returned.

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

On 2026-10-09 all nineteen original-specific SQLite cases passed. They cover
selection of the seventeenth retained occurrence without advancing its older
siblings, immutable original history, unchanged retry, substituted identities,
no-send, claimed/handed non-recall, cancellation, final expiry and qualification
loss, inner queue/no-send author/grant withdrawal, replay faults and admission
journal faults. All nine delivery and seven owner cases passed. The independent
UDP default moving-window case observed handoff at 2,007 ms; the one-second
expiry case refused without a set. Real sockets remained enabled. This is
software evidence; minimum-window latency and installed/physical qualification
remain unfinished.

The later [transaction-bounded runtime inventory](runtime-guard-inventory-v1.md)
surrounds preparation with complete opening/closing inventories and closes
before the final independent artifact/clock guards. Its 132-case execution and
delivery run passed both independent UDP cases; default-window handoff was
observed at 966 ms. Five opt-in one-second attempts produced two positive
handoffs and three safe expiry refusals without a set. The complete minimum
window therefore still needs latency margin and supported-host/load evidence.
No deadline, current guard, admission scope or physical default was widened.
