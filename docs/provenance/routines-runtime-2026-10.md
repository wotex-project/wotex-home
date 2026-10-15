# Temporal runtime adoption evidence — October 2026

This record owns incremental Home evidence for the
[temporal runtime successor](../specs/routine-temporal-runtime-v1.md).
Dependency selection, production calendar delegation and the complete v4
runtime identity are implemented. Expanded opening/closing/final Store
phase-fault, historical retained-row and current-guard checks have bounded
software evidence below. Wider routine admission and installed/physical
qualification remain separate.
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
adoption evidence. Expanded-bound/cohort tests had not run at that finding;
the following checkpoint records their subsequent execution.

## Implemented current runtime slice

Production `Recurrence` now delegates its once/daily/weekdays branches to the
public pure `RoutineCalendar` join. Its replaced calendar resolver/search loop
is removed; interval arithmetic and the countdown refusal remain Home-owned.
There is no runtime switch or old-calendar fallback. A fresh Home-only VM now
proves producer absence refuses actual production calendar calls while interval
calculation remains usable.

RuntimeArtifacts owns one exact ordered ten-application temporal closure and
adds UDP for the eleven-application Store scope. It accepts at most eleven
applications / 1024 modules each and retains the complete 541-module Home list.
The parsed checksum memo is bounded to 11264 entries. Other artifact, reader,
path, timeout and cleanup bounds remain unchanged. Existing caller domains and
smaller-request term encoding are preserved.

TemporalBasis emits `single-schedule-temporal-v4`, using the complete ten-member
closure and domain `wotex-home.single-schedule-runtime.v2`, including for interval
and countdown sources. The v3 obligations gain `generic_civil_calculation` and
`complete_temporal_runtime_cohort`. Exact v1/v2/v3 obligation/hash decoding remains
historical; current comparison requires rebuilt v4 equality. No receipt/schema
migration, current-author cache, clock-trust change or physical dispatch is added.

### Focused executed checks

Root used its pinned Elixir 1.19.6 / OTP 28.5.0.6 and selected locked producers.
All commands used `WOTEX_HOME_GIT_DEPS=1`:

- `mix test test/wotex_home/routine_calendar_test.exs test/wotex_home/schedule_recurrence_test.exs test/wotex_home/schedule_timezone_test.exs test/wotex_home/schedule_calendar_reference_test.exs test/wotex_home/schedule_source_correspondence_test.exs --warnings-as-errors`: **30 passed**, seed **57954**, 9.6 seconds. Actual production recurrence passes the 112 frozen next/membership cases; pure resolution passes 230 labels. Independent raw-byte/Gregorian checks remain separate.
- `mix test test/wotex_home/runtime_artifacts_test.exs test/wotex_home/schedule_admission_artifact_test.exs --warnings-as-errors`: **31 passed**, seed **26149**, 45.6 seconds at that test-file revision. This retains byte/loaded/old-code/path/reader checks and actual source-bound window/cursor/countdown/guard proofs, including future-fold and footer mutations. The fold mutation now targets the production RoutineCalendar owner. v1/v2/v3 records decode and refuse current use.
- A subsequent location-filtered run selected RuntimeArtifacts lines 8/138, ScheduleAdmissionArtifact line 559, ProducerAbsenceTest, and DurableScheduleAdmission lines 65/152: seed **350577**, **five passed and one test-output assertion failed** because the isolated guard script printed an unused-variable warning. All injected eleven-member guard assertions reached their successful terminal marker. The helper binding was then made explicit.
- `mix test test/wotex_home/runtime_artifacts_test.exs:138 --warnings-as-errors`: **one passed**, seed **833737**, 7.2 seconds, after that warning fix. Every one of the eleven applications now passes complete-byte drift with equal OTP code checksum, missing-file opening refusal, loaded mismatch/old code, declared-version/module-list drift, and fresh reads after scope closure. Callback positives remain unpublished on closing drift.
- The other five filtered cases above establish exact eleven-member ordering and reverse/singleton subsets; warmed v4 proof changes/refuses for every temporal producer/dependency's bytes, missing artifact, version or module list; a fresh absent-producer VM runs all **five** child absence cases; and actual SQLite admission/retention plus same-owner restart retain current v4 bytes.
- `mix test test/wotex_home/durable_schedule_occurrences_test.exs:92 test/wotex_home/durable_schedule_lifecycle_test.exs:729 --warnings-as-errors`: **two passed**, seed **449243**, 9.3 seconds. An actual qualified-clock poll creates one retained held request/root with temporal provenance and no execution; actual installed-UTC calendar content activates and the SQLite snapshot passes integrity.
- Scoped formatting, `mix compile --warnings-as-errors` and `git diff --check`: passed after the final code changes. The docs-only agent reviewed the three affected public moduledocs; no documentation build was run.

