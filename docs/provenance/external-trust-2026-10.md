# Exact external trust software evidence

The [owning trust contract](../specs/external-trust-v1.md) froze requirements in
`31165cf`, independent ordered-array identities in `7946792`/`e79629d`, pure
preparation/codecs in `f51ad2e`, and durable schema 33 behavior in `74ff982`.
Local digest approval remains separate from target selection, observations,
grants, routines and physical qualification. V1 policy is unchanged.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- `mise exec -- elixir bin/check_routines_shadow.exs --profile-store-consumer`
  with the distinct three archive/digest pairs below: 35 pure archive cases and
  67 actual Home Authority/Store/SQLite/private-custody cases passed. The fresh
  consumer compiles nineteen selected Home modules with warnings as errors.
  The isolated Store process loads only verified archive dependency ebins.
- `mise exec -- mix test` selecting external trust, external inspection, durable
  profiles and recovery Store/snapshot suites: 77 tests passed in 28.5 seconds.
  No socket exclusion was selected. Six location-selected historical schema
  19/21/22/23/25 and pairing migrations passed, with 82 cases excluded.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No full application/native suite, Dialyzer,
  release, installed transport or physical qualification was run.

| Selected archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

Fresh consumer lock SHA-256 remains
6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
Actual Store fixture source SHA-256 is
e1f7fe74bf84ffb8e1215d1611e3c36a2b2473219c54c90152b07b4c82928f20;
stateless trust writer SHA-256 is
be5b8c2c7bffdf57f86f1f6996e1f43ee2b9a6ff0f5bcdeb3c5b588169c11884.

Twenty trust cases extend the prior 47 Store cases. Both independently authored
quantities approve/revoke/reapprove with immutable originals and first metadata.
Cross-actor reapproval requires that actor's own byte imports and inspection.
Same labels cannot replace revoked raw bytes. Stale epoch/CAS/counters/reference,
wrong actor/digest, absent maintenance, duplicate state, missing files and changed
checked host capture refuse without advancing history or retaining a lease.
Removing the actual public Binding module preserves exact original lookup and
metadata-only revocation while new approval reports producer unavailability.
Withdrawal reports author_unavailable, denies that actor's original reads and
allows another current manager to revoke without source access.

An actual SQL trigger rolls back first manifest, journal and policy counter.
Tampered manifest labels, counters, journal and orphan events fail deep historical
correspondence and fence writes. Actual schema 32 migration retains inspection
originals, creates empty trust tables and initializes separate policy generation
zero. Inclusive/database-only encrypted archives preserve history in quarantine
and report byte availability honestly. Normalized older transfer snapshots declare
empty new tables and zero external policy without manufacturing approval.

Capacity checks cover 64 genuinely imported/inspected/approved artifact closures,
1024 alternating retained decision originals, and the 4 MiB outcome ceiling below
the original count using one genuinely checked 29-channel closure. Additional
alternating rows are canonical historical metadata fixtures, not new producer
truth. Legal maximal input field widths cannot exhaust the separate 4 MiB input
budget before 1024 originals. Refusals preserve revision, original replay and zero
leases. The reader's 32-reference ceiling includes profile, binding and decoder;
the first 32-definition test correctly refused and was replaced by 29 definitions.
Two test-fixture repairs regenerated the changed capture digest through public
Capture.digest/3 and restored immutable custody mode 0400 after a missing-file
probe. Production limits were preserved.

The schema diff audit restored three accidentally expanded unrelated 32-member
bounds before the final passing runs. Operator routes are separately specified
in [their owning annex](../specs/external-profile-operators-v1.md); current v2
selection/observations, native adoption and physical qualification remain open.
Producer dependency pins are unchanged and all commits remain local on main.
