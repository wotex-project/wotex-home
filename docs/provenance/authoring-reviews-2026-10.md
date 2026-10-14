# Source and fixture review software evidence

Home commit `a4de0ca` implements checked source attribution, authored-envelope
reconstruction and producer-independent original/result/receipt encodings.
Commit `5dfca6f` implements the schema 31 Authority/Store review transaction,
immutable original lookup, retained metadata validation and recovery support.
The owning [review successor](../specs/authoring-reviews-v1.md) is version 0.1.2.
Review is inert: it changes no candidate original, approval, enrollment, grant,
observation or physical qualification.

On 2026-10-14, pinned Elixir 1.19.6 / OTP 28.5.0.6 ran:

- `mise exec -- elixir bin/check_routines_shadow.exs --profile-store-consumer`
  with the three explicit archive/digest pairs below: 21 pure consumer tests
  and 35 actual Home Authority/Store/SQLite/private-custody tests passed.
  The fresh consumer compiles eleven selected Home modules with warnings as
  errors and supplies only its checked dependency ebins to the isolated Store
  process. The test-only dynamic String.Chars protocol restoration is unchanged;
  no application dependency or production loader is modified.
- `mise exec -- mix test` selecting authoring review/candidate/unavailable,
  durable authoring objects/profiles and recovery Store/snapshot suites:
  90 tests passed in 28.6 seconds. No socket exclusion was selected.
- Six location-selected migration cases passed (82 excluded): native target
  schema 22, active controller schema 21, temporal schemas 23/25, qualification
  schema 19 and pairing migration. Fourteen further location-selected legacy
  causal-root/handoff/observation/request/enrollment cases passed (573 excluded).
  These are bounded compatibility checks, not a complete application rerun.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. The first formatting check identified two
  changed schema guards; formatting them resolved it before the final check.

| Selected archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

The fresh consumer lock SHA-256 is
6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
Store fixture source SHA-256 is
bc0749550e14cd40ca27c03ca4f953885e169e0e4271be10ac3429f103c2afc6.
The independent source/ordered-review vectors live in
test/fixtures/profiles/authoring-sources.json and authoring-review.json;
the executable structural schema is priv/profiles/authoring-review.schema.json.

The acceptance cases AR-T1–AR-T8 include independently authored temperature and
unfamiliar density quantities, absent/ambiguous/unresolved attribution, forged native
values, failed independent expectations and duplicate fixture JSON. Actual
Store cases distinguish source-only and complete receipts, unchanged candidate
history, another actor, revocation, current CAS/epoch, changed selected contract,
mismatched capture, unavailable capture and maintenance. Removed producer code,
missing private files, disabled selection and restart preserve exact originals;
new work refuses. An actual SQL trigger proves journal/result/revision rollback
and zero remaining leases. Changed evidence/candidate digests with rewritten
receipt hashes, damaged journal links and orphan events fail correspondence and
fence writes.

Quota cases retain 1024 originals, fill the exact 4-MiB input aggregate and reach
the result aggregate before the count limit using an actual producer-compatible
32-channel candidate with 132 required roots. Direct historical-row fixtures
exercise canonical metadata/resource constraints, not additional source truth.
Refusal preserves revision and original replay. History validation batches
candidate metadata instead of querying a candidate separately for each review.

Actual schema 30 migration preserves candidate receipts and creates no reviews.
Encrypted inclusive and database-only exports retain original review metadata
and honest dependency availability. Inclusive restore verifies the actual new
table and remains quarantined; database-only restore cannot invent private bytes.
Existing retained import/candidate references protect every review dependency.

These checks establish bounded software identity and correspondence. They do
not authenticate a vendor source, detect contradictions in source prose, qualify
a device, install a producer cohort or authorize an active profile. Optional
generation, current v2 admission/observations and host/physical qualification
remain programme obligations. No native suite, full application suite or Dialyzer
was run at this stage. All commits remain local on main.
