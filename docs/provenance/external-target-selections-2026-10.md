# External target selection software evidence

Recorded: 2026-10-14. Owner: [durable target selections](../specs/external-target-selections-v1.md),
WOH.18 H18-03/04/05/07/08, H18-T2/T3/T4/T5/T6/T8/T9/T11/T12.
Level: bounded software and exact archive correspondence. No physical qualification.

## Implemented result

Local commits `98fd36d`, `5a3dd78` and `f1be7c0` implement closed original/outcome/receipt
encodings, exact private byte witnesses, actual checked target preparation and
schema 34 Store selection/replacement/revocation through Authority. The single
Store owns all SQL and revisions. Borrowed source checkout is checked again at
the final commit boundary and finished after the definite attempt.

Replacement/revocation clears current grants, source epochs, reports, overrides
and qualifications through the existing owning invalidators. Trust or selector/
approver withdrawal retires selected dependents atomically, retaining its actual
cause. Reserved history capacity prevents ordinary admission quotas from refusing
that withdrawal. Historical checks compare original hashes, actor-owned imports,
approval manifests, source/reader/policy witnesses, declaration/Thing joins,
counters, current pointers and withdrawal causes without producer or files.
Deleting the retirement and its journal event cannot hide the retained withdrawal.

Metadata-only revoke and exact original replay work after Store restart without
source owner or producer installation. No selection issues a grant, canonical
report, routine authority or physical dispatch. Generic current-use guards remain
closed until the separately specified external observation owner is implemented.

## Executed checks

Elixir 1.19.6, OTP 28.5.0.6; project `mix.lock` unchanged. Tests used public generic
WoTEx APIs from the exact existing archives:

| Package | Archive SHA-256 |
| --- | --- |
| Core | `77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61` |
| Runtime | `7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4` |
| Profiles | `34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96` |

`bin/check_routines_shadow.exs --profile-target-store-consumer` with complete
archive/digest arguments passed 64 isolated profile cases (9.0 seconds) and
22 real Home Store cases (4.7 seconds). Consumer lock SHA-256 remained
`6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
The suite compiles the selected Home modules and producer packages from fresh
archive extraction. It checks independent temperature, previously unseen density
and multi-channel vectors; a changed target capture; actual optional producer
removal including cold Store boot, lookup and revoke; original recovery; permission/CAS/trust/source refusals; grant withdrawal;
reusable identity tombstones; actual SQLite failure; principal/trust retirement;
source replacement while byte preparation is paused; deep corruption; schema 33
migration; and both inclusive/database-only encrypted quarantine. The retained
normalized commitment also matches for nonempty target/source histories across
both quarantine modes.

`mix test` for `recovery_store_test.exs`, `controller_acceptance_schema_test.exs`
and `native_target_schema_test.exs` passed 50 cases in 21.6 seconds. The focused
target/core/source-owner files passed 22 cases in 1.1 seconds; the target,
inspection and trust wire files passed 14 cases in 0.06 seconds after adding
numeric overflow/lexical bounds. A fresh process compiled all 24 selected routine
consumer modules with zero compile/runtime warnings; this checks source closure,
not a new routine archive correspondence run.

`mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix woh.spec.check` (22 owning catalogue contracts) and `git diff --check` passed.
No socket-free exclusion, full application suite, Dialyzer or native build was
used for this slice. Historical fixtures remove all four actual successor tables
when testing older schemas rather than relabeling a latest database.

## Remaining acceptance

This establishes the exercised software subsets of TS-T1–TS-T5. Exhaustive count/
byte ceilings, every dependent work state, complete nonempty target transfer
acceptance, protocol qualification, installed host source publication, current
external observation/read use and socket/native target workflows remain open.
The reserved quotas and existing invalidator calls are implementation facts;
their complete boundary matrix is not claimed as executed evidence. There is
no board, storage power-loss, live sensor or physical effect evidence here.

Independent vectors are regenerated with
`python3 test/support/external_target_oracle.py`; it calls neither Home nor WoTEx.
The oracle freezes ordered originals/receipts, raw artifact identities from prior
independent vectors, private UTF-8 witnesses and exact select/revoke outcomes.
The archive suite compares live preparation against those frozen results.
