# Retained generic read semantics software evidence

The [owning contract](../specs/generic-read-semantics-v1.md) was committed in
af5219f and independent records/multi-channel identities in f07ff36 before the
implementation c5bc710. This slice adds format-qualified EnvironmentalSensor
read metadata to the existing Thing/Registry, not another authority or Store.
Current v2 selection/report acceptance remains separately required.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- The exact three-archive `--profile-consumer` command recorded in
  [trust evidence](external-trust-2026-10.md) passed 43 cases in 8.5 seconds.
  It freshly compiles 28 selected Home modules with warnings as errors. The
  existing archive and consumer-lock identities are unchanged.
- `mise exec -- mix test` selecting generic_read_semantics_test,
  semantics_test, thing_current_test, profile_selection_history_test and
  durable_store_test passed 52 cases in 2.8 seconds.
- The shared-Registry enrollment/profile/recovery milestone selected
  durable_enrollment_test, durable_profiles_test and recovery_snapshot_test:
  505 tests passed in 640.5 seconds, one skipped. The skipped opt-in
  WOTEX_HOME_MINIMUM_WINDOW_PROBE one-second handoff timing probe was not
  enabled. Actual socket tests ran. This broad enrollment file includes
  qualification/temporal/handoff mechanisms beyond the changed representation;
  future iterations should select the affected cases before invoking it.
- A follow-up selected enrollment restart/backup and scoped socket status at
  locations 355/480 plus the profile/recovery-snapshot files: 27 cases passed
  in 12.6 seconds, 478 excluded. It was started before the broad run's terminal
  output was inspected; no assertion required a rerun. The attempted stops
  found both processes already terminal and terminated neither.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No whole-application/native suite,
  Dialyzer, packaging, dependency update or physical qualification was run.

| Source | SHA-256 |
| --- | --- |
| ReadDeclarationCodec | 4cafdb326eebca1577cc7e949d9de50a92abff0a8e4bef804812573e7ac9c96b |
| Independent retained/multi-channel vectors | a617687015ae63332fb4285607d2e64589675bd34dd9693b2c20eef1905f5a15 |
| Archive value/retained consumer | 1d8d5a6796672dda7a45e734caf73470ec2ca1bb2d094164fb477f43af16ed86 |
| Focused semantic/Store cases | 14e5ee051e03f90fc3d349035a242ec1edaf763ca35cd36a8ce1f0fea7a8db23 |

The Python oracle reconstructs canonical producer profile/closure/compiler
identities, checked plans and typed WOHA frames without invoking Elixir. A real
two-definition, two-channel closure then matches its raw artifact key, exact
retained declaration records and sorted Thing bytes through the public producer
and Home APIs. Live encoding verifies the actual raw closure rather than merely
accepting a supplied digest. Wrong artifact assertions refuse.

Producer-independent records preserve exact bytes/hashes. Unknown/duplicate/
deep/oversized fields, wrong hashes/formats/IDs/risk/freshness/operations,
crossed identities and forged native fields/map keys refuse. A valid maximum
32-channel historical metadata set reaches the existing total Thing byte limit;
the fixture does not establish additional producer/source truth. Generic metadata
survives actual Store enrollment/restart and integrity verification without the
optional producer. Legacy value/observation constructors and the real Store
observation path cannot accept it.

The guard audit caught the legacy compiled-profile fallback for the new role.
Generic current use now refuses profile_selection_unavailable until its owning
selection lifecycle exists; legacy fact projection refuses unsupported_fact.
Current inspection can show declaration metadata with profile_unavailable, no
current value and zero remaining freshness. Even a target-granted ordinary
controller cannot submit a write or advance the revision for these metadata-only
Things. No implicit grants or physical claims are created.

The first focused fixture called a nonexistent Store alias and was corrected to
the actual Authority.current_thing API. The first total-size fixture fit the
existing byte ceiling; adding bounded historical schema metadata exercised that
ceiling honestly. All final cases passed. SQLite schema 33 and producer pins are
unchanged, unrelated drafts are preserved and all commits remain local on main.
