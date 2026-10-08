# Independent bounded calendar consumption traces v1

Version: 0.1.0. Software correspondence, 2026-10-08. WOH.04 owns temporal
admission; WOH.14 owns occurrence consumption and retained history. This adds
no autonomous runner, countdown admission, schema or physical dispatch.

The [independent reference machine](schedule-runtime-traces-v1.md) now also
accepts a closed finite calendar timeline. Its five exact inputs are sorted
unique UTC instants, exclusive horizon end, initial considered watermark,
late window and uncertainty tolerance. One to 64 instants are bounded to the
supported UTC domain and separated by at least one minute. The constructor
rejects expanded fields, invalid bounds, duplicates and reordered data. It
imports no Home recurrence, planner, guard, writer, clock or transport code.
Calendar selection comes from a separate oracle, not from the writer's result.

The executable
[fourteen-trace corpus](../../test/fixtures/schedules/calendar_durable_trace_vectors.json)
has a closed calendar-consumption software scope. Its
[Python generator](../../test/fixtures/schedules/generate_calendar_durable_vectors.py)
uses `zoneinfo.from_file` over the existing frozen authored TZif bytes. Daily
and selected-weekday sources have an explicit exclusive end so their complete
timeline can be enumerated independently. One-shots bind an explicitly chosen
valid instant. It covers Stockholm and New York folds and gaps, weekly first-fold
selection, both reviewed Stockholm one-shot choices, uncertain consumption
without later retry, repeated/backward polls, consumed-coordinate restart,
one bounded month of missed work and a start between the two folded instants.

The actual SQLite harness selects the corresponding installed IANA dataset
through Home's existing read-only custody. Before admission, a separate Python
process checks those complete bytes and the exact source trigger against the
entire frozen expected timeline. A changed dataset or missing installed zone
fails the check rather than being replaced or silently ignored. Original source,
artifact and historical receipts bind the actual selected bytes and digest;
the authored `Fixture/*` definitions never become installed authority.

The existing public Store boundary retains admission. Synchronous borrowed
writer fixtures then run the actual lifecycle and occurrence transactions with
controlled typed clock/timezone inputs, under the original Store scope. They
preserve single-writer serialization and repeat the actual author, declaration,
artifact and generation guards. Clock inputs are software fixtures, not
qualified sources; the public default remains unqualified after actual Store
restart. No Store or host API acquires a test option or alternate timezone root.
An explicit refusal case verifies that a controlled synthetic activation is
withdrawn with its original timezone-basis reason and no occurrence or request.

After every event, an independent read-only SQLite projection checks generation,
considered watermark, occurrence/range counts, missed instants, original held or
blocked dispositions and causal reservation against the reference machine.
Empty/repeated polls and restart preserve revision. Full snapshot integrity and
complete immutable consideration/effect rows are checked separately, alongside
principal-private original lookup. Long downtime creates one missed summary and
at most one current held effect, without a catch-up burst or reused coordinate.

This is bounded calendar **consumption** evidence. The existing interval corpus
owns execution-phase, author/grant, override, maintenance and publication-fault
traces; those broader phases are not inferred for every calendar source here.
The current temporal basis still has calculation/guard scope. A complete
source-bound autonomous runtime argument, countdown lifecycle, composed sets,
cursor compaction and actual installed clock/sleep and hardware qualification
remain required before autonomous delivery. No packet, timer, Keychain item,
OS timezone preference or service registration is changed by this corpus.

On 2026-10-08, 44 focused reference/calendar/planner tests passed, followed by
the explicit synthetic-authority refusal and an existing actual Authority/Store
interval trace: 46 selected tests, zero final failures. The first harness run
correctly withdrew uninstalled synthetic zones; its cleanup race was corrected
and actual installed bytes gained the independent check above. A later read-only
projection omitted the original uncertainty reason; the projection was corrected.
No production lifecycle or occurrence writer was changed for either correction.
The frozen fourteen-trace corpus regenerates byte-for-byte.
