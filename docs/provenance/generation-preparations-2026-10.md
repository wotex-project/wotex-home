# Durable generator preparation software evidence

Recorded: 2026-10-14. Contract:
[durable inert preparations](../specs/generation-preparations-v1.md).
Runtime source: 063aac87251448b90df71a9f09100a149f211613 on local main.
Contract and frozen independent vectors preceded implementation in 7b6384d.

## Source and environment

GenerationPolicy and GenerationPreparation define the closed installed policy,
ordered operation and historical receipt. Authority/Store own authentication,
current contract/policy checks, custody projection and one durable transaction.
Store.GenerationPreparations owns borrowed-connection history and integrity.
Schema 36 adds the inert originals; backup, recovery commitments and explicit
Linux package/status/probe gates consume that actual table set.

The independent Python oracle is
test/support/generation_preparation_oracle.py. Its frozen fixture,
test/fixtures/profiles/generation-preparations.json, has raw SHA-256
0cc36914a925b24dd71babbbdd83b1ce4675390f1165f7272d9bb22a61bc8682.
It encodes ordered arrays and hashes using existing two-family projection and
contract vectors without invoking Home or WoTEx. Runtime receipt tests separately
compute the actual installed contract basis in Python from its public summary;
the older frozen basis is not relabelled as the current runtime basis.

The consumed producer source remains ba8ea373244ce57987f47a731b8eca3ccae9b45f.
No dependency was updated. Root mix.lock raw SHA-256 remains
3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184.
Root checks used mise Elixir 1.19.6 / OTP 28.5.0.6 on macOS. Native Nerves host
checks use its own OTP 29.0.4 / Elixir 1.19.6-otp-28 toolchain.

## Executed checks

The final focused generation suite passed **11 tests, zero failures, 9.3 seconds**:

```
mise exec -- mix test test/wotex_home/generation_preparation_test.exs
```

The affected regression run passed **79 tests, zero failures, 53.9 seconds**:

```
mise exec -- mix test test/wotex_home/generation_preparation_test.exs \
  test/wotex_home/durable_authoring_objects_test.exs \
  test/wotex_home/authoring_candidate_test.exs \
  test/wotex_home/authoring_review_test.exs \
  test/wotex_home/recovery_snapshot_test.exs \
  test/wotex_home/durable_schedule_lifecycle_test.exs \
  test/build_runner_test.exs test/linux_service_package_test.exs \
  test/linux_update_journal_test.exs
```

Selected historical-schema migration and backup cases passed **45 tests, zero
failures, 22.8 seconds; 845 other tests excluded**. The exact file/line selectors
are listed below (paths relative to the runtime commit):

```
test/wotex_home/controller_acceptance_schema_test.exs:60
test/wotex_home/controller_acceptance_schema_test.exs:124
test/wotex_home/controller_acceptance_test.exs:535
test/wotex_home/controller_acceptance_test.exs:665
test/wotex_home/controller_pairing_consumption_test.exs:551
test/wotex_home/controller_pairing_consumption_test.exs:557
test/wotex_home/controller_pairing_consumption_test.exs:568
test/wotex_home/controller_retirement_test.exs:379
test/wotex_home/durable_authoring_objects_test.exs:240
test/wotex_home/durable_authoring_objects_test.exs:247
test/wotex_home/durable_candidates_test.exs:510
test/wotex_home/durable_causal_roots_test.exs:370
test/wotex_home/durable_enrollment_test.exs:742
test/wotex_home/durable_enrollment_test.exs:3251
test/wotex_home/durable_enrollment_test.exs:3282
test/wotex_home/durable_invariant_test.exs:252
test/wotex_home/durable_maintenance_test.exs:382
test/wotex_home/durable_override_test.exs:232
test/wotex_home/durable_override_test.exs:248
test/wotex_home/durable_override_test.exs:404
test/wotex_home/durable_override_test.exs:422
test/wotex_home/durable_profiles_test.exs:658
test/wotex_home/durable_qualification_test.exs:313
test/wotex_home/durable_requests_test.exs:1029
test/wotex_home/durable_requests_test.exs:1461
test/wotex_home/durable_schedule_admission_test.exs:369
test/wotex_home/durable_schedule_admission_test.exs:379
test/wotex_home/durable_schedule_admission_test.exs:395
test/wotex_home/durable_schedule_lifecycle_test.exs:788
test/wotex_home/durable_schedule_lifecycle_test.exs:811
test/wotex_home/durable_schedule_occurrences_test.exs:526
test/wotex_home/durable_schedule_occurrences_test.exs:538
test/wotex_home/durable_schedule_occurrences_test.exs:579
test/wotex_home/durable_schedule_occurrences_test.exs:631
test/wotex_home/durable_store_test.exs:420
test/wotex_home/native_target_schema_test.exs:42
test/wotex_home/native_target_schema_test.exs:61
test/wotex_home/native_target_schema_test.exs:75
test/wotex_home/recovery_store_test.exs:292
test/wotex_home/durable_observation_clock_test.exs:234
test/wotex_home/durable_handoff_clock_test.exs:107
test/wotex_home/durable_causal_roots_test.exs:112
test/wotex_home/durable_causal_roots_test.exs:228
test/wotex_home/durable_requests_test.exs:1009
test/wotex_home/durable_requests_test.exs:1044
```

