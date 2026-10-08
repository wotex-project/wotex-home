# Controller-owned explicit power delivery v1

Version: 0.1.0. Implemented software boundary, 2026-10-08.
WOH.14 owns execution, WOH.03 owns transport/report meaning and WOH.08 owns
host lifecycle. Installed and physical qualification remain separate.

## Original and routing

One controller-owned consumer selects retained held or queued boolean-power
originals through Authority. Each scan uses the Store's immutable creation
order, sixteen-row page limit and initial revision cutoff. New arrivals cannot
keep an old scan open indefinitely. A failed original is deferred for thirty
seconds; the consumer retains only its creation revision and retry deadline.
It retains no bearer, device identity, report, routing or Store connection.
One exchange completes before the next timer is armed. Claimed, handed-off,
unknown and terminal receipts are absent from selection and cannot be retried
by this loop. This consumer handles explicit originals, including explicit
rule invocations; it does not select temporal occurrences.

Authority requires trusted dispatch configuration and a live power supervisor
before capture. The Store derives the exact original author's current grant,
epoch, profile/resource pin, enrolled stable identity and applicable rule
guards. No client supplies routing, adapter clock, boot identity or source
sequence. This trusted operation has no new API or CLI route.

The existing capture owner discovers the enrolled stable identity afresh on
its selected interface. It refuses a busy enrollment session, ambiguous
identity, exhausted source sequence or expired bounded capture. Held originals
receive the existing correlated GetLightState report before admission. Queued
originals discover routing only: their sealed baseline is not replaced.
Private routing returns to Authority, with the capture-owned boot, monotonic
clock and a separately reserved readback source sequence. It exposes no socket
handle or transcript. Capture owns no Store reference and sends no command.

## Guarded exchange and recovery

For held work, Store publication repeats the complete original author and
capture scope before and after the report transaction. Authority then advances
that same original through ordinary guarded admission. A matching fresh report
closes it as `already_reported_no_send` without opening a power transport or
spending its causal root. Required effects still need current exact signed
qualification custody and all existing admission guards.

Queued work uses the existing supervised power executor. Its five narrow Store
hooks repeat current claim, final handoff, protocol acceptance, observation and
failure guards. The worker receives no Store connection or bearer. Absolute
SetLightPower follows a committed handoff; ACK is intermediate and correlated
GetLightPower is the independent readback. Matching, contradictory and missing
readback retain `observed`, `contradicted` and `outcome_unknown` respectively.
A missing ACK does not prevent a matching readback from settling the report.
An uncertain handoff is never blindly resent. Existing explicit reconciliation
remains separate and does not attribute a later report to the original packet.

Same-boot queued recovery can proceed only while its original sealed report
and all claim/handoff guards remain current. A prior-boot or superseded report
cannot be refreshed into that queued execution. Cancellation, withdrawal,
resource/profile changes, maintenance and unknown effect-domain occupancy keep
their existing fail-closed behavior. No schema or persistent receipt shape is
changed by this consumer.

## Host ownership and evidence

Trusted `:lifx_power_dispatch_enabled` remains false by default. With it enabled,
the Host restart order places capture before the consumer, and the consumer
before the power Task.Supervisor and API server. Losing capture or the consumer
stops downstream workers. Losing Store or custody also fences delivery. The
optional component preview stays last and cannot restart earlier core children.
Dispatch configuration is neither enrollment nor physical qualification.

Twelve focused actual Authority/SQLite/scripted-transport cases cover matching,
contradictory and missing readback, ACK loss, no-send closure, default dispatch,
caller routing rejection, qualification custody loss, original-author
revocation during capture, prior-boot refusal, same-boot queued recovery with
distinct source sequence, uncertain-work exclusion and bounded scanning under
new arrivals. Synthetic signed qualification supplies software fixtures only.
The host suite checks the restart order and actual consumer death stopping a
power worker while preserving Store. Actual local Unix and UDP socket suites
remain enabled. These checks do not establish installed service custody,
hardware behavior, sleep/wake continuity or storage power-loss survival.

On 2026-10-08, fresh-Home runs passed 99 selected direct-power/causal-history
cases (including the twelve delivery cases), 80 authority/request/maintenance/
executor cases, twenty host/capture/enrollment API cases and twenty real
UDP/scripted-peer cases: 219 cases with no failures. The direct-history filter
excluded 311 unrelated temporal cases; no socket-free option was used.
Formatting, warnings-as-errors compilation, contract/catalogue metadata,
changed-document references and Git whitespace checks passed. An initial host
command named a nonexistent test file; the corrected twenty-case run passed.
