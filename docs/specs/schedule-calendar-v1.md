# Schedule calendar and time-zone correspondence v1

Version: 0.1.3. Implemented pure calendar calculation, 2026-10-08. WOH.04 owns
temporal admission. This consumes the separately closed
[schedule records](schedule-source-v1.md); it does not install a dataset,
establish trusted time, register a scheduler or create an effect.

The parser accepts immutable non-leap TZif 2, 3 and 4 bytes, at most 65,536
bytes, 4096 transitions, 256 local types and 2048 designation bytes. It bounds
counts before slicing and checks type indexes, strict transition order,
indicator relationships, complete footer framing and footer/last-type
correspondence. The original bytes and their SHA-256 remain in the parsed
value; public use reconstructs it to reject forged parsed fields. The zone
name remains separately bound by the complete schedule source.

Version-one compatibility data is skipped; the 64-bit block determines
offsets. An empty future footer or an unspecified `-00` type refuses outside
the represented range. A constant dataset with no transitions and empty
footer uses its first type. These data rules follow
[RFC 9636](https://www.rfc-editor.org/rfc/rfc9636.html).

Supported footer data includes fixed offsets, explicit daylight offsets,
month/week/weekday rules, Julian rules excluding leap day, zero-based ordinal
rules including leap day, southern and negative DST, second-resolution
offsets and all-year DST. Version 3/4 transition times can extend beyond the
day. Named DST without explicit rules refuses rather than consulting a
platform default. Rules stay inert data; the parser never sets `TZ` or calls
an OS calendar service. Date forms use the
[POSIX environment contract](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap08.html).

Local resolution tries each bounded distinct represented offset and checks the
original UTC-to-local mapping. A gap has no valid instant; a fold returns the
sorted valid instants. Recurring daily/weekday schedules skip gaps and select
the first folded instant once, even when the start/cursor lies between the two.
A one-shot must bind the explicitly chosen valid instant and exact local label;
either folded instant can be reviewed, and a gap cannot be invented as valid.
Every use requires the exact zone name, original bytes and digest.

`Recurrence.next` returns the first instant strictly after its UTC cursor and
within the source's inclusive start/exclusive end. Fixed intervals use direct
anchor arithmetic, including after very long downtime; they never iterate old
ticks or drift from a previous completion. Calendar search considers at most
32 local dates and reports a concrete horizon/undefined-data error rather than
an unbounded scan. Countdowns belong to the separate monotonic window and
cannot enter this UTC recurrence path. The window checker now repeats exact
calendar membership, so a recurring fold's second instant is ineligible.

The frozen authored `Fixture/*` datasets are synthetic, not qualified IANA
releases. Their independent generator uses Python `zoneinfo.from_file` for
207 local resolution cases and 112 recurrence cases, including DST gaps/folds,
weekday/end bounds, southern and negative DST, dates past 2038 and the far
supported year boundary. For 23 ordinal-day cases it instead uses process-local
libc UTC/local round trips under the explicit POSIX fixture. The installed
Python implementation disagrees with POSIX/libc on four zero-based ordinal
boundaries; both results are retained in the corpus rather than altering Home
to match that discrepancy. The generator changes only its child's environment
and does not change an OS preference or clock.

Twenty focused record/calendar tests pass, including complete-byte tampering,
malformed count/index/order/footer cases, one-shot review, changed zone pins,
fold replay refusal, half-open windows and boot/generation expiry. Actual host
tzdata custody/update behavior, qualified clock/sleep bounds, retained temporal
admission and the durable occurrence writer remain separate work. None of this
evidence establishes physical effects or installed-host qualification.

`CalendarReference` now supplies a separate executable reference over the
complete original TZif bytes. It independently parses both headers, skips the
legacy block, constructs half-open UTC phases and parses the closed footer
tokens. Erlang Gregorian-day/second arithmetic and enumerated month weekdays
replace the production ISO date helpers. Local resolution intersects the
requested label with UTC phases; independently computed recurring candidates
retain the first-fold, skip-gap and inclusive-start/exclusive-end policies.
The module calls neither `Tzif`, `TzifFooter` nor `Recurrence`, performs no I/O
and establishes no clock confidence or effect authority. Its decoded values
are inert calculation inputs, not serialized or externally admitted records.

The focused reference/production calendar suites passed 18 tests (seed 593565,
0.3 seconds), freshly compiling 261 Home modules against the locked test cache
without a socket-free filter. The reference independently matches all 230
frozen local-resolution vectors (207 Python and 23 separately labelled libc
ordinal cases) and 112 recurrence vectors. Finite/undefined data, type-zero
boundaries, one-shot fold choices, malformed raw/source inputs and an isolated
process replacing all production calendar calculators are also covered. This
initial commit supplied the reference mechanism. The separately versioned
[v3 qualifier](schedule-admission-v1.md) now compares production recurrence with
its source-bound phase/date probes and consumes its independent prefix.

That comparison exposed a terminal-calendar bug: a valid final UTC cursor or
a positive offset reaching beyond year 9999 returned a conversion error.
Production recurrence now reports no later coordinate for those exhausted
calendars. The change preserves source headroom and never fabricates a later
instant. Undefined TZif phases still refuse rather than becoming exhaustion.
