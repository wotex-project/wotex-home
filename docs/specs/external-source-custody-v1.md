# Bounded host custody for external source snapshots

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-04/05/07/08/H18-T3/T4/T6/T8/T11/T12.
Implementation: bounded original-scoped custody process implemented; Host and durable target adoption planned.
Evidence: [executed process, archive and cold-start cases](../provenance/external-source-custody-2026-10.md).

## Result and trust boundary

Profiles.ExternalSourceOwner is a transient host process retaining exact checked
[source selections](external-source-selection-v1.md) and one-use, original-scoped
snapshot leases for later target review/commit. It opens no Store, receives no
bearer and performs no transport I/O. An explicitly configured trusted publisher
supplies actual host-held source/capture/consumer assertions. A published source
does not authenticate a device, qualify hardware, accept a report or grant control.
No model/request can choose a publisher PID, endpoint, driver or consumer policy.

Authority must derive the principal through current Store permission checks
before asking for custody. SourceOwner accepts that principal ID as internal
trusted boundary input, not as external caller authentication. Store repeats
permission, current source and original checks before a durable target commit.
The single Store owns target history; this process owns only transient memory.

## Configuration and public internal APIs

start_link/1 requires publisher: one live PID. Options are name (normal GenServer
registration), source_limit 1..32 default 32, lease_limit 1..32 default eight,
ttl_ms 100..60000 default 60000 and max_bytes 1..4194304 default 4194304.
Unknown/invalid options refuse invalid_external_source_owner. The owner monitors
its publisher and stops when the publisher dies; a new owner has a new random
lower-hex32 owner_epoch. It never restores sources, leases or authorization from
disk. Publication and lease APIs have bounded five-second call deadlines; clocks
are local System.monotonic_time(:millisecond), including negative native origin.
Validate options before linking a process. Its supervisor child specification
uses restart temporary: publisher loss cannot repeatedly restart custody with
the dead PID or revive an old incarnation. The host explicitly installs custody
under its new publisher. A publisher dying during startup causes normal owner
termination through its monitor, with no republished sources or fresh lease.

Original ref is exactly authority_epoch (positive signed-64), operation_id (Home
ID) and input_sha256 (lower hex64) for the later target original. Principal and
source_ref are Home IDs. Scope is principal/epoch/operation; changed digest or
source within a retained scope is external_source_conflict. No API accepts a
credential, SourceConnection or database handle.

| API | Input and output |
| --- | --- |
| publish/2 | Checked ExternalSourceSelection; publisher-only; returns safe current summary |
| catalogue/1 | owner_epoch and sources sorted by source_ref, each safe source summary |
| hold/5 | principal, original ref, source_ref, expected owner_epoch; returns lease summary |
| status/4 | principal, epoch, operation; lease summary or not_found |
| checkout/4 | principal, lease token, exact original ref; returns borrowed native selection and local guard |
| validate/5 | principal, token, original ref, checkout PID; returns guard or typed refusal |
| finish/4 | principal, token, original ref; consumes a checked-out lease |
| cancel/4 | principal, epoch, operation; retires an uncommitted lease |

