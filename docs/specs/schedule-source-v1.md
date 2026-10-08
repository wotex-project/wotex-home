# Schedule source and occurrence records v1

Version: 0.1.4. Closed records with pure calendar correspondence, 2026-10-08.
WOH.04 owns
temporal admission; WOH.14 owns the future durable occurrence writer. These
inert codecs and window calculations create no admission, trusted clock,
scheduler registration or effect. The explicit admission profile is unchanged.

All canonical documents are compact JSON arrays, UTF-8, at most 4096 bytes,
three array levels, sixteen members per array and 128 bytes per string. Objects,
floats, negative integers, expanded members and noncanonical bytes refuse.
Identifiers use the existing Home identifier contract. Integers fit signed
SQLite 64-bit; UTC milliseconds are bounded to Gregorian years 1970–9999 with
headroom for the maximum late window. No supplied field becomes executable code,
an atom, a path, a device endpoint or a credential.

Source field order is `["wotex-home.schedule-source.v1", id, source_revision,
author_id, rule_id, rule_source_digest, target_id, resource_revision,
late_window_ms, uncertainty_tolerance_ms, trigger]`. The source SHA-256 commits
these exact bytes. A future writer derives the original author from current
authenticated authority and binds the retained complete rule, declaration,
profile, invariant, runtime and independently admitted temporal proof. Merely
encoding their identifiers cannot establish those joins.
The rule-source digest is SHA-256 of the exact canonical rule-document bytes
carried by the [original operation](schedule-operation-v1.md), independently
of the compiler's domain-bound source and IR commitments.

Trigger arrays are closed:

| Kind | Remaining ordered fields |
| --- | --- |
| `once` | IANA zone, tzdata SHA-256, ISO local date, `HH:MM:SS`, explicitly resolved UTC ms |
| `daily` | zone, tzdata SHA-256, time, inclusive UTC start, exclusive UTC end or null |
| `weekdays` | zone, tzdata SHA-256, time, sorted unique ISO weekdays 1–7, start, end or null |
| `interval` | UTC anchor, integer period ms, start, end or null |
| `countdown` | Store boot ID, clock generation, start monotonic ms, duration ms |

Intervals are 60,000–2,678,400,000 ms; countdowns are 1000–86,400,000 ms. Late
windows are 1000–60,000 ms with zero early tolerance. Admitted uncertainty
tolerance is 0–1000 ms per side. Calendar source decoding does not resolve a
zone or prove that a selected instant matches its local label. That separate
tzdata correspondence is required before temporal admission.

Clock field order is `["wotex-home.schedule-clock.v1", source_id,
qualification_digest, boot_epoch, generation, sampled_monotonic_ms,
utc_lower_ms, utc_upper_ms, maximum_age_ms, drift_ppm, wall_confidence,
monotonic_continuous]`. Wall confidence is qualified or unqualified; unqualified
UTC bounds are null. Qualified wall time or continuous monotonic time requires
a qualification digest, which this codec cannot attest. The actual host owner
must establish its source, uncertainty, maximum age and drift from measured
qualification. No network/client route accepts this record as trusted time.

Advance only in the original boot/generation and a continuous, nondecreasing
monotonic clock, within maximum age (1–600,000 ms). Elapsed time translates the
UTC interval and expands each side by ceiling(elapsed × drift_ppm / 1,000,000),
with drift bounded to 0–1000 ppm. Calendar/interval eligibility requires the
entire interval inside `[due, due + late_window)` and width at most twice the
admitted tolerance. Boundary overlap stays uncertain. A countdown can use
qualified continuous monotonic time with unqualified UTC; boot or clock
generation changes expire its basis.
The separate [retained countdown clock record](schedule-countdown-clock-v1.md)
now checks monotonic-only capture and historical correspondence without
inventing qualified UTC. The actual Store still refuses countdown admission;
its durable expiry and execution obligations remain following work.

Occurrence order is `["wotex-home.schedule-occurrence.v1", authority_epoch,
schedule_id, source_revision, source_digest, rule_generation, coordinate]`.
Coordinates are `["utc", due_ms]` or `["countdown", boot_id, clock_generation,
due_monotonic_ms]`. SHA-256 of these bytes produces `occ:<hash>` and
`cause:schedule:<hash>`. UTC identity excludes the current clock generation so
time corrections cannot mint another identity for the same considered
occurrence. Countdown identity retains its original boot/generation. The
future writer must retain the considered-through boundary across compaction
and repeat current admission and time guards at queue, claim and handoff.

The pure window checker verifies exact interval membership, validated one-shot
label/UTC identity, daily/weekday membership and exact countdown deadline. Every
calendar form refuses without the complete immutable
[time-zone basis](schedule-calendar-v1.md). The bounded resolver skips recurring
gaps and uses only the first recurring folded instant. These calculations create
no Store migration, temporal admission or runtime scheduler registration.

Eight focused tests cover independently calculated Python source/occurrence
bytes and SHA-256 identities, every closed trigger, range and allocation
refusals, immutable source/author binding, boot/generation/clock age and drift,
35 independent window boundary/tolerance pairs, exact recurrence membership
and countdown expiry without qualified wall time. These are software
correspondence cases. They do not establish qualified host time, retained
temporal admission, crash-safe occurrence consumption or physical execution.