Run these selectors as arguments to `mise exec -- mix test`.
Fixtures remove the schema-36 table before claiming an actual earlier schema;
post-migration expectations assert literal 36. This was a targeted historical
regression run, not a full application-suite milestone.

Root formatting, warnings-as-errors compilation, the catalogue check (22 matched
contracts), and Git whitespace checks passed before the runtime commit.
The native Nerves pure host check passed **4 tests, zero failures, 0.1 seconds**:

```
cd native/nerves
WOTEX_HOME_GIT_DEPS=1 MIX_TARGET=host EX_MAUDE_BUILD_CNODE=0 mise exec -- \
  mix test test/board_snapshot_test.exs test/usb_inventory_test.exs \
  test/data_mount_test.exs
```

It freshly compiled Home in the host closure and performs no firmware build.

Raw synthetic logs are /tmp/home-generation-preparation-complete.log,
/tmp/home-generation-preparation-regressions.log and
/tmp/home-generation-migration-tests.log.

## Acceptance correspondence and limits

GP-T1 exercises two installed families, independent policy/operation/receipt
identities, unchanged revision on original retry/status, restart and absent
policy/bytes. GP-T2 exercises actual current actor/ownership/CAS/epoch/maintenance,
wrong contract/provider/policy/range/kind/revision, remote consent and local-only
policy. Metadata refusals precede custody reads. Revoked export permission refuses
new preparations while retaining the historical original.

GP-T3 covers cancellation/repeat, boot retirement, exact expiry, the final
transaction deadline, 16 live preparations, 1024 retained rows and exactly
4194304 aggregate encoded input bytes. Capacity fixtures use structurally valid
expired historical SQLite rows rather than unbounded production generation.
GP-T4 injects prepare/cancel SQL faults and checks complete rollback; checks
tampered history, real schema-35 migration/failed migration, encrypted inclusive
and database-only quarantine restore, and historical normalized commitment
stability when the new table is empty. Generic SQL faults intentionally close
writes; the fault fixture removes its trigger and restarts before retry.
GP-T5 covers malformed ordered documents/forged policies, pre-lock invalid
installation, exact current Linux36 metadata and historical28/35 verification.

The wider affected run occurred before the final two focused locality/deadline
cases were added; the final 11-case run includes those cases. These checks establish
inert preparation and durable software history. They make no provider call,
export no source to a provider, install no transport/native route and produce no
generated candidate. Handoff/attempt originals, current export rechecks during
adapter work, bounded repair and signed paired/native delivery remain successors.

Linux-root service cases, fresh packaged release execution, firmware/board tests,
installed signing, disk power-loss and physical qualification remain unexecuted
for this source. No fresh hosted CI result is claimed. Earlier schema-35/Nerves
evidence retains its own source scope. All commits remain local; no refs pushed.
