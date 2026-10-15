# Temporal runtime adoption evidence — October 2026

This record owns incremental Home evidence for the
[temporal runtime successor](../specs/routine-temporal-runtime-v1.md).
Dependency selection is implemented. Production Recurrence delegation, the
complete v4 runtime identity and actual durable boundary cases remain pending.
The separate [civil archive record](routines-civil-2026-10.md) retains the
producer archive identities and all prior comparison evidence.

## Selected source cohort

Home and the firmware lock select these exact committed Git inputs:

| Application | Revision | Package root |
| --- | --- | --- |
| wotex / wotex_continuum | 687a5cd70267fa47dbfb36e28eccad6ef2964fdf | packages/wotex / packages/wotex-continuum |
| wotex_routines | f3e77a431a917b639f7b0d52a93b78c27def4344 | packages/wotex-routines |
| ex_booking | 3fa614cd3cf106aba7161e17015969634afc3730 | repository root |

Core and Continuum package trees are identical at the selected revision and
inspected WoTEx eb1380ae: respectively
`f957417a4aad62054fc5b0f5abc91072aec45e5b` and
`fed56fbd187acf0ee6cec9cc3f3f183abfe3adf5`.
Routines has no package-tree change between f3e77a43 and that inspected HEAD.
ExBooking's package inputs have no change between 16a9d0d and 3fa614c;
the latter adds independent producer test evidence. Thus selection preserves
the exact package sources behind the prior four-archive civil comparison.
Existing Runtime/Profiles/MQTT/core/UDP pins and all Hex versions are retained.
Routines' optional ExBooking release requirement is explicitly overridden by
Home's reviewed exact source, rather than silently selecting an older API.

The ordinary release's existing sparse-package legal input step now includes
Routines and Continuum through the same package map. No release or firmware
image was assembled; installed/native/legal qualification remains separate.
Source objects were fetched from owned local repositories into ignored dependency
checkouts with their canonical upstream URLs retained. No push, release or
remote-availability claim was made.

## Executed pinned checks

Home used Elixir 1.19.6 / OTP 28.5.0.6 from `.tool-versions`, with
`WOTEX_HOME_GIT_DEPS=1`. These checks ran against the selected sources:

- Root `mix deps.get --check-locked`: passed, retaining other dependency entries.
- `mix compile --warnings-as-errors`: passed.
- `mix format --check-formatted mix.exs test/wotex_home/producer_cohort_test.exs test/wotex_home/routine_calendar_test.exs`: passed.
- `mix test test/wotex_home/routine_calendar_test.exs test/wotex_home/civil_timezone_test.exs test/wotex_home/producer_cohort_test.exs test/release_components_test.exs test/isolated_smoke_test.exs --warnings-as-errors`:
  **26 passed**, seed **773526**. This includes all 230 frozen local-label
  vectors and 112 next-coordinate/membership vectors through the selected
  public civil join, exact source/firmware-lock assertions, public profile/MQTT
  regressions, sparse legal input fixtures and isolated committed-source staging.
- In native/nerves, `WOTEX_HOME_GIT_DEPS=1 MIX_TARGET=host EX_MAUDE_BUILD_CNODE=0 mise exec -- mix deps.get --check-locked`:
  passed. Its Nerves bootstrap compiled the host dependency closure and Home;
  upstream OTP deprecation warnings were printed. Native used its own pinned
  OTP 29.0.4, with Elixir 1.19.6-otp-28. This was no firmware build.
- `git diff --check`: passed.

An initial strict selected-API case exposed an old ExBooking test BEAM cache
following local source staging. Rebuilding only ExBooking in the dev and test
environments resolved the stale cache; the final corpus above requires the
actual selected public API and has no absence fallback. One test also needed an
explicit module load before using `function_exported?/3`.

Lock SHA-256s at this selection milestone:

- root: `428208a00ea1e711354f52f11b9be289e068bd54357db62f120c2eeadb227fb8`;
- firmware: `4427873e5b6463d582109035f4178d6ce5b45f6e027e779c9c78a986df893b16`.

Dependency resolution reported Cowlib/Gun advisory CVE-2026-43966. The
[CNA record](https://cna.erlef.org/cves/CVE-2026-43966.html), updated October 14,
names an unreleased Cowlib fix and Gun's existing request-header mitigation.
This selection milestone did not claim a green advisory audit. The following
[remediation record](http-header-dependency-2026-10.md) retains the actual fix,
single explicit acknowledgement and subsequent lock identities. Earlier dated
no-advisory records are historical observations.

No full Home suite, Dialyzer, release/image build or physical test ran for this
slice. Tests clean their private staging/release fixtures. No standalone
archives, reports, Docker resources or documentation output were created.

## Inventory capacity finding before v4 implementation

The first focused runtime/admission run after production calendar delegation
failed Home inventory even for the old Home/UDP subset. A separate
`MIX_ENV=test mix run --no-start --no-compile` probe loaded each application
without starting it and inventoried each separately. Home declares **541**
modules, above the previously accepted 512-module cap. All other selected
applications passed: Routines 57, Continuum 26, core 18, ExBooking 26, Decimal 7,
Jason 28, ExJsonSchema 107, NimbleOptions 3, Tz 18 and UDP 9.

The successor contract was amended before changing the implementation bound:
1024 modules per trusted application, eleven applications maximum and a
11264-entry parsed checksum memo. This retains the complete actual Home module
list with bounded headroom; no module is omitted or given a weaker digest.
Artifact/path/read/timeout caps and loaded/file/old-code checks remain unchanged.
The failed first run (31 cases, 18 failures, seed 569374) is diagnosis, not positive
adoption evidence. The expanded-bound and complete-cohort tests remain next work.