Exact source SHA-256s for this slice:

| Source | SHA-256 |
| --- | --- |
| runtime_artifacts.ex | 7e561efdf18fee2bacba43d86fa77e505a3482a252afe883f7564302256ec0ad |
| schedules/temporal_basis.ex | 456461bca2f5fc82e57aaeedd8fb4912187e95bfe33f50a1cf9e2a8a2adbf3a9 |
| schedules/recurrence.ex | 18ee3a9927744fa83bc0fffb2dc3a31fb398ba813b0fbb2f44910624c90dd02c |

### Remaining acceptance at the runtime implementation slice

The actual Store queue/claim/final-handoff and poll-preparation phase-fault
campaign must still mutate producer/dependency artifacts at opening, closing and
final unscoped checks, including SQL withdrawal/rollback and spent/unknown roots.
Historical v1–v3 decoding is checked in pure artifacts; actual retained old-profile
rows, withdrawal/restart and unchanged current author/grant/profile/invariant/clock
barriers still need their expanded durable cases. The full mechanism milestone,
release/image/installed and physical qualification remain open. No global-green
or complete RTR-T3/T4 claim follows from the narrow happy-path Store checks.

All new isolated runtime, proof, absence and Store fixture directories were
removed on terminal completion. No archive, standalone report, Docker resource
or generated documentation tree remains from these checks. Dependency and normal
compiled caches are retained to avoid unrelated rebuilds.

## Actual Store opening/closing producer campaign

The existing durable enrollment fixtures now name ten independent temporal
application/module pairs explicitly: Home/Window, Routines/Civil, Continuum,
core/JSON, ExBooking, Decimal, Jason, ExJsonSchema/Schema, NimbleOptions and Tz.
The application list is not derived from the implementation under test. Each
producer/member gets all three queue/claim/handoff retained-byte cases and four
poll-preparation opening/closing plus withdrawal-publication-fault cases.

These use actual Store calls and SQLite. The byte mutation appends a BEAM chunk
while verifying that OTP's code checksum remains unchanged. No loaded module
semantics, clock/deadline, current guard or artifact decoder is weakened.
Queue/claim/handoff refusal retains one sticky suspension and the immutable
original, rejects unsent work, retains already committed root spend and creates
no dispatch journal. Poll refusal creates no caller-bound slot, consideration,
effect or scheduled root. A withdrawal SQL fault restores the prior revision and
phase, retains activation history and stops writes. Successful inactive polling
creates no slot even while runtime custody is still missing. Every case validates
complete snapshot integrity, then restores the original file and stops its Store.

Executed on root Elixir 1.19.6 / OTP 28.5.0.6 with exact locked Git sources:

- `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_runtime_member:wotex_routines --warnings-as-errors`: **7 passed**, seed **8843**, 19.4 seconds.
- `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_runtime_cohort --warnings-as-errors`: **70 passed**, seed **163541**, 104.9 seconds; other cases in this large fixture module were explicitly excluded. This expands the seven pre-existing Home cases to all ten applications.

The final-reader-after-scope-closure injection, committed-handoff uncertainty and
actual historical v1/v2/v3 retained-row/restart cases remain separate acceptance
work. This campaign does not establish atomic live upgrades, physical control,
installed host performance or a full Home quality milestone. No real device
transport was opened, and no socket-free suite filter was used.

## Final-reader classification finding

A deterministic test-only RuntimeArtifacts BEAM inserts a one-use file mutation
immediately after its successful complete closing inventory. Its loaded code and
retained file match while the actual Store creates its reviewed fixture; no
production source or hook is added. Store, its SQL transitions, admission and
final execution guards are unchanged. The mutation then changes a selected
producer's complete bytes with an equal OTP code checksum before the independent
final guard. The ordinary complete byte/file/loaded checks remain enabled.

The first Routines run selected queue/claim/handoff with and without withdrawal
SQL faults: six cases, seed 906163, 27.3 seconds. The three fault-shaped outcomes
matched `store_unavailable`, but did not yet prove that withdrawal publication
was reached. The three ordinary final refusals also returned `store_unavailable`.
Inspection found `stale_schedule_admission` in ExecutionWriter's initial-policy
set but absent from its final-policy set; the final reader correctly detected
stale admission, then treated that semantic refusal as writer damage.