Safe source summary is exactly source_ref, source_selection_sha256 and data
(the source selection's nine-field payload-free summary). Catalogue adds exactly
owner_epoch and sources. Lease summary is exactly owner_epoch, principal_id,
authority_epoch, operation_id, input_sha256, source_ref,
source_selection_sha256, token and state. Tokens are fresh opaque lower-hex32,
never caller-selected. States are pending, checked_out, consumed, expired,
invalidated or cancelled. Status exposes only this actor's original, no stable
ID, capture, consumer bodies or local monotonic time.

Checkout returns exactly selection (the checked native source value) and guard.
Guard is exactly owner_epoch, token, principal_id, authority_epoch, operation_id,
input_sha256, source_ref, source_selection_sha256, checkout_pid and expires_at.
Guard is internal native data; PID/deadline never enter JSON or durable history.
Validate uses the guarded checkout PID, not a caller-authored external identity.
Store's native commit callback may pass that exact PID from Authority's borrowed
guard; no transport request can supply it. The returned guard is never authority
by itself and does not replace current Store checks.

## Requirements and state transitions

**SC-01 — Publish only checked host selections.** Reject any non-publisher before
producer reconstruction. Rebuild every native selection with public to_map/1.
Count its complete canonical source/reader.inputs/channels bytes from public
core JSON under the selected reader limits. Retain at most source_limit distinct
references and max_bytes aggregate across current sources. Resource refusal is
external_source_capacity, with no pointer/lease changes. Exact republish returns
the same current summary and renews no lease/time/generation. A different value
for an existing source requires source_generation = previous + 1; otherwise
stale_external_source_generation. A new source may start at any positive supplied
generation; owner restart remains distinct through owner_epoch.

After a checked replacement passes every guard, publish it and invalidate all
pending/checked-out leases of the old selection atomically in memory. The old
native value may still be held by a borrower, but validate refuses it. Source
identity, epoch, reader/capture or policy changes never edit a prior lease.
Source-owner publication is separate from a physical source changing; the actual
transport/capture owner must notify its current-source succession promptly and
all eventual reports must independently recheck their source correlation.

**SC-02 — Hold once per original.** Require the current owner_epoch and a current
source. Exact pending/checked-out/retired scope replay returns its original
summary before current source/capacity work and does not extend expires_at.
Changed scope input refuses external_source_conflict. First hold requires a
free lease slot; it snapshots the exact current native source and deadline
now + ttl_ms. Count at most 1024 retained original scopes/tombstones during an
owner lifetime, refusing external_source_capacity instead of deleting retry
identity. Pending leases expire when now ≥ deadline. No current source or actor
source discovery is inferred by a lease token.

**SC-03 — Checkout and commit guard.** Checkout requires the owning principal,
exact original digest and a nonexpired pending lease whose current source SHA
still equals the held SHA. Bind it to the checkout caller PID and monitor that
caller. Exact checkout by the same caller recovers the same native value/guard
without renewing its deadline; another caller gets external_source_busy.
Validate requires checked_out, matching principal/original/token/PID/owner epoch,
live caller, now < deadline and the same current source SHA. Any changed/expired/
retired source guard refuses; the later Store transaction must abort without
publication. Owner failure makes validation unavailable; it never implies a
successful or rolled-back Store decision.

**SC-04 — Retire without fresh authority.** Finish consumes a matching checkout
and removes its caller monitor; exact consumed replay is unchanged success.
Cancel retires a pending lease, with exact cancelled replay unchanged success;
checked-out cancellation refuses external_source_busy because its Store result
may be uncertain. Expiry, source replacement or checkout caller death retires
the lease and releases capacity/monitors while preserving its original summary.
Checked-out leases also expire at their original deadline. Caller death retires
as cancelled. Retirement drops the owner's private selection/caller/deadline
and monitor; only the bounded safe original summary remains. Finish requires the
checkout caller; another caller receives external_source_busy. Cancel of any
other retired state refuses external_source_retired. The owner processes expiry
on every call and a timer at min(ttl_ms, 1000) milliseconds, so abandoned capacity
is released even when no caller polls. Exact consumed finish remains :ok without
needing the former caller to be alive. Catalogue reflects retained host assertions,
not live transport availability.
No retired original can be made pending by replay or by fresh publication.
Restart drops all memory and changes owner_epoch, so old tokens/guards cannot
become current even when a host republishes the same source selection.

Malformed refs/options/native fields refuse invalid_external_source_lease or
invalid_external_source_owner as appropriate; publisher mismatch
external_source_publisher_denied; missing source/original/token not_found;
wrong actor does not reveal another original. Wrong owner epoch is
external_source_owner_changed; retired/expired lease external_source_retired;
changed held selection stale_external_source; busy checkout external_source_busy.
Inherited source/producer reconstruction errors remain typed and payload-free.
No exception exposes private stable/capture/consumer data. OTP status and crash
formatting redact both the private state and current message; safe catalogue
and actor-scoped status APIs remain the inspection boundary.

## Durable handoff and acceptance

The next owning durable target contract must freeze input/outcome/receipt,
selection/enrollment/current tables and backup/integrity obligations before code.
It must recover the original before this owner, recompile actual actor-owned
bytes with this held target source, then recheck this guard inside its single
transaction alongside epoch/CAS/maintenance/trust/policy/grants/counters. Release
custody on every success, refusal, caller loss and SQL fault. A vanished lease
or lost reply requires durable original status, not a fresh automatic snapshot.
Snapshot custody does not complete physical source authentication, device read
qualification, external report admission or Store-clock freshness.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| SC-T1 | 01–04 | Real process with checked independent sources: publish, hold/replay, checkout/validate/finish, private status and stable deadline. Renewed expiry, private summary leakage or source substitution fails. | Software |
| SC-T2 | 01/02 | Foreign publisher, malformed native/ref, generation mismatch, source/byte/lease/original limits. Partial publication, lost scope or broadened actor lookup fails. | Software |
| SC-T3 | 03/04 | Concurrent caller, expiry, replacement, caller/publisher death and owner restart. Live old guard, leaked monitor/slot or recycled token fails. | Software |
| SC-T4 | 01–04 | Missing producer during new publication, exact existing metadata/status and retired originals; no Store/bearer/network/physical calls. Fallback producer or new authority fails. | Software |
