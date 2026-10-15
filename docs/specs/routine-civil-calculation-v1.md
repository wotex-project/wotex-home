# Immutable civil calendar calculation v1

Version: 0.1.0. Updated: 2026-10-15. Status: accepted target.
Owner: WOH.20 H20-02/07/08 and H20-T7; WOH.04 owns temporal admission.
Implementation: RCC-01–03 provider implemented; RCC-04–05/public archive join planned.
Evidence: direct Home provider checks pass; actual Home civil archive and runtime
adoption cases remain open.

## Purpose and dependencies

Home must preserve its supported calendar labels while consuming the public
ExBooking SP.09 civil query through WoTEx WRO.03. A repeated local time may have
more than two instants. Home's TZif offsets span -89999 through 93599 seconds;
the existing RRULE provider's narrower bounds cannot represent every such input.
This contract owns the pure immutable provider and finite Home calculation join.
The [runtime adoption contract](routine-temporal-runtime-v1.md) separately owns
dependency selection, current compiled-code correspondence and Store guards.

ExBooking at inspected source `16a9d0d` implements TimeZoneProvider.new/2,
resolve_civil/3 and civil_occurrences/3 under SP.09 CIV-06. A complete ambiguity
has 2–732 candidates; the whole query permits 366 resolutions and 732 round-trip
localizations. Every alternative validates before policy/filtering; refusal
returns no partial result. WoTEx at inspected source `f3e77a43` implements the
closed Schedule, CivilRequest, CivilPage and Civil seams under WRO03-06–09.
Local positions 3–732 project as `["fold", index]`. These source revisions are
producer evidence, not Home dependency selection or execution authority.

## Immutable provider

**RCC-01 — Distinct purpose.** `Schedules.CivilTimezone.provider(zone)` accepts
an exact, fully revalidated Home Tzif value. It returns the public producer's
native TimeZoneProvider with this Home module and binary context, or an atom
refusal. The legacy RoutineTimezone module, context and callbacks stay unchanged.
The new context is exactly:

`<<"wotex-home.civil-tzif-provider.v1", 0, name_size::unsigned-big-16, name::binary-size(name_size), tzif_bytes::binary>>`.

Name is 1–128 bytes under Codec.zone?'s closed grammar. Original TZif bytes are
44–65536 bytes, versions 2/3/4, with at most 4096 transitions, 256 types and
2048 designation-block bytes. Each type designation is at most 32 bytes; footer
designations retain their existing 3–6-byte grammar. Every callback decodes the
complete context again. A forged parsed value, wrong tag, truncated/trailing
bytes or mismatched name cannot substitute another dataset. No registry,
environment, process, filesystem, clock or random source is consulted.

Construction checks the public provider constructor and civil facade are
available. Missing capability returns routine_timezone_unavailable. The required
legacy resolve/3 callback always returns unsupported_timezone_profile; the new
provider cannot silently enter RRULE enumeration. The optional resolve_civil/3
callback owns complete civil resolution. Public old-provider helpers keep their
own bounds and are never an intermediate conversion for this profile.

**RCC-02 — Complete resolution.** resolve_civil(nominal, name, context) requires
an exact native ISO NaiveDateTime in years 1970–9999, valid date/time, whole
seconds and precision `{0,0}`. Extra native fields refuse. Resolve through the
retained Home Tzif bytes. Zero supported instants returns :gap; one returns
`{:ok, local}`; two or more return `{:ambiguous, locals}` as a proper, complete,
strictly UTC-ordered list. Do not reduce a threefold ambiguity to two or choose
a policy in the provider. There are at most 258 distinct represented offsets
(256 types plus at most two footer offsets), hence at most 258 candidates.

Each local DateTime retains every nominal field, exact zone name/designation,
the installed total offset in utc_offset and std_offset zero. Normalization does
not invent a standard/daylight identity. The instant is unchanged. Existing
Home resolution excludes UTC coordinates outside 0–253402300739999 ms; an empty
supported set remains a gap under that profile. Undefined represented phases
still refuse; they cannot be changed into gaps or exhaustion.