Before correcting production classification, RTR-05 was clarified: final stale
admission is a closed current-basis denial, preserving sticky withdrawal and
original spend while leaving the writer usable. SQL and historical damage remain
rollback/disabled-writer failures. This failed run is a counterexample, not
positive final-boundary acceptance evidence.

### Final-reader fix and executed acceptance

ExecutionWriter now includes `stale_schedule_admission` in its final-policy
classification, inherited by the initial-policy set. No other error changes
classification. A current-basis denial restores tentative execution, publishes
the required sticky withdrawal against the original phase and leaves Store
writable. SQL/history damage still rolls back and disables writes.

The final-reader matrix covers all ten temporal applications at queue, no-send,
claim and handoff; Routines also repeats all four phases with a withdrawal SQL
fault. Every case observes SQLite's actual rule-generation update before the
withdrawal insert, including when its trigger aborts. Thus an earlier generic
writer failure cannot satisfy a SQL-fault case. The one-use fault is consumed
after successful closing inventory, and no guard inventory remains at the
independent final check. Every case checks immutable originals, prior committed
spend, absence of tentative dispatch, exact withdrawal/rollback state and snapshot
integrity. Home byte drift may refuse earlier through `profile_unqualified`;
it must still retain the same sticky withdrawal and writer usability.

Two producers, Routines and ExBooking, additionally change complete retained
bytes after an already committed handoff. Successful withdrawal records exactly
one unknown outcome without refunding the spent root, replaying the original or
opening another poll slot. A SQL fault preserves the committed dispatching phase
and revision, retains its dispatch journal and disables writes. These are
software uncertainty tests; no physical transport or device acknowledgement is
inferred.

Executed with root Elixir 1.19.6 / OTP 28.5.0.6 and exact locked sources:

- `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_final_runtime_member:wotex_routines --warnings-as-errors`: **six passed**, seed **74396**, 22.7 seconds, after adding the actual generation-update observation.
- `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_final_runtime --warnings-as-errors`: **44 cases, three failed test expectations**, seed **782223**, 91.1 seconds. All forty non-Home cases passed. Three Home cases correctly returned `profile_unqualified`, which the initial test whitelist omitted. This run alone is not a green matrix claim.
- After correcting that expectation, `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_final_runtime_member:wotex_home --only temporal_handed_runtime --warnings-as-errors`: **eight passed**, seed **913064**, 38.8 seconds: all four Home final phases and all four committed-handoff/SQL cases. Combined with the unchanged forty non-Home cases above, every final matrix case has positive executed evidence.

The fixtures restore original dependency/Home BEAMs in `after` and `on_exit`,
restore compiler options, stop owned Stores and remove private SQLite
directories. A post-run scan found no `.held` backup. Normal locked dependency
and compiled caches remain for incremental work. No Docker container, image,
volume, standalone archive, generated documentation tree or release was created.
At this final-reader checkpoint, historical retained-row/current-authority
acceptance and the broader mechanism milestone remained open. The following
checkpoints retain their subsequent results separately.

Scoped formatting, `mix compile --warnings-as-errors`, `mix woh.spec.check`
(22 working catalogue contracts) and `git diff --check` passed. ExecutionWriter's
source SHA-256 is `a24c7e7f6dbd0b9c6e1155bebb6f5ee18a7e9992054bc7f1d0ef0a4df136a346`.

## Historical retained-row acceptance

The actual SQLite matrix covers each v1/v2/v3 profile with held, queued, claimed
and already dispatching work, both without restart and after a same-owner
restart. Each profile also has a dispatching case whose withdrawal insert
aborts. These are 27 distinct cases. No production switch, receipt rewrite,
schema migration or legacy authorization fallback was added.

A controlled test-only TemporalBasis producer runs the full current finite
proof, but emits each exact historical profile/obligation list and the older
Home-only runtime/domain. Inspection of repository objects 6479c1b, 276d0aa and
5f14995 independently confirmed those older inputs. Tests contain the explicit
lists and require no historical Git object, network or archived dependency.
The temporary module's loaded code and retained BEAM match while the real Store
admits, activates and advances the fixture. Before switching to production v4,
the actual current-admission reader accepts that exact retained artifact.

The fixture then restores the original current TemporalBasis BEAM, or stops
Store, restores it and restarts the same database with its existing private
qualification keys. It supplies no replacement clock or claim owner on restart.
This is controlled historical-content software evidence, not execution of an
archived old release, an atomic live upgrade or installed-host qualification.

