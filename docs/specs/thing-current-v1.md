# Current Thing inspection v1

Version: 0.1.3. Implemented bounded inspection and native presentation evidence,
2026-10-08.
WOH.01/02 own declarations and observations, WOH.14/15 own current scope and
Store receipt clocks, and WOH.08 consumes this read for native inspection.

The local request contains exactly `api_version: 1`, `operation: "thing_current"`,
`credential` and `thing_id`. Require a current read or ordinary-control principal,
its current target grant and an active enrolled declaration. Retired/quarantined
owners refuse. No supplied time, source evidence, route or profile is accepted.

Success contains exactly `api_version`, `outcome: "ok"` and `thing_current`.
The latter has `format: "wotex-home.thing-current.v1"`, `principal_id`,
`authority_epoch`, `store_revision`, `store_boot_epoch`, `sampled_monotonic_ms`,
`resource_revision`, `declaration` and `capabilities`. Declaration retains the
existing complete closed Thing document. There is exactly one sorted capability
entry per declaration key, at most 32. Each contains `key`, `current_value`,
`report`, `freshness`, `remaining_ms`, `age_ms` and `profile_status`.

Report is null when missing, otherwise the existing fourteen-field observation
projection plus `received_store_boot_epoch` and `received_store_monotonic_ms`.
Compare its current row to its original complete journal row, identity,
declaration/profile/evidence references and typed value before returning it.
Corruption refuses and disables writing. Historical/source time and adapter
monotonic time are evidence; they never determine current Store freshness.

Freshness is one of `missing`, `unknown`, `synthetic`, `untimed`, `old_boot`,
`future`, `stale`, `fresh`, `profile_unavailable`. Only `fresh` exposes a
`current_value`. The report retains its original stored value with its quality
and trust even when stale. Current profile denial forces `profile_unavailable`
and null current value. `profile_status` is `usable` or the owning current
profile guard's denial. `age_ms` is null outside a timed, nonfuture same-Store-boot
receipt; remaining is zero unless fresh. Fresh uses the Store's sampled receipt
clock, current declaration freshness bound and excludes synthetic lab evidence.
Reading advances no revision and creates no admission or physical qualification.

Native display must let freshness expire using elapsed client monotonic time
since the request began; it cannot renew evidence by redrawing or refreshing
stored state. An explicit `lifx_refresh` asks the existing host owner for bounded
fresh discovery/read of the enrolled identity and a reauthenticated Store commit.
It accepts only a Home Thing ID and returns the owning existing refresh result.
No timer, endpoint or write is introduced. A transport failure can leave reports
committed; rereading inspection is safe and does not silently repeat the probe.

Required evidence: actual Store read scope, missing/unknown/lab reports, receipt
clock expiry/old boot/future/untimed and profile denial; complete journal damage;
unchanged revision; strict framed route and independent native malformed shapes,
numeric/Boolean identity, declaration/report joins and monotonic expiry. Existing
fact-preview and snapshot contracts retain their shapes. Software evidence does
not establish hardware, installed permissions or protocol qualification.

`ThingReadModel` implements this synchronous borrowed-connection projection
through Authority and Store. The Store prepares current immutable profile byte
checks for this call and clears them after its reply. `FactReadModel.report_detail`
shares its original journal/receipt validation with unchanged reported-fact
preview semantics. The existing snapshot projection supplies the historical
wire fields without adding freshness claims to older routes. `thing-current
THING_ID` uses the strict framed route through the ordinary private CLI.

The focused inspection, observation-clock, Store, candidate, CLI and portable
review suites pass 109 tests. They cover scoped missing/reported/unknown/lab
evidence, exact expiry, future/untimed/old-boot receipts, duplicate after restart,
revocation, original journal damage and missing/revoked selected profile bytes.
Inspection advances no revision.

`NativeThingClient` implements closed typed declaration, report, value and
current-state decoding through the existing original peer lease and five-second
deadline. It independently checks the declaration/report identity joins,
numeric/Boolean identity, capability/value ranges and freshness/clock
correspondence. Its immutable view can only expire current values as elapsed
client monotonic time grows. The separate refresh method accepts only the Home
ID and checks the existing refresh result without creating a write or route.
Sixty-nine independent socket cases cover all nine freshness states, six value
types, malformed fields/joins/ranges, refresh results and current refusal.
The complete app including the SDK compiles with warnings as errors; app
inventory/SPDX checks pass. No fixture enables physical dispatch.

`NativeThingViewModel` explicitly reads stored state or requests the existing
bounded LIFX refresh. It captures the original credential once, repeats full
controller identity around inspection and rejects a changed principal, epoch,
owner or revision basis. Draft, session and sleep/wake changes fence in-flight
presentation. A display timer only expires already-read values; it makes no
API call. Stored value, current value, trust, quality and complete provenance
remain separate. A lost refresh reply stays unconfirmed; a separate stored
lookup can inspect reports without another probe.

`mix woh.native.thing.panel.smoke` passes ten workflows against a private actual
Store and scripted capture owner: stored, missing, stale, synthetic, revoked,
changed owner, edited target, wake, explicit probe and lost probe followed by
stored lookup. It verifies no startup capture and no automatic retry. Eight
mounted native renders show stale and synthetic evidence at 599, 600, 839 and
840 points. These establish the read/presentation joins, not physical transport
qualification, signed custody or a device effect.