**RCC-03 — Round-trip localization.** localize(datetime, name, context) accepts
an exact native, valid ISO DateTime in years 0000–9999. Its UTF-8 timezone name
is 1–256 bytes and abbreviation 0–256 bytes; offset components are integers in
-93599..93599 seconds and their sum in -89999..93599 seconds. Normalize with the
explicit UTC-only database, require its floor integral millisecond coordinate
(DateTime.to_unix at :millisecond) in Home's supported UTC range, and
obtain the retained offset at that instant. Construct the local fields with the
exact name/designation, total offset and std_offset zero. Preserve microsecond
value/precision and the UTC instant. Local fields may reach 1969 at the lower
UTC boundary; civil labels themselves still require years 1970–9999.

Invalid native/context values return invalid_timezone_projection; valid native
nominals outside the supported year/precision profile, UTC instants outside
Home's floor-millisecond range, or local projections outside ISO years 0000–9999
return unsupported_timezone_coordinate; mismatched names return timezone_basis_mismatch.
Invalid source Tzif values return invalid_timezone_data. Existing undefined-data
errors remain explicit. No error includes raw bytes, paths or private identities.
The operation owns no state, timeout, cancellation or retry resource.

## Public finite calculation join

**RCC-04 — Exact projection.** `Schedules.RoutineCalendar.resolve(source,
nominal, zone)` returns `{:ok, sorted_utc_ms}` or an atom refusal. Validate the
closed Home source and exact name/digest/bytes against its calendar trigger.
Nominal has RCC-02's shape and must match the source's literal clock; for a
one-shot its date must also match. Daily and one-shot use weekdays 1–7; a weekday
source retains its complete explicit day set. A nonselected weekday returns an
empty result after input validation. Interval/countdown inputs refuse this seam.

Construct the complete WRO.03 civil schedule: format wotex.routines.schedule@1,
kind civil, schedule_id equal to the Home source ID, exact late_window_ms,
literal clock, complete weekdays, exact zone name, time_zone_basis equal to
`"sha256:" <> zone.digest`, gap_policy skip and fold_policy both. producer_basis
is `sha256:` plus lowercase SHA-256 of the exact UTF-8 literal
`wotex-home.routine-civil-calculation.v1`. This declares the calculation profile;
it is not the installed-code digest. Compute definition_digest through public
Schedule.semantic_digest/2, then construct the checked public CivilRequest.

The query has first_date equal to nominal's date, days 1, from
`1970-01-01T00:00:00Z` and until `9999-12-31T23:59:00Z`. This is Home's entire
supported UTC range with an exclusive endpoint. Source start/end and the current
cursor are deliberately not substituted: the caller must distinguish a gap
from a selected first instant already outside its source bounds.

Use public Limits.new/1 with exactly max_bytes 1048576, max_depth 32, max_nodes
100000, max_string_bytes 65536, max_collection_size 1024 and max_integer
9223372036854775807. Time is explicitly clock_generation `civil-calculation:1`,
epoch `civil-calculation:1`, elapsed_ms 0 and null utc_low_ms/utc_high_ms. These
inert constants supply no clock confidence or generation of an admitted schedule.
Call only Civil.page/3. Revalidate a complete proper output list of at most 258
original due_ms coordinates, strictly increasing and within Home's UTC range.
Require the exact native CivilPage envelope, its retained request/time equal to
those supplied, and closed WRO.03 point fields without an ordinal. Each retained
nominal matches the requested label, starts_at is UTC and agrees with due_ms,
and resolution is unique for a singleton or a complete contiguous first/second/
`["fold", index]` sequence for an ambiguity. The full-range query cannot filter
any supported candidate. No generic original, ordinal, event, database basis or projection clock replaces
the existing Home Occurrence encoding/ID. This seam returns only those UTC ints.

Missing public seams return routine_calendar_unavailable. Exact civil_work_bound
maps to routine_calendar_work_bound; other producer refusals map to
routine_calendar_refused, including undefined data refused inside a callback.
This explicit producer refusal replaces that callback's private error payload;
it must never become a successful empty list. Malformed native/projected output and implementation
faults map to invalid_routine_calendar_projection. Never return partial results,
log producer payloads, retry another callback or fall back to the old calculator.
Identical supplied source/nominal/bytes produce the same result.

