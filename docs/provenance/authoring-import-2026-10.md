# Durable authoring import software evidence

Home commit `998688b` adds schema 29 actor-owned tagged-object imports, immutable
original receipts, retained collection references and encrypted inclusive
WOHBK3 backup framing. Inputs/receipts are closed ordered encodings; Python
vectors retain an independent encoding oracle. Custody verifies actual payloads
and holds a typed lease through the single Store transaction.

On 2026-10-14, pinned Elixir 1.19.6 / Erlang OTP 28.5.0.6 executed:

- The authoring import, archive and actual SQLite suites passed 16 tests.
  Cases cover exact replay after missing bytes/restart, conflicting originals,
  distinct actor ownership, permission/revocation/CAS/epoch refusals, maintenance,
  actual SQL-trigger rollback with an inert orphan, the 1024-operation bound,
  retained collection, corrupted receipts/first revisions/orphan journal events,
  schema 28 migration and authenticated inclusive/database-only quarantine restore.
- The authoring, durable profile and recovery Store suites passed 69 tests before
  the additional corruption/maintenance cases. Historical fixture corrections
  passed 73 tests in their five affected suites, and the sixth occurrence
  migration case passed separately (31 other cases excluded).
- A schema milestone ran 861 tests in the 18 affected historical-schema suites
  plus the import/custody/archive/recovery components: six failed and one was
  skipped. All six failures were old fixtures that downgraded user_version while
  retaining the new tables. Their corrected fixtures passed the targeted checks
  above. The milestone was not repeated; this record does not claim a full green
  rerun. It also exposed and prompted fixes to three version lists and the
  snapshot identifier validator's rejection of digits in `payload_sha256`.
- Format, warnings-as-errors compilation, the 22-contract catalogue check and Git
  whitespace checks passed. No native packaging or Dialyzer was run for this stage.

Actual-root and SQLite checks establish software behavior, not power-loss or
physical qualification. Imported objects establish possession and actor-owned
byte references, never source truth, candidate assessment, provider permission
or active selection. Retained histories survive restore only in quarantine;
generation and physical dispatch remain under their separate requirements.

Follow-up commit `ae49f57` batches operation-to-journal/principal link validation
into one bounded join while keeping canonical receipt and ownership checks.
The import/archive/source-passage/Store suites passed 25 tests after this change,
including an authenticated read at the exact 1024-operation ceiling and the
existing corruption/rollback/recovery cases. Format, compilation, catalogue and
Git whitespace checks passed again. This reduces query count; no production
latency or physical-storage performance is claimed.
