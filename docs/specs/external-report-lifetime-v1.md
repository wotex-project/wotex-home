# Consumed external report lifetime witnesses

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.18 H18-04/05/08 and H18-T3/T4/T8; WOH.20 H20-04/06, H20-T1/T3.
Implementation: planned. Evidence: source review and independent entry vectors;
no native lifetime API or current routine collection evidence yet.

## Purpose and boundary

Profiles.ExternalReportOwner.lifetime/3 returns the original receive instant and
exclusive deadline of one consumed report, while that same owner and source are
still live. A later Store collector can cap a routine Fact at this original
lifetime rather than renew it from processing time or declaration freshness.
A receipt consumed at -5 us with ttl_ms 60000 expires at 59999995 us even if a
later consumer allows a longer freshness interval.

The existing [report custody contract](external-report-custody-v1.md) owns
publication, exact report SHA, source correlation, caller-bound checkout and
consumption. [Durable observations](external-observations-v1.md) own retained
originals, target/channel current pointers, author/trust/policy checks and Store
receipt coordinates. The [inert routine projection](routine-external-facts-v1.md)
owns original reader reconstruction and exact Mapping conversion. This witness
creates no observation, receipt original, lease, qualification or authority.
It exposes no bearer, Store connection, report body, stable device identity or
transport endpoint. There is no new socket, CLI or model route.

Source review at Home aa8ec898 found that retirement discards the guard's original
receive/deadline fields, while durable v1 receipts retain received_store_ms but
not the original report-owner deadline. Reconstructing that deadline from a
current/default ttl would change an old receipt. Retain the original two integers
in bounded, process-local consumed custody instead; persistent v1 bytes stay exact.

## API and closed result

lifetime(server, expected_owner_epoch, report_id) is a native five-second GenServer
call. The caller must equal the currently resolved configured Store PID, using
the existing PID or local registered-name rule. Perform that check before lookup,
source calls or clock disclosure. expected_owner_epoch is lowercase hex32;
report_id is a Home ID. Reject malformed input as invalid_external_report_lease;
a valid different owner epoch returns external_report_owner_changed before lookup.
A missing ID under the matching owner returns not_found.

Only an exactly consumed original can produce a witness. Pending or checked_out
returns external_report_not_consumed; expired, invalidated or cancelled returns
external_report_retired. Require the source owner's current incarnation and
published selection SHA to match the original summary, and current monotonic
microseconds to be strictly less than the original deadline. Unavailable or
changed current source refuses external_report_retired; no cached source success.
The owner monitors publisher/source-owner death and stops as before. Calling a
dead owner retains ordinary GenServer exit behavior; Store callers must catch it
as unavailable rather than manufacture a witness.

Success is {:ok, plain_object} with exactly thirteen string-keyed JSON members:

| Member | Type and original source |
| --- | --- |
| format | wotex-home.external-report-lifetime@1 |
| owner_epoch | Original report owner hex32, equal to expected_owner_epoch |
| report_id | Original Home report ID |
| source_owner_epoch | Original source-owner hex32 |
| source_ref | Original source Home ID |
| source_selection_sha256 | Original lowercase hex64 source selection SHA |
| channel_id | Original channel Home ID |
| source_epoch | Original publisher source hex32 |
| sequence | Original null or canonical uint64 decimal string |
| report_sha256 | Original lowercase hex64 report document SHA |
| state | consumed |
| receipt_monotonic_us | Original signed-64 receive coordinate as canonical decimal string |
| expires_at_us | Original exclusive signed-64 deadline as canonical decimal string |

Both time strings reject leading plus, leading zero and negative zero. The
exclusive deadline is the original receive coordinate plus the ttl_ms * 1000
selected when this owner accepted publication. Require both coordinates to fit
signed-64 and their positive difference to be an integral number of milliseconds
in 100..60000. Invalid retained bounds return invalid_external_report_clock;
never clamp or wrap. The result has no sampled-now or new UTC field. It is at
most 4096 UTF-8 bytes and contains at most the original bounded IDs and metadata.
Native publication already owns validation of the retained source/correlation
fields. No reader/Core JSON API is required to read this native witness.

## Requirements and transitions

