# Atomic scheduled report and admission v1

Version: 0.1.0. Implemented software boundary, 2026-10-09.
WOH.14 owns transaction and receipt meaning; WOH.04 owns temporal authority;
WOH.03 owns report provenance and routing.

Private held-power delivery now asks the single Store to publish its captured
reports and advance that exact original in one transaction. The internal
`refresh_and_advance_scheduled_power` call accepts the previously derived held
scope and validated reports, with no bearer, proposed effect, endpoint or clock.
It creates no new request, occurrence, root, schema or public route. Separate
report-only publication and original advancement remain available with their
original semantics. Queued delivery keeps its sealed report and producer basis.

The Store reconstructs the complete held scope before report publication and
again before advancement. Reports retain the existing immutable declaration,
source correlation and Store-stamped receipt coordinates. Advancement selects
only the scope's original principal/epoch/operation and repeats the current
author, activation, temporal window, profile, qualification, report freshness,
effect-domain, invariant, override, causal and attempt guards. A matching report
closes with `already_reported_no_send`, with no transport or reservation.
An all-duplicate report batch can advance only under the same current checks;
replaying reports cannot renew their Store receipt time.

After tentative advancement, the enclosing transaction captures its actual
receipt, observes sticky withdrawal and validates the complete owning history.
It reconstructs the original read scope against that actual receipt, including
the exact stable binding and declaration, then runs the existing final power
guard for queued or no-send work. Accepting a terminal receipt for this internal
scope comparison does not make terminal requests available for fresh capture:
the public private-read operations retain their held/queued limits, and the new
composition accepts a held original only.

The enclosing checkpoint precedes report publication. A known final refusal
therefore restores tentative reports, source custody, queue/no-send publication
and newly reserved spend before retaining any observed activation withdrawal
and closing the actual original. The returned receipt describes the restored
rows. A policy failure before advancement rolls back the reports completely.
An ordinary qualification refusal can commit its terminal receipt and validated
report together. SQL, history or refusal-replay failure rolls back the complete
operation and disables the writer. Existing committed reservations are never
refunded, and this operation cannot recall claimed or handed-off work.

Claim, committed handoff, protocol acknowledgement and independent readback
remain separate execution transitions. A lost reply is recovered through the
original immutable occurrence and request status; repeating the old held scope
after queueing or closure creates no second admission. Restart cannot make that
scope held again. No manifest, authority decision or current clock result is
cached by this composition, and no occurrence deadline is widened.

Twenty actual SQLite cases pass. They cover queue/no-send publication, immutable
original recovery and unchanged retry across Store restart, substituted scope,
explicit roots, queued-baseline refusal and duplicate reports without receipt
time renewal. Report-time author/grant loss rolls back completely. Queue/no-send
author/grant withdrawal retains its original barrier after restoring reports
and spend; injected replay failure restores the held original and fails closed.
Three SQL publication faults roll back reports, queue and receipts together.
An arity-only trace signals actual queue publication to the private clock peer;
subsequent expiry, confidence loss and uncertain time restore tentative work.
The trace supplies no Store connection or receipt arguments to that peer.

The first trace harness used the wrong message shape and crashed its clock peer,
producing clock-unavailable refusal rather than the intended expiry/uncertainty
injections. Corrected arity-only tracing passes all three cases. Its initial
clause-grouping warning was also corrected; the final focused run has no warning.
These preliminary failures do not establish the intended boundary evidence.

Both independent raw-UDP window cases pass with real sockets enabled. The
default moving-window handoff was observed at 1,606 ms; exact one-second expiry
refused without a set. These local results still do not establish usable
minimum-window latency. Installed clock/sleep behavior, autonomous admission and
physical qualification remain separate obligations. Dispatch stays disabled by
default, and packaging evidence must bind the new committed source separately.

Final fresh-source regression passes 242 selected cases across artifact readers,
profile/correspondence, rule and schedule admission, clock custody/context,
supervised power, Host lifecycle, enclosing guards and original/capture/delivery/
owner/refusal transitions, including all twenty new transaction cases. The two
independent UDP window cases run separately and also pass; sockets remain enabled.
Formatting, warnings-as-errors compilation, the working 20-contract and indexed
19-contract catalogues, 41 staged local references and Git whitespace checks pass.
These are software checks, without installed or physical qualification.

A separate positive one-second attempt still fails safely: the actual original
is rejected as `schedule_blocked:occurrence_expired`, and no set is emitted.
Its independent peer times out waiting for that absent command. This remains
counterevidence to minimum-window usability; the successful default-window case
and atomic publication checks do not discharge that product obligation.
