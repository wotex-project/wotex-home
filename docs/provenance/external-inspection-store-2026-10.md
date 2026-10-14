# Durable external inspection software evidence

Commit `fd03305` freezes schema 32 before implementation; `bfd4427` implements
its inert Authority/Store transaction, current trusted reader selection, original
input/result/receipt journaling and recovery. The owning
[inspection successor](../specs/external-inspections-v1.md) is version 0.1.3.
The [pure preparation record](external-inspections-2026-10.md) independently
binds the prior reader, frame, closure and encoding components.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- `mise exec -- elixir bin/check_routines_shadow.exs --profile-store-consumer`
  with the distinct archive/digest pairs below: 34 pure archive cases and
  47 actual Home Authority/Store/SQLite/private-custody cases passed. The fresh
  consumer compiles seventeen selected Home modules with warnings as errors.
  The isolated Store process loads only the verified archive dependency ebins;
  the existing test-only dynamic String.Chars protocol restoration is unchanged.
- `mise exec -- mix test` selecting external inspection, authoring review/
  candidate/default-unavailable, durable authoring objects/profiles and recovery
  Store/snapshot suites: 94 tests passed in 39.5 seconds. No socket exclusion
  was selected. The six location-selected historical schema 19/21/22/23/25 and
  pairing migrations passed (82 excluded).
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No full application/native suite, Dialyzer,
  release, installed transport or physical device qualification was run.

| Selected archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

The fresh consumer lock SHA-256 remains
6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
Actual Store fixture source SHA-256 is
012e00dcf64705b3afb0d3e6111f8326b69bef4b4fe6c1cc9213d655a4145e68.
The stateless external writer source SHA-256 is
3f780fe96bb80ebe1aa1a6e69b468704a508d0fd8432d7170734fcfee342d2d8.

Twelve new Store cases join the prior 35 authoring cases. Both independent
quantities import exact envelope/profile/definition frames and retain separate
inspection originals. Exact retry/status, changed-input conflict and separate
review namespace are tested. Another actor, stale CAS/epoch/first revision,
wrong owned kind and changed reader basis refuse. Missing bytes cannot create
a successor and every lease releases; retained originals survive missing files,
disabled reader and restart. Removal of the public Binding implementation proves
original lookup uses historical metadata while new work returns unavailable.
Maintenance blocks new work but preserves originals; revocation blocks reads.

An actual SQLite trigger rolls back result, journal and revision with zero leases.
A changed raw document identity with a rewritten result/receipt hash still fails
retained import correspondence and fences writes. Actual schema 31 migration
preserves existing review receipts and creates an empty inspection table.
Encrypted inclusive/database-only exports preserve original metadata and honest
dependency availability; inclusive restore verifies schema 32 in quarantine and
database-only restore cannot invent private bytes. Existing imports protect all
inspection bytes, without a new byte owner or provider path.

Quota cases retain 1024 originals and fill each aggregate until another original
would exceed 4 MiB, separately for input and result below the count limit.
The input case uses a sparse high-revision canonical metadata fixture so wide
first-import references consume input bytes without consuming result bytes.
The result case uses closed bounded result metadata and then small originals to
reach its final boundary. These direct historical-row fixtures exercise metadata/
capacity guards, not additional producer compatibility or source truth. They
preserve deep actor/import/journal/receipt correspondence; exact replay remains
available and refusal preserves revision and zero leases.

The first recovery milestone found a missing schema 32 branch in retained profile
selection validation. Adding that branch made the targeted case and repeated
94-test milestone pass. The first input-quota fixture unintentionally exhausted
the result budget first; isolating it with wide original references resolved
the fixture before the final 47-case Store run. Formatting corrected two expanded
schema guards before the final passing check.

The inspection receipt establishes supplied read-only mechanics and historical
identity. It does not authenticate the source, approve trust, enroll/select a
Thing, renew an observation, widen a grant, activate a routine or qualify hardware.
Operator routes and the current v2 trust/selection/observation lifecycle remain
owning obligations. Producer dependency pins are unchanged and all commits remain
local on main.
