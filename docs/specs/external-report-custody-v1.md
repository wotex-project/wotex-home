# Bounded custody for external transport receipts

Version: 0.1.3. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-04/05/08, H18-T3/T4/T8/T11/T12; WOH.03 H03-T3/T5.
Implementation: bounded publisher/Store custody process and schema 35
[durable observation integration](external-observations-v1.md) implemented.
Host transport installation planned. Evidence: [executed software/archive
cases](../provenance/external-report-custody-2026-10.md); physical evidence missing.

## Result and ownership

Profiles.ExternalReportOwner retains one exact bounded decoded transport receipt
from an explicitly configured trusted publisher. The publisher owns actual packet/
read correlation and stamps the host clock at receipt. A report is inert until
the single Store checks current target/source/trust, interprets it with the public
WPF API, consumes its accepted meaning and commits its observation transition.
Neither this process nor a profile receives a Store connection or bearer.
No socket/model request can install a publisher, author a receipt clock or publish
a decoded report as fresh truth. The report owner performs no device I/O.

[Source custody](external-source-custody-v1.md) owns checked host source selections
and their current source-owner incarnation/SHA. The public WPF Interpreter and
Home [ExternalValue](external-values-v1.md) own full report/C02/schema/unit
interpretation; buffering does not duplicate or establish those mechanics.
Source method/trust remain host assertions, not physical qualification. Existing
Light/SmokeDetector reports, grants, effects and v1 histories remain unchanged.

## Configuration and closed publication

start_link/1 requires publisher: live PID, source_owner: live SourceOwner PID,
and store_owner: PID or local registered atom. The host supplies all three;
store_owner may name the Store that starts later. Optional name uses ordinary
GenServer registration. Options are report_limit 1..256 default 128,
ttl_ms 100..60000 default 60000, max_bytes 1..4194304 default 4194304.
Unknown, duplicate, malformed or dead publisher/source-owner configuration refuses
invalid_external_report_owner before linking. Both owners are monitored;
publisher/source-owner death stops custody normally. The supervisor restart is
temporary. A replacement is explicitly installed with a new random hex32 epoch.

All calls have a five-second deadline. Local clock is System.monotonic_time in
microseconds, including a negative native origin. receipt_clock/1 returns exactly
epoch (the owner hex32) and monotonic_us (current local time encoded as a
canonical signed-64 decimal string, as required by WPF). The
publisher records that epoch and the actual monotonic receive instant; publication
processing time never replaces the supplied instant. Clock reports establish no
physical source time or source authentication.

publish/5 takes report_id, source_ref, source_selection_sha256 and report.
Report ID/source ref are Home IDs, SHA lower hex64. Reject nonpublisher before
producer/container work. Report is a non-struct JSON map with exactly the WPF
thirteen fields channel_id, profile_sha256, binding, capture_epoch, source_ref,
source_epoch, sequence, source_time, receipt_time, continuity, quality,
quality_reason and value. Channel is a Home ID; source_ref/source_epoch must
equal the current checked source summary; sequence is null or a canonical
unsigned-64 decimal string (no leading zero, sign or whitespace).
Other WPF members are bounded opaque data here and are interpreted later.
receipt_time is exactly epoch and monotonic_us, matching this live owner epoch,
as a canonical signed-64 decimal string at or after owner startup and at or
before current local time. Report deadline
is the original receipt instant plus ttl_ms, not publication/checkout time.

Use public Core JSON.encode/2 to retain exact canonical report bytes, at most
65536 bytes, depth eight, 4096 nodes, collections 256, strings 4096. Numeric
report metadata follows WPF; this owner does not coerce C02 values or units.
Missing producer refuses profiles_producer_unavailable for new publication.
Source catalogue epoch/SHA must be current before and after byte preparation;
selection replacement refuses stale_external_source, incarnation change
external_source_owner_changed, owner loss external_source_unavailable.

Report SHA is SHA-256 of UTF-8 wotex-home.external-transport-report@1, newline
and exact canonical report bytes. Scope is report_id within this owner epoch.
Publication comparison uses the public canonical encoder, including replay;
missing producer still refuses publication. Metadata, checkout and retirement
need no producer. Exact publication replay checks retained scope/source/SHA before current clock,
source or capacity, returns its original safe receipt and renews nothing.
Changed input at that ID is external_report_conflict. The same non-null source/
epoch/channel/sequence cannot be published under another ID; refuse
external_report_duplicate even after consumption/expiry. A null sequence has no
invented correlation key; eventual Store admission cannot treat it as continuous.

## Lease and original transitions

**RC-01 — Retain bounded originals.** Retain at most report_limit pending or
checked-out bodies and max_bytes aggregate canonical bytes. Keep at most 1024
original summaries/correlation tombstones per incarnation. New publication over
any capacity refuses external_report_capacity before state change. Retired bodies
release byte/active slots but preserve original identity. Timers and every call
expire at now >= original deadline. Timer period is min(ttl_ms, 1000) milliseconds.

