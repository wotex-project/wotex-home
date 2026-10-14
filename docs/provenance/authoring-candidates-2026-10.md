# Durable manual candidate software evidence

Home commit `8d0782f` freezes bounded original/receipt/assessment encodings;
`3e8f6a6` adds schema 30 manual candidate journaling, original replay, derived
bundle retention and recovery. The owning successor is
[authoring-candidates-v1](../specs/authoring-candidates-v1.md) version 0.1.0.
Compatibility remains a proposal; source review and independent fixture
comparison are separate outcomes and confer no current selection authority.

On 2026-10-14, pinned Elixir 1.19.6 / OTP 28.5.0.6 ran:

- `bin/check_routines_shadow.exs --profile-store-consumer` with the exact core,
  Runtime and Profiles archives below: 17 pure envelope/mechanics/fixture cases
  and 17 actual Home Authority/Store/SQLite/custody cases passed. The isolated
  producer consumer compiles seven selected Home modules with warnings as errors;
  the following Home test process uses its checked producer/dependency ebins.
  It restores the original dynamic Elixir String.Chars protocol because Home's
  ordinary consolidation predates the optional ExJsonSchema implementation.
  No production dependency, loader fallback or protocol configuration changes.
- Candidate codec/default-unavailable checks: four tests passed, including
  Python-generated exact ordered vectors, depth/node/member/string/byte budgets
  and no assessment without a trusted selected host contract.
- Candidate/import/profile/recovery/snapshot/maintenance milestone: 104 tests
  passed. Twelve targeted historical migration/refusal cases passed (93 excluded),
  retaining schemas 19/20/22/23/25/26 and pairing collision rollback. No whole
  application/native suite or Dialyzer was run for this stage.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  check and Git whitespace checks passed.

| Selected archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

The fresh producer consumer lock SHA-256 is
6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
Actual Store fixture source SHA-256 is
9122d7d9f4b0ed3ed70a61574ab15ff4a7e902dd346599894707562a808a7464.
The checked command takes explicit --core-archive/--core-sha,
--runtime-archive/--runtime-sha and --profiles-archive/--profiles-sha pairs;
it neither resolves a neighboring producer checkout nor starts Home's host.

Cases cover both independent quantities, invalid syntax/selector reports,
exact replay/conflict, removed required producer function, missing bytes,
disabled configuration/restart, permission/revocation/maintenance/CAS/epoch,
owned reference kind/revision, SQL-trigger rollback/orphans and released leases.
Receipt, assessment, journal and source-reference corruption fence writes.
Real inclusive/database-only exports retain dependency availability honestly
and restore in quarantine; collection preserves candidate bundle references.

Quota cases retain 1024 originals and exact 4-MiB input/assessment byte totals,
then refuse a new operation. Their direct SQLite metadata fixtures exercise
retained representation/integrity bounds, not additional producer truth. Real
imports fill 128 shared frames and the exact 4-MiB complete-frame budget; new
bundle/source publication refuses. A missing retained bundle cannot let a v1
approval bypass the shared logical count or turn capacity refusal into Store
corruption. Published bytes do not imply source review or physical correctness.

The first Store run exposed a missing schema-version dispatch entry; it was
fixed before this evidence. The initial archive-backed loader also exposed
Home's consolidated protocol omission; the isolated dynamic protocol and a
temporary correctly named test copy resolved it. Final runs above passed.
Installed producer adoption, durable source/fixture review, optional provider
policy/attempt/handoff, current v2 admission and physical qualification remain
owning programme obligations. All commits remain local on main.
