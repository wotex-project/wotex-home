# Paired authoring journal foundation evidence

Recorded: 2026-10-15. Owner: [v8 pending custody](../specs/native-pending-paired-authoring-v8.md).
Contracts and initial independent vectors preceded code in b7e5668. Oracle S64
correction: c7e13df. Runtime:
ce83af8139f289c28b1495db8f7b41847ff99614 on local main.
No Store schema, dependency or sibling API changed.

## Implemented representation and compatibility

v8 retains complete paired import/candidate/review and preparation/attempt
originals using existing paired custody references. It preserves original epoch,
creation-revision floor, canonical document/payload checks and existing byte/tree/
scalar bounds. First publication upgrades once under full-file CAS; no-op/load
preserves existing bytes/version. v8 remains after resolution, empty and later
local publication. Older formats still refuse the new combinations.

The shared paired capture/recovery correspondence previously required v5 even
after local authoring/generation upgraded that same journal. Capture now compares
the exact required/retained version; review, cancellation, retention and removal
preserve the actual v5/v6/v7/v8 version plus all original/revision/other-row guards.
The v1 generation workspace adds an explicit paired refusal to preserve its
boundary when the general pending accessor can validate v8 paired metadata.

## Independent inputs and executed checks

`test/support/native_pending_paired_oracle.py` allocates roots without Home,
BEAM or Swift, from frozen owning originals and a separately constructed tagged
import payload. It now supplies35 valid roots and291 invalid roots, including
both quantity families, import/candidate/review, Unicode, mixed rows, positive
S64 maximum and old-marker/phase/custody/creation/scalar failures. Fixture SHA256:
61a3e844903f3eb4ffb0c2181c298df20ae39ef8c844b787ff4ace015880da4d.

Four initial negative vectors incorrectly treated creation equal to an original's
maximum S64 revision as future. Native acceptance exposed that oracle error.
They now use an invalid zero creation at that boundary, and four positive vectors
express the valid equal-floor case. The codec was not widened to satisfy them.
Older tests also now name v6/v7 explicitly for paired refusal and v9 for an unknown
future marker; they cannot treat newly accepted v8 as unknown.

`mise exec -- mix woh.native.pending.storage.smoke --paired-authoring` passed
independent exact bytes/hash/accessors, malformed roots, old v1–v7 upgrades,
no-op, stale/full-content/inode CAS, exact removal/empty/local version retention,
separate-process crash/load and two competing ordinary/paired publishers with one
winner and one refusal. The full `mix woh.native.pending.storage.smoke` passed
older unsafe-file, bounds/capacity, publication, crash/restart, authoring/generation
and concurrent-upgrade cohorts together with these new cases.

`mise exec -- mix woh.native.paired.recovery.smoke` passed existing actual
pairing/TLS/SQLite original receipt/retry/restart/revocation and unsigned-production
checks. The full capture/review/no-op/cancel/resolve/other-row/substitution cases
now run under each v5/v6/v7/v8 root. New authoring/generation entries have every
action disabled; actual production recovery refuses before its clock producer and
leaves bytes intact. Pure first-capture correspondence also refuses these
uninstalled consumers before publication. No test supplies a successful signing
backend or constructs an authenticated production session.

`mise exec -- mix woh.native.generation.workspace.smoke` passed unchanged v1
workspace originals/private CAS/four process races/restart with paired custody
still refused. Formatting, warnings-as-errors compile, catalogue (22 contracts),
HTML ExDoc with warnings-as-errors and Git whitespace checks passed. Toolchain:
Elixir1.19.6 / OTP28.5.0.6; Swift6.4 on arm64 macOS27, Swift6 language mode targeting
arm64 macOS15. Logs: /tmp/home-native-pending-v8-{storage,regression,paired,workspace-refusal,docs}.log.

NP8-T1–T3 have focused software evidence. Paired v2 workspace and closed signed
authoring/generation consumers remain unimplemented dependencies; publication
alone starts no model or source export. No installed app, signed artifact,
Keychain qualification, live model, power-loss or physical evidence was produced.
No push or repository visibility change occurred.