**RL-01 — Preserve only the necessary consumed witness.** On the successful
checked_out -> consumed transition retain the exact original receive/deadline
pair in a private lifetime field. Continue dropping report, canonical document,
active receive/deadline slots, checkout PID and monitor. Cancelled, invalidated
and expired active entries retain no lifetime pair. Do not introduce a second
map, per-reader originals, background tasks or a renewed lease. The existing
1024-summary/correlation cap also bounds these two retained integers per consumed
entry. Active count and body-byte capacity are released exactly as before.
All process status remains redacted; status/2, catalogue/1, publish replay and
checkout guard/result representations remain byte-for-byte unchanged.

**RL-02 — Guard the original, not a new receive instant.** lifetime/3 authenticates
the configured Store PID, validates expected owner and original, requires consumed,
rechecks the current source and checks the unchanged exclusive deadline. It does
not mutate the consumed summary or extend time. Equal live inputs return equal
witnesses; now == expires_at_us is retired. A current configured Store replacement
may read an unexpired consumed original while the owner lives, but its own Store
boot/selection/authorization rules still apply. The witness itself does not carry
or transfer the preceding Store's authority.

**RL-03 — Preserve retry and refusal.** Exact consumed finish remains :ok before
and after deadline; exact publication replay keeps the original consumed summary
and never reactivates a body or renews lifetime. Old sequence correlation remains
reserved. Wrong caller returns external_report_store_denied with no clock data.
Wrong owner, malformed input, missing original, non-consumed original, invalid
clock and retired lifetime remain separate payload-free outcomes as above.
There is no fallback to receipt_clock/1, current owner ttl or wall time.

**RL-04 — Keep current collection separate.** A future Store collector must match
owner/report/SHA/source/channel/sequence to the retained durable observation,
verify the original receipt coordinate against received_store_ms and Store boot,
and repeat current author/grant/selection/trust/policy/resource/custody/producer
and qualified Mapping checks. It must conservatively floor the original deadline
into Store elapsed milliseconds, reject preboot/future/expired data and cap expiry
by every narrower declaration, Mapping and owner bound. This witness does not
promote an approved read profile to a qualified routine input. Current collection,
complete-set composition and wider admission need their own owning contracts.

## Failure, restart and compatibility

No SQLite table, schema number, durable receipt or backup encoding changes.
Restart restores no lifetime pairs; a replacement owner has a new epoch and no
originals. Historical durable rows cannot seed this native state. Source change
or loss refuses current witness use even if immutable consumed metadata remains.
The two integer witnesses disappear when their owner stops. Restore/transfer
remains quarantined. No physical dispatch flag or read/write grant changes.

The changed internal consumed representation is deliberate: only its bounded
private lifetime pair is new. Safe public receipt representations and retirement
of bodies stay compatible. This corrects the earlier custody statement that
all original clock coordinates disappear; no existing public result gains fields.

## Entry conditions and acceptance

Commit this contract, the offline closed result schema and independent signed
receipt/deadline vectors before implementation. The schema checks representation;
the native owner must enforce numeric ranges, source/caller/state and time.
Actual owner tests use public source/reader/report APIs. A fresh isolated VM may
replace only clock/nonce seams in test code to hit signed/exact deadline vectors;
production has no injectable clock, alternate publisher or fixture branch.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| RL-T1 | 01/02 | Actual two-quantity and multi-channel publication, checkout, finish; compare original pair and whole closed witness; changed clock/body or invented UTC fails | Native software |
| RL-T2 | 02/03 | Wrong caller/owner, malformed ID/epoch, missing/pending/checked-out/cancelled/expired originals, source replacement/loss and invalid retained range | Native refusals; no partial result |
| RL-T3 | 01–03 | Independent negative receive and exact-before/equal/after deadline in an isolated actual owner; exact finish/publish replay and sequence tombstone | Deterministic native software |
| RL-T4 | 01/03 | Body and monitor release, existing count/byte/1024 cap, public receipt shape and producer-absent consumption/witness | Software/archive |
| RL-T5 | 02–04 | Configured Store incarnation changes; owner restart changes epoch and drops witnesses; no historic restore or current routine authority | Software |

Entry/schema evidence alone does not satisfy these cases. Record exact source,
toolchain, commands, actual results and artifact cleanup. Software tests and
signed clock fixtures do not qualify a source, physical device or installed host.
