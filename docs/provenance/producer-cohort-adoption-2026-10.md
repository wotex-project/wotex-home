# Ordinary application producer adoption

Recorded: 2026-10-14. Runtime source: Home 692586e on main.
Owner: [producer cohort successor](../specs/producer-cohort-adoption-v1.md),
WOH.18 authoring/reader consumption and WOH.16 source/legal inventory.

The ordinary Git-selected consumer now includes wotex, wotex_runtime and
wotex_profiles at ba8ea373244ce57987f47a731b8eca3ccae9b45f, using each exact
sparse package directory; ExBooking uses 25ad04548c01e5a24c5505acfbe063550d3efaa0.
All actual dependency checkout HEADs equal the declared pins. ExMaude remains
released Hex 0.5.0 and WoTEx UDP remains dde1837f03f88a847ba5a0ec4479711a5ff1cf96.
No existing lock tuple changed. The eight additions are those four Git sources,
Decimal 3.2.0, ex_json_schema 0.11.5, NimbleOptions 1.1.1 and tz 0.28.4.
Home mix.lock raw SHA-256 is
3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184.

## Release/source review

Primary Hex API reads found ExBooking 0.2.3 and ExMaude 0.5.0; the four WoTEx
package names, including Routines, returned 404. The selected generic occurrence
API is outside ExBooking's current Hex artifact, so its exact hosted Git source
is required. GitHub commit API reads verified both selected hosted revisions.
Repository visibility was read only; no push or visibility action occurred.

Reviewed selected producer CHANGELOG files and actual public APIs. The WoTEx
core/Runtime/Profiles changelogs have no release entries. ExBooking's maintenance
commit updates CI action pins without changing occurrence behavior. Decimal's
notes require the current 3.2 precision/exponent and numeric fixes; Profiles
already requires Decimal >=3.2. NimbleOptions 1.1.1 retains default-value and
typespec fixes. tz 0.28 notes cover bundled 2026d data and finite DST boundaries;
Home installs no updater/watcher or global time-zone database. ex_json_schema
has no CHANGELOG or GitHub release entry; primary v0.11.4...v0.11.5 source compare
preserves sibling keywords while resolving $ref. Its default remote resolver
remains absent. No automatic schema URL fetch or clock installation was added.

## Executed checks

Toolchain: Elixir 1.19.6 / OTP 28.5.0.6 on local arm64 macOS. All Mix commands
used WOTEX_HOME_GIT_DEPS=1; checks used MIX_ENV=test. Compilation of the eight new
dependencies passed. Formatting, warnings-as-errors Home compilation, catalogue
check (22 contracts) and git diff --check passed.

- 37 focused producer/import/candidate/review/operator/source-staging cases
  passed before the final reader/inventory additions.
- 25 runtime-artifact, explicit time-zone custody and legal inventory cases passed.
- Final focused run: 12 cases, zero failures, in producer_cohort_test.exs,
  release_components_test.exs and isolated_smoke_test.exs. This run includes
  two independent contract/finalizer/validator/report vectors, changed capture
  refusal, explicit-basis occurrence output/refusal, actual application runtime
  inventories, all declared source staging, sparse legal-path/full-byte hashes,
  actual release-step copying and missing payload refusal.

Profile/report expectations are retained independently under test/fixtures/profiles;
they are not regenerated from the adopted implementation. The disposable source
staging cases retain only committed bytes despite modified/ignored source files.

No fresh full OTP release, native bundle, signed installation or physical test
was performed for this slice. Old extracted archive SHA values remain identities
of those explicit test archives. They are not asserted as the new Git runtime's
package identity. Host contract/source/meaning installation, Routines/Continuum
adoption, authenticity, redistribution clearance and physical qualification
remain separate requirements. Dispatch and schedule-delivery defaults remain false.
