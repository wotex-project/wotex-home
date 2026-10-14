# Generator attempt and explicit repair software evidence

Recorded: 2026-10-14. Contract:
[durable attempts and bounded repair](../specs/generation-attempts-v1.md).
Runtime: 5c39907a8bd1058fe9cd5df27df560c8e32c098a on local main.
Specification and independent vectors preceded code in 17659fc.

## Consumed sources and scope

Authority/Store now reserve an explicit attempt before one temporary worker calls
the installed native provider process. GenerationAttempts retains immutable
reservation/result history; generated draft/bundle imports and settlement are one
SQLite transaction. Invalid candidates permit separately requested repair with
explicit consent for the exact previous draft/assessment. Cancellation, current
credential/policy/source withdrawal, deadline, process loss and restart cannot
resume the provider or install a profile.

Schema 37, backup table sets, full/normalized recovery commitments and the
literal Linux package/live-status/embedded-probe cohort include this mechanism.
Exact historical package metadata for 28/35/36 remains verifiable and is refused
as a current update image. No cross-schema executable update is introduced.

The frozen Python fixture is test/fixtures/profiles/generation-attempts.json,
raw SHA-256 ea747ce33654465c06945462bfff59dc64b2ca5a84587d44f2000a3f067ff0d9.
test/support/generation_attempt_oracle.py calculates ordered request/receipt,
provider-document/result bytes and import-operation IDs from independently frozen
two-family projection/policy data, using Python/hashlib without Home or WoTEx.
Actual Store cases compare those bytes/receipts and use the same installed
finalizer/validator as manual authoring for response correspondence.

No dependency changed. Consumed core/Runtime/Profiles source remains
ba8ea373244ce57987f47a731b8eca3ccae9b45f. Root mix.lock raw SHA-256 remains
3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184; native Nerves
lock remains 259fb7f414899924e12897dcb9c04ceff817c9e82d03f6254f82049a3a1b3663.
Root checks used mise Elixir 1.19.6 / OTP 28.5.0.6 on macOS. Nerves pure host
checks used its own Elixir 1.19.6-otp-28 / OTP 29.0.4 toolchain.

## Executed checks

The final mechanism run passed **24 tests, zero failures, 42.3 seconds**:

```
mise exec -- mix test test/wotex_home/generation_attempt_test.exs \
  test/wotex_home/generation_attempt_codec_test.exs
```

It contains 16 actual Store/process cases and eight pure/process codec/worker
cases. A preceding affected run passed **47 tests, zero failures, 30.7 seconds**:

```
mise exec -- mix test test/wotex_home/generation_attempt_test.exs \
  test/wotex_home/generation_attempt_codec_test.exs \
  test/wotex_home/durable_authoring_objects_test.exs \
  test/linux_service_package_test.exs
```

That run preceded the final cancellation-integrity refinement and 16-author
capacity case; the final 24-case run covers both. Selected historical migration
cases passed **45 tests, zero failures, 30.7 seconds; 845 other tests excluded**.
The selectors below resolve previous affected cases by their exact test titles,
then use current source locations. The initial affected run was **102 tests,
one failure, 106.2 seconds**; its only remaining failure was a stale schema-36
assertion in DurableAuthoringObjectsTest. The 47-case run and selected migration
run explicitly cover that corrected case. This is not a claimed green rerun of
the complete 102-case selection or the full application suite.

```
test/wotex_home/controller_acceptance_schema_test.exs:36
test/wotex_home/controller_acceptance_schema_test.exs:109
test/wotex_home/controller_acceptance_test.exs:522
test/wotex_home/controller_acceptance_test.exs:661
test/wotex_home/controller_pairing_consumption_test.exs:547
test/wotex_home/controller_pairing_consumption_test.exs:562
test/wotex_home/controller_retirement_test.exs:372
test/wotex_home/durable_authoring_objects_test.exs:233
test/wotex_home/durable_candidates_test.exs:502
test/wotex_home/durable_causal_roots_test.exs:310
test/wotex_home/durable_enrollment_test.exs:729
test/wotex_home/durable_enrollment_test.exs:3238
test/wotex_home/durable_enrollment_test.exs:3269
test/wotex_home/durable_invariant_test.exs:244
test/wotex_home/durable_maintenance_test.exs:372
test/wotex_home/durable_override_test.exs:223
test/wotex_home/durable_override_test.exs:395
test/wotex_home/durable_profiles_test.exs:636
test/wotex_home/durable_qualification_test.exs:304
test/wotex_home/durable_requests_test.exs:1014
test/wotex_home/durable_requests_test.exs:1452
test/wotex_home/durable_schedule_admission_test.exs:362
test/wotex_home/durable_schedule_admission_test.exs:388
test/wotex_home/durable_schedule_lifecycle_test.exs:780
test/wotex_home/durable_schedule_occurrences_test.exs:519
test/wotex_home/durable_schedule_occurrences_test.exs:550
test/wotex_home/durable_schedule_occurrences_test.exs:624
test/wotex_home/durable_store_test.exs:395
test/wotex_home/native_target_schema_test.exs:35
test/wotex_home/native_target_schema_test.exs:68
test/wotex_home/recovery_store_test.exs:288
test/wotex_home/durable_observation_clock_test.exs:216
test/wotex_home/durable_handoff_clock_test.exs:90
test/wotex_home/durable_causal_roots_test.exs:75
test/wotex_home/durable_causal_roots_test.exs:206
test/wotex_home/durable_requests_test.exs:953
```