**RCC-05 — Preserve consumer recurrence policy.** Runtime adoption delegates
calendar label resolution to RCC-04. Seed localization and Home source/window
policy remain Home-owned. Search at most 32 successive local dates in their
current local-date order. Resolve selected labels one at a time; do not replace
that order with the global earliest UTC point from a 32-date batch. Select the
complete set's first instant before checking cursor/start/end. A passed first
fold never substitutes its second/third instant. Check exclusive end before
choosing a candidate; a first instant at/after end terminates the search.
Gaps advance a date, undefined data refuses, and final-year exhaustion returns
nil without advancing beyond 9999-12-31. All other exhausted searches retain
calendar_search_horizon. At most 32 producer calls and 8256 round trips occur
in one search, with every single-label query below the producer work ceiling.

One-shots still accept an explicitly reviewed instant from any position in the
complete set. Membership repeats the exact source/date/time/weekday and first
position for recurring labels. UTC intervals retain their strict-after integer
arithmetic; countdowns keep their separate boot/monotonic path. No source or
occurrence bytes, durable original, watermark, retry or eligibility rule changes.

## Implementation entry and acceptance

RCC-01–04 may be built and compared through exact extracted producer archives
before dependency selection. Existing Recurrence remains authoritative until
the runtime contract's cohort/current-basis gates are implemented. There is no
automatic optional fallback when runtime adoption occurs. The archive harness
adds a distinct --civil-consumer mode requiring the existing four archive/SHA
pairs exactly once, with unchanged safe extraction bounds. It freshly compiles
the actual CivilTimezone/RoutineCalendar source plus the existing temporal source
closure and Recurrence. Existing --temporal-consumer and restricted modes remain.
Every consumer/archive/patch scratch directory is removed on success or failure.

| Case | Requirements | Stimulus / expected observation and falsifier | Evidence |
| --- | --- | --- | --- |
| RCC-T1 | 01–03 | All 230 frozen local-label vectors and independent CalendarReference preserve every UTC instant, exact zone/designation and fractional round trips; forged native/context/name/data refuses | Pure/archive |
| RCC-T2 | 02–04 | Literal threefold fixture and 256-type/258-offset bound, both extreme offsets, inclusive UTC zero/final headroom, gaps and undefined data; no missing alternative, narrower helper or metadata change | Pure/archive |
| RCC-T3 | 04–05 | All 112 retained recurrence vectors plus independent raw-phase/Gregorian reference; exact old/new next and membership/Occurrence bytes agree, including a cursor between folds, multi-day offsets and nonmonotonic UTC order across local dates | Archive |
| RCC-T4 | 01–04 | Missing old release, bad native input, malformed/refusing producer and exact work refusal; closed errors, no fallback, partial result, ordinal or implicit clock trust; old RRULE provider remains unchanged | Pure/archive |
| RCC-T5 | 05 | Maximum 32-date search, final year, exact start/end, one-shot later-fold membership and repeated immutable queries; no unbounded scan, second-fold substitution, changed original or false exhaustion | Pure/archive |

These cases establish pure calculation only. Current Store races, compiled-code
changes, installed clock/sleep and physical qualification have separate owners.

## Sources

The inherited Home behavior is [schedule-calendar-v1](schedule-calendar-v1.md)
and [routine-timezone-provider-v1](routine-timezone-provider-v1.md). Producer
contracts are [SP.09](../../../ex_booking/docs/specs/SP.09-civil-occurrences.md)
and [WRO.03](../../../wotex/docs/packages/wotex-routines/specs/WRO.03-temporal-host.md).
Their [renewed archive cohort](../../../wotex/docs/packages/wotex-routines/provenance/civil-time-cohort-2026-10.md#complete-ambiguity-renewal)
establishes producer software evidence, not this consumer's acceptance.

## Executed provider subset

On 2026-10-15, `mix test test/wotex_home/civil_timezone_test.exs
 test/wotex_home/routine_timezone_test.exs test/wotex_home/schedule_timezone_test.exs
 --warnings-as-errors` passed 17 tests (seed 282764), using Elixir 1.19.6/OTP
28.5.0.6 and unchanged locked dependencies. The six new direct-provider cases
exercise all 230 frozen labels, independent raw-phase resolution, literal
threefold coordinates, 256 simultaneous alternatives, a 258-offset input set,
both extreme signed offsets, exact 32-byte metadata, fractional/final headroom,
gap versus undefined phases, malformed native/context values and producer
absence. The old RRULE provider's threefold refusal remains unchanged.
These are direct callback checks. The current locked producer lacks the new
public civil capability; actual public-provider construction and WRO.03/Home
archive consumption remain separate acceptance work.
