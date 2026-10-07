# Bounded schedule consideration v1

Version: 0.1.1. Pure single-schedule calculation, 2026-10-08. WOH.04 owns
temporal admission and WOH.14 owns the future durable cursor and occurrence
transaction. This module changes no Store, grants no clock trust and dispatches
no effect.

The planner consumes a complete source, exact timezone basis where needed,
retained considered-through watermark and host-owned clock sample. UTC
watermarks are inclusive millisecond boundaries, initially at least the
activation instant. They never decrease. A candidate must lie after that
boundary and no later than the UTC lower bound. The complete uncertainty
interval must fit its half-open late window and admitted tolerance for
eligibility. A future due time crossed only by the upper bound emits no early
candidate. An already due candidate with an uncertain interval is considered
once and remains skipped even if a later clock sample becomes precise.

Elapsed windows produce one missed-range pair `[exclusive_previous_boundary,
inclusive_cutoff]`; it summarizes a time range, not a fabricated count of
individual physical outcomes. Cutoff is the greater of the old watermark and
`UTC_lower - late_window`. The planner finds the next coordinate after that
cutoff, never loops over historical ticks and returns at most one candidate.
The successor watermark reaches the current lower bound, preserving the
no-repeat boundary independently of occurrence-row retention. Time correction
backward cannot lower it. Invalid, stale, discontinuous, old-boot or unqualified
clock input returns an error and supplies no successor cursor.

The narrow profile proves at least 60 seconds between coordinates. Fixed
intervals already have that minimum. Daily and weekday forms additionally
require the complete pinned timezone's maximum-minus-minimum offset to be at
most 86,340 seconds: selected local dates differ by at least one 86,400-second
day, so their UTC coordinates differ by at least 60 seconds. This conservative
bound includes both historical types and footer offsets. Wider offset spans
remain unsupported until a separate multi-candidate temporal argument exists.
One-shots and boot-local countdowns have only one coordinate. The maximum
60-second half-open late window consequently cannot contain two candidates.

Countdown watermarks use their original monotonic domain. They emit one eligible
or expired coordinate, and cannot reuse that cursor after boot or clock-generation
change. Same-owner restart may later resume UTC definitions only after the
retained admission is revalidated; the pure planner itself performs no such
owner, grant, activation, restore or maintenance decision.

Six focused tests compare 378 interval/cursor/uncertainty combinations against
independent explicit enumeration, replay and forward/backward correction traces,
an approximately 30-year missed interval range, qualified-wall refusal,
same-definition boot change and countdown expiry, the independent calendar
recurrence corpus, malformed cursors and a valid wide-offset TZif refusal.
These do not establish durable cursor consumption, current Store guard truth,
installed clock qualification or physical execution.