Run those selectors as arguments to `mise exec -- mix test`.

Four native Nerves pure host probes passed **4 tests, zero failures, 0.2 seconds**
and freshly compiled the root code in the host closure:

```
cd native/nerves
WOTEX_HOME_GIT_DEPS=1 MIX_TARGET=host EX_MAUDE_BUILD_CNODE=0 mise exec -- \
  mix test test/board_snapshot_test.exs test/usb_inventory_test.exs \
  test/data_mount_test.exs
```

These probes preceded the last cancellation-integrity refinement; they establish
host-probe compatibility, not generation-provider or board qualification.
Formatting, warnings-as-errors compilation, catalogue checking (22 workspace
contracts matched), full HTML ExDoc with warnings-as-errors, and Git whitespace
checks passed. The catalogue check includes the existing unrelated workspace
draft; only the owning contract versions were staged with this work.

Raw synthetic logs are /tmp/home-generation-attempt-capacity.log,
/tmp/home-generation-attempt-final.log, /tmp/home-generation-attempt-regressions.log,
/tmp/home-generation-attempt-migrations.log, /tmp/home-generation-attempt-nerves.log
and /tmp/home-generation-attempt-docs.log.

## Acceptance correspondence and remaining evidence

GA-T1 compares both families' actual private handoff documents and immutable
receipts to independent vectors, checks manual/generated assessment parity and
exact actor-owned raw draft/bundle bytes, and confirms zero enrollment, request
or portable-profile activation rows. Original retry changes no revision/call.
GA-T2 covers wrong CAS/epoch/preparation SHA/missing root/provider, foreign and
unprivileged actors, and malformed native installation before file/lock creation.
The inherited preparation suite separately supplies kind/first-revision/range,
remote/local consent and ownership cases.

GA-T3 covers one-author busy refusal, 16 simultaneously held channels belonging
to distinct authors, shared preparation-capacity refusal, original conflict,
restart with dead helpers and absent provider/policy/custody on original recovery.
GA-T4 checks three explicit invalid-candidate attempts with the exact preceding
raw draft and report, no automatic repair, compatible/unknown predecessor refusal,
and exact total input/output representation boundaries. Embedded model requests
to change source selection remain inert data.

GA-T5 checks preparation cancellation and late replies, settled candidate history
after cancellation, credential revocation, maintenance, policy removal, missing
source, exact attempt expiry, provider/worker/Store death, and foreign/duplicate
tokens. No refused output becomes an owned candidate. Worker tests observe linked
helper death after cancellation/owner loss and safe OTP status redaction.
GA-T6 injects reservation and multi-row settlement SQL faults, verifies unchanged
revisions/import counts, checks corrupt handoff history, actual36 migration and
failed corrupt migration, encrypted inclusive/database-only quarantine archives,
unchanged empty-table legacy commitment and source-scoped later settlement.
GA-T7 supplies malformed ordered/native/float/unknown/improper requests/capabilities,
literal Linux37 metadata and historical28/35/36 verification/current refusal.

The 3072-row, 4-MiB attempt-input and 8-MiB aggregate result pool limits are
implemented with existing import/preparation limits and reserved failure space;
their complete bulk boundary corpus remains a milestone obligation. This record
does not claim every aggregate limit is reachable independently of those other
limits. The inherited preparation boundary corpus remains scoped to its own
executed cases. No external provider, network credential or model was installed;
scripted local GenServers establish software process behavior only.

Provider-specific transport authentication/confinement, immutable installed
generator policy/provider delivery, private socket/CLI/native operations, signed
paired delivery, full hosted CI, fresh packaged release/firmware execution,
storage power-loss and physical qualification remain separate work. Ordinary
host generation stays disabled. All commits remain local; no refs were pushed.