Production v4 withdraws the old activation before selecting work, returns
inactive polling status and creates no poll slot or new original. The complete
admission rows remain byte-identical by an independently retained row hash;
their old profile, immutable admission receipt and original occurrence remain
readable. Held roots stay unspent; queued/claimed/handed-off roots stay spent.
Unsent work is rejected. A live committed handoff becomes unknown under the
generation fence, retaining its worker owner to prevent concurrent
reconciliation. Restart first retains `crash_after_handoff` uncertainty and
creates no replacement owner; subsequent withdrawal does not count that
already terminal original as a newly affected or unknown outcome. Withdrawal
SQL faults prove actual generation-update observation, restore the prior phase
and revision, retain every old admission byte and disable writes. Every case
validates complete snapshot integrity and stops its Store.

Executed with the root pinned toolchain and locked producers:

- The first v3 run, seed **534852**, selected nine cases in 41.6 seconds. Its SQL-fault case passed; eight expectations incorrectly required an error instead of the owning API's inactive result. That expectation was corrected against the actual `ScheduleOccurrences.prepare_poll/2` contract.
- `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_historical --warnings-as-errors`: **27 cases, three failed test expectations**, seed **376220**, 67.1 seconds. Twenty-four passed. The three live handed-off cases correctly retained their worker owner; the test had incorrectly required an empty owner map. No production change followed from this finding.
- After correcting the phase-specific owner expectation, `WOTEX_HOME_GIT_DEPS=1 mix test test/wotex_home/durable_enrollment_test.exs --only temporal_historical_phase:dispatching --warnings-as-errors`: **nine passed**, seed **101607**, 30.5 seconds, covering every profile's live handoff, restart and SQL failure. Together with the unchanged eighteen non-dispatching positives above, every historical matrix case has positive executed evidence.

Temporary BEAMs and compiler options are restored in both normal and fallback
cleanup. Store fixtures use their existing private directory cleanup. These
tests create no archive, release/image, generated docs or Docker resource.

## Bounded runtime and current-guard milestone

After the final-reader classification fix and historical fixture restoration,
this targeted mechanism command passed on root Elixir 1.19.6 / OTP 28.5.0.6:

```sh
WOTEX_HOME_GIT_DEPS=1 mix test \
  test/wotex_home/runtime_artifacts_test.exs \
  test/wotex_home/schedule_admission_artifact_test.exs \
  test/wotex_home/durable_schedule_admission_test.exs:87:179 \
  test/wotex_home/durable_schedule_lifecycle_test.exs:133:250:403:430:729 \
  test/wotex_home/durable_schedule_occurrences_test.exs:133:176:198:244 \
  test/wotex_home/durable_enrollment_test.exs:2580:2750:3388:3468:3918:4388 \
  --warnings-as-errors
```

**73 passed**, seed **436221**, 95.6 seconds; 652 unrelated tests were excluded
by explicit file/line selection. No socket-free switch was used. The full
runtime-artifact/admission-artifact files repeat complete inventory, historical
decoding/current refusal, source/calendar mutations and current producer
availability. Selected actual Store cases repeat original-author/epoch/CAS and
declaration checks, target-grant withdrawal/restoration, private clock/restart
custody, competing polls/backward correction, installed timezone equality,
independent temporal boundary oracle, generation/cancellation, invariant expiry,
operator override and final queue/no-send/claim/handoff clock/qualification/SQL
guards. No mutable fact is replaced by the v4 runtime proof.

These executed finite cases supply RTR-T1–T5's stated pure/archive and durable
software evidence alongside the separately recorded civil producer archives and
phase matrices. They do not supply installed clock/storage qualification,
minimum-window load reliability, physical acknowledgement, wider/composed
admission, a full Home suite, Dialyzer, a release/image or a host campaign.

Final scoped formatting, warnings-as-errors compilation, all **22 working**
catalogue contracts, all **21 staged** catalogue contracts, 27 changed-document
local references and Git whitespace checks passed. The staged catalogue check
used a disposable projection of indexed spec files, removed on completion;
unrelated research edits remain outside this commit. Historical test source
SHA-256 is `6036a407a83b2bc3a157fdcb89b6b1d1c7ff1cb7846b746906158e473dfa948e`.
The production TemporalBasis source remains unchanged at
`456461bca2f5fc82e57aaeedd8fb4912187e95bfe33f50a1cf9e2a8a2adbf3a9`.
A final scan found zero enrollment fixture directories, staged-spec projections
or `.held` BEAM backups, and the restored compiled RuntimeArtifacts contains
no fixture hook. No Docker resources were created or removed; shared resources
and useful dependency/build caches were preserved.
