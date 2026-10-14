# Current host cohort and CI remediation evidence

Recorded: 2026-10-14. Owning compatibility contract:
[Linux schema-35 update profile](../specs/linux-update-schema35-v1.md).
Specification preceded the update implementation in 5fb0dd5.
Implemented sources: firmware lock e223f0f, portable/current historical fixtures
699f296 and Linux compatibility gates 757bad0, all local main commits.

## Observed hosted failure and local reproduction

[Hosted run 38587021806](https://github.com/wotex-project/wotex-home/actions/runs/38587021806)
tested 3449ac76e4e7e72cab0b804b9e109c06472ec503. Nerves failed at
deps.get --check-locked; core ran 2645 tests with 25 failures and seven skipped;
macOS stopped at paired recovery smoke. This evidence belongs to that older
source, not the current local commits.

The hosted core failures included seven Linux service-package cases fenced by
their stale schema-28 compatibility; 13 authoring-operator cases whose fixed
/private/tmp parent does not exist on Linux; a macOS Swift compilation scheduled
in the Linux core lane; an obsolete outbox count, schema-24 fixture retaining
newer tables, schema-28 packaged probe and update-journal status. Current source
also had additional macOS-only authoring fixtures needing platform selection,
and the new pure projection/installed-file tests used the same fixed temporary
parent. Those were corrected without removing any macOS obligations.

Local reproduction of service package, update journal, request and lifecycle
files produced **92 tests, ten failures, 52.9 seconds**, confirming the stale
schema, outbox and migration cases. Independent paired recovery smoke on current
source already passed; no additional paired production change was required.
Its earlier failure remains historical until a new hosted run is available.

## Changed boundaries

LinuxServicePackage emits literal schema 35 compatibility and refuses a future
unreviewed Store version. Exact historical schema-28 format-2 packages remain
verifiable; legacy format 1 is unchanged. The current update image predicate and
live status gates admit only integer 35 and retain writable/fence/current-original
checks. No cross-schema upgrade/rollback, migration, service transition or physical
dispatch was added. Independent package tests check old/floating/extra/unknown
metadata and preserved historical inventories. A Linux-root image case additionally
reissues a valid historical inventory/bootstrap and requires current image refusal;
that platform case is present but was not executed on this Mac.

Schema-24 lifecycle fixtures now remove schema 29–35 tables before migration,
and the embedded packaged probe independently expects literal 35 after creation
and restart. The outbox count follows 32 live held requests after one cancellation
and replacement. Pure/portable fixtures use the OS's temporary parent on Linux,
and canonical /private/tmp on macOS. Seven Swift/macOS Host fixtures explicitly
skip on non-macOS; their actual macOS/socket checks remain required in that lane.

Nerves lock adds exactly eight already-adopted root entries: core, Runtime,
Profiles, ExBooking and their decimal/ex_json_schema/nimble_options/tz closure.
All eight entries were independently compared byte-for-byte with mix.lock.
Existing entries and dependency versions were preserved. Root producer pins and
root lock are unchanged; firmware lock raw SHA-256 is
259fb7f414899924e12897dcb9c04ceff817c9e82d03f6254f82049a3a1b3663.
No new firmware image or board was provisioned.

## Executed validation

Environment: macOS 27.0.1 build 26A434. Root lane: Elixir 1.19.6 / OTP 28.5.0.6.
Nerves host lane: Elixir 1.19.6 / OTP 29.0.4, MIX_ENV=test, MIX_TARGET=host and
EX_MAUDE_BUILD_CNODE=0; both selected through their .tool-versions with mise.

* Affected service package/journal/maintenance/process/selection files:
  **24 tests, zero failures, 1.0 second**. Linux-root process/systemd branches
  are absent on this platform; these are portable software cases.
* Corrected request, schedule lifecycle, embedded build probe, authoring operator,
  generator projection and private configuration files:
  **111 tests, zero failures, 74.0 seconds**. This includes actual SQLite
  migration/rollback, framed operator routes, restart/original recovery, fresh
  packaged probe and private configuration startup processes.
* `mix woh.native.paired.recovery.smoke`: actual pairing/TLS/SQLite original
  retries, restart/revocation and wrong-principal refusal passed on current source.
  This fixture does not establish a signed paired application session.
* Seven macOS fixture modules loaded under an explicit requires_socket exclusion:
  **zero executed tests, seven excluded**. This checked filter/module loading only;
  their prior owning native evidence is not renewed by an exclusion.
* Nerves `mix deps.get --check-locked`, `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix test --no-start` (**four tests, zero
  failures, 0.2 second**) and `mix hex.audit` (no retired/advisory packages) passed.
* Root format, warnings-as-errors compile, catalogue (22 matched contracts) and
  whitespace checks passed. Each local runtime commit passed staged whitespace.

Raw ephemeral logs: /tmp/home-ci-{repro,linux-profile,corrected-fixtures,
paired-recovery,native-filter,nerves-deps,nerves-locked,nerves-compile,
nerves-test,nerves-audit}.log. They contain synthetic status/probe results.
No private credentials or hardware identities were retained in tracked evidence.

## Remaining evidence

The current cohort is implemented and has the above focused software evidence.
A new hosted run, full core milestone, Linux-root process/systemd image cases,
fresh complete packaged release, signed installed-host qualification and board
boot/power-loss/firmware qualification remain unexecuted in this slice. Passing
portable cases do not make those obligations green. No source refs were pushed;
the user performs every push, and repository visibility/remotes were unchanged.
