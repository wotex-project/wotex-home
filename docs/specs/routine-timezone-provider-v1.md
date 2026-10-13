# Immutable timezone provider for routine calculation

Version: 0.1.0. Updated: 2026-10-13. Accepted consumer join.
Owner: WOH.20 H20-02/07/08 and H20-T7; schedule-calendar-v1 owns Home TZif semantics.
Implementation: pure provider and extracted-archive join implemented.
Evidence: 230 retained vectors, five archive cases and focused software refusals;
full temporal Store/admission and physical cases remain open.

## Purpose and dependencies

The optional calendar calculation seam must consume Home's exact retained TZif
bytes without installing a global database, reading a file or changing Calendar's
application environment. ExBooking SP.08 owns original occurrence enumeration
and its explicit immutable TimeZoneProvider. WoTEx WRO.03 owns the direct calendar
adapter and its cursor binding. Home owns the retained zone name/data, supported
coordinates, source/occurrence identities and later clock/authority decisions.

This is an additive pure provider for calculation. It does not register a
scheduler, select an application dependency, change v1 schedule/occurrence
encodings or enable a routine/scheduled effect. Existing Recurrence/Store
admission/claim/handoff paths keep their qualified implementation. Full temporal
extraction, pinned runtime adoption and durable correspondence remain separate
entry gates. The published ExBooking 0.2.3 archive lacks the provider API; an exact
inspected development archive must be supplied until a successor is released.

## Values and limits

`WotexHome.Schedules.RoutineTimezone.provider(zone)` takes a fully checked Home
Tzif value and returns the producer's checked TimeZoneProvider or a typed atom
refusal. A forged parsed field, mismatched original bytes/digest, unsupported
name or missing producer rejects. The provider has the existing Home module
as its installed callback, and an explicit immutable binary context:

`<<"wotex-home.tzif-provider.v1", 0, name_size::unsigned-big-16, name::binary-size(name_size), tzif_bytes::binary>>`.

Name is 1–128 bytes and must satisfy the existing closed zone-name grammar.
TZif bytes are 44–65536 bytes with the existing bounded 2/3/4 parser, 4096
transitions, 256 types and 2048 designation bytes. No trailing provider field,
mutable registry, module name from text or caller-supplied function exists.
Every callback decodes the complete retained bytes again; the context cannot
substitute forged parsed tables. Requested zone must exactly match the name.
The producer separately bounds/revalidates its whole native provider value.

`resolve(nominal, zone_name, context)` implements the public producer callback.
Nominal is ISO-calendar, year 1970–9999, with whole seconds and precision `{0,0}`.
Use Home Tzif resolution: zero instants returns `:gap`, one returns `{:ok, local}`,
two return ordered `{:ambiguous, first, second}`. More than two refuses
unsupported_timezone_multiplicity. Local datetimes retain every nominal field
and the exact zone name. Installed total offset is represented as utc_offset,
std_offset zero, with the exact designation; no DST identity is inferred from
that normalization. ExBooking uses the total offset/instant for its contract.
Offsets outside ±86400 seconds refuse unsupported_timezone_offset, because
Home's wider TZif parser bounds cannot be silently narrowed by conversion.

`localize(datetime, zone_name, context)` implements the second callback. Input
is a structurally valid ISO DateTime. Normalize its instant with the explicit
UTC-only database, obtain the exact Home offset at its integral millisecond
coordinate, then construct the local fields while preserving the original
microsecond value/precision and UTC instant. This permits fractional query
endpoints without allowing fractional recurrence labels. Undefined timezone
phases and coordinates outside Home's UTC headroom refuse; they cannot become
gaps or fabricated exhaustion. Producer validation independently checks the
returned datetime and original instant.

Both callbacks are deterministic and perform no I/O, process, clock, random or
ambient environment operation. Bad context/coordinates return
invalid_timezone_projection; unsupported precision/year returns
unsupported_timezone_coordinate; name mismatch returns timezone_basis_mismatch.
Missing producer returns routine_timezone_unavailable; invalid input zone returns
invalid_timezone_data. Existing Tzif undefined-data errors remain explicit.
Errors do not retain raw context, hardware identities or paths.

## Identity, failure and compatibility

The outer Calendar cursor binds the callback module and SHA-256 of exact context;
ExBooking's inner cursor retains/checks the full native provider and its context.
Changing a zone name, original bytes, producer cohort or clock projection requires
a fresh query, and old continuations refuse. The consumer retains original
schedule source/revision/authority epoch/rule generation and uses unchanged
Occurrence.build/identity for its original IDs. Generic recurrence ordinal or
projection generation must not replace those Home identities.

Provider construction/lookup supplies calculation only. Trusted UTC confidence,
considered-through watermark, complete current authority and final handoff window
still belong to the single Store. A callback result is neither clock confidence
nor a reviewed mapping/grant. Restore does not activate a definition. Logical
calculation retry returns the same values; persistent no-repeat accounting remains
outside the provider. No durable schema changes in this join.

## Acceptance

| Case | Stimulus | Expected observation / falsifier | Evidence |
| --- | --- | --- | --- |
| RTZ-T1 | Exact synthetic TZif fixtures, every independent local-resolution vector | Public callback returns the original UTC instants or exact gap; compare independently parsed CalendarReference and retained Python/libc expectations | Pure software |
| RTZ-T2 | Named gap/fold calendar pages through four supplied exact producer archives | Original nominal/UTC/resolution agrees with independent expectations; selected second-fold DTSTART survives; pages retain Home occurrence bytes/IDs | Extracted-archive software |
| RTZ-T3 | Change name/data with an old cursor, tamper context/native Tzif, truncate framing or supply unsupported offsets/precision | Typed refusal; no fallback, stale continuation or altered original | Pure/archive software |
| RTZ-T4 | Two providers concurrently; fractional query endpoint and missing producer | Independent immutable data, exact precision; no global database mutation or implicit source selection | Pure/archive software |

Copy/compile the actual Home source closure in the fresh archive consumer; name
all source/fixture/archive/lock digests and the supported profile. Existing
restricted Boolean shadow comparison must still pass after its harness is
extended. Existing schedule recurrence/clock/occurrence tests remain unchanged;
passing provider vectors is not full scheduler extraction, actual Store race,
installed-clock or physical qualification.

The standalone archive harness selects `--temporal-consumer`, the original three
archive/SHA pairs, and `--ex-booking-archive`/`--ex-booking-sha`. Every argument
is required exactly once in this mode. Digests are lowercase SHA-256 of the exact
Hex archive files, verified before extraction/dependency resolution. The existing
32 MiB archive, 16 MiB inflation, 2048-member safe-relative regular-file/directory
bounds apply independently to all four producers. No links or traversals execute.
The fresh consumer selects only extracted paths with env=prod, starts no Home
application, and copies these actual source files under lib/wotex_home:
`id.ex`, `profiles/codec.ex`, `schedules/codec.ex`, `schedules/tzif_footer.ex`,
`schedules/tzif.ex`, `schedules/calendar_reference.ex`, `schedules/occurrence.ex`
and `schedules/routine_timezone.ex`. The original vector bytes and consumer test
are also copied with their digests. Existing restricted mode still requires its
six original arguments and unchanged Boolean comparison profile.

The [executed cohort](../provenance/routine-timezone-2026-10.md) records the exact
source/fixture/archive/lock/toolchain bindings and evidence limits.