Safe receipt is exactly format wotex-home.external-transport-receipt@1,
report_id, owner_epoch, source_owner_epoch, source_ref, source_selection_sha256,
channel_id, source_epoch, sequence, report_sha256 and state. States are pending,
checked_out, consumed, expired, invalidated or cancelled. It contains no body,
stable identity, source/receipt time, token or endpoint. catalogue/1 returns
exactly owner_epoch and receipts sorted by report_id; status/2 returns this safe
receipt or not_found. Native host access is not bearer authorization.

**RC-02 — Checkout only to Store.** checkout/2 takes report_id and requires its
caller to equal the currently resolved configured Store PID. Require an active
unexpired receipt and unchanged current source epoch/SHA. Pending becomes
checked_out and monitors the caller. Same caller exact replay preserves all
fields/deadline; a different Store incarnation refuses external_report_busy.
Return exactly report (original native map), document (exact bytes) and guard.
Guard has exactly report_id, owner_epoch, source_owner_epoch, source_ref,
source_selection_sha256, report_sha256, receipt_monotonic_us, expires_at_us and
checkout_pid. Native PID/times never enter a socket request or retained receipt.

validate/3 takes report_id and exact checkout PID. It requires the native Store
caller, checked_out, live matching checkout PID, same owner/source incarnation/
SHA and now before deadline. It returns the unchanged guard. This is a borrowed
custody guard, not observation or effect authority. A later Store transaction
must repeat its own epoch, selection, author/trust/policy and byte guards before
committing. Final callback refusal rolls back all observation rows and counters.

**RC-03 — Retire without renewing freshness.** finish/2 is Store-only and consumes
its own checkout. Exact consumed finish remains success. cancel/2 is publisher-
only and cancels a pending receipt; checked-out cancellation refuses busy because
the durable result can be uncertain. Caller death cancels its checkout. Expiry
retires even checked-out bodies. Detected source replacement invalidates matching
active receipts on the next owner call/timer; it cannot leave a valid old guard.
Retirement drops body/document/active clock fields/PID/monitor and keeps the safe
original. The accepted [consumed lifetime successor](external-report-lifetime-v1.md)
adds a separate private original clock pair for consumed entries only; its API
and evidence remain planned until implemented.
No retired original can become pending through replay. Process restart restores
nothing and changes epoch; old report IDs/guards do not become current authority.

## Failure, recovery and durable entry

Malformed publication refuses invalid_external_transport_report; malformed IDs/
native scope invalid_external_report_lease. Wrong publisher is
external_report_publisher_denied, wrong Store external_report_store_denied.
Wrong clock is invalid_external_report_clock. Retired lease is
external_report_retired; changed source/incarnation keeps the source errors above.
All errors are atoms without private payload. OTP status/crash formatting redacts
state and message. No exception logs the decoded body or hardware identity.

Store finishes checkout after a definite commit/refusal. A lost reply uses the
eventual observation owner's durable original status; it never republishes the
same packet with a new timestamp/ID. Missing durable original plus retired custody
requires an explicitly new actual transport receipt. Neither restarting custody
nor restoring SQLite can manufacture a live receipt, grant or qualification.

Before durable observation implementation, freeze its schema, exact canonical
value/outcome/receipt and current selection/clock/sequence rules in its own owner.
That successor must map receipt_monotonic_us into Store boot receipt-clock scope,
reject pre-Store-boot/future/expired receipts, prevent duplicate freshness renewal
across custody restart, and preserve producer source_time/receipt_time separately.
This custody owner has no persistence, SQLite migration, canonical current report,
operator upload, read fact or physical dispatch. It is the required native receipt
boundary for that successor, not a substitute for the complete observation path.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| RC-T1 | 01–03 | Independent temperature/density/multi-channel reports: publish, exact replay, Store checkout/validate/finish and safe status. Changed bytes, timing renewal or body leak fails. | Software/archive |
| RC-T2 | 01/02 | Foreign publisher/Store, wrong source/epoch/SHA/clock, malformed channel ID/oversized native data and correlation duplicate. Any state change or imported authority fails. | Software |
| RC-T3 | 02/03 | Source replacement, expired checkout, caller/publisher/source-owner death, uncertain Store reply and new incarnation. A valid old guard, automatic recapture or resumed receipt fails. | Software |
| RC-T4 | 01/03 | Actual count/byte boundary, 1024 retained originals, duplicate tombstones, timer release and missing producer during metadata/retirement. Lost identity, overflow or producer fallback fails. | Software |

Use actual processes and a separate configured Store receiver, independent report
JSON/hash vectors and real source custody. A synthetic publisher can establish
these software boundaries only; qualified transport correlation and live sensor
meaning require the existing physical cohort procedures.
