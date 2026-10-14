# Native authoring pending custody evidence

Recorded: 2026-10-14. Owner: [pending custody v6](../specs/native-pending-custody-v6.md).
Level: native codec, actual private file/CAS and separate-process software.

The owning contract preceded implementation in `05dad97`. The v6 authoring
category retains the full canonical original and verified import payload, with
no credential/path substitute. Native payload/frame correspondence reuses the
strict object SDK; candidate/review retain null payload. Only the named v6 slots
grow, and old roots still refuse beyond 65536 bytes. Publication upgrades the
root through the existing private whole-file CAS. No authoring mutation runner
is invoked; pending presentation explicitly disables unavailable recovery.

Elixir 1.19.6 / OTP 28.5.0.6 and Apple Swift 6.4
(swiftlang-6.4.0.34.1, clang-2100.3.34.1), Swift 6 language mode and
arm64-apple-macos15.0 target executed:

- `mise exec -- mix woh.native.pending.codec.smoke`: independent existing closed
  vectors, schedule originals and ordinary string/number/custody bounds passed.
  Existing entries also round-trip in v6; unknown version refusal now uses v7.
- `mise exec -- mix woh.native.pending.storage.smoke`: existing private mode/link/
  lock/inode/CAS and process restart/race checks passed. The separate authoring
  fixture upgrades each v1..v5 root while preserving its old original, verifies
  full 256-KiB binary custody, exact no-op bytes, stale CAS, resolution and retained
  v6 after empty/later ordinary publication. It round-trips independent candidate/
  review originals and a UTF-8 review above 65536 bytes, and refuses wrong payload,
  phase, epoch, native role/revision and authoring paired custody.
  Sixteen maximum imports produce a root above 5 MiB and below 8 MiB and retain
  complete originals; a seventeenth refuses without file change. A separate
  process retains and exits with an import, and another reloads identical bytes.
  Two independent processes race ordinary/v6 publication from one v5 snapshot
  with exactly one winner; a fresh reader validates the preserved root/originals.
- `mise exec -- mix woh.native.pending.paired.smoke`: the existing seven valid/
  31 invalid paired vectors, joins, private CAS, restart, competing publication
  and local recovery refusals passed. Its obsolete unknown-v6 negative vector
  now uses v7; valid older paired bodies remain unchanged.
- `mise exec -- mix test test/macos_app_inventory_test.exs
  test/macos_app_spdx_test.exs`: three cases passed in 0.5 seconds. Explicit app
  and fixture compilation closures include the new native authoring sources.
  Full app warnings-as-errors Swift type checking, Elixir warnings-as-errors
  compilation, formatting, the 22-contract catalogue and Git whitespace passed.
  `mix.exs` and `mix.lock` remain unchanged.

The initial combined storage fixture exceeded its existing 15-second quick-check
budget at full 5-MiB saturation. That new case is now a separate authoring fixture
with a bounded 45-second budget; ordinary checks keep 15 seconds. Early compiler
runs interrupted by source edits were discarded and rerun after edits settled.
No timed-out or interrupted run is counted as passing evidence.

Storage fixture SHA:
`e978e915a8a17465f7490f151ba7dfaeb0525b5997f95f6dfa1444b415461491`.
Current paired vector SHA:
`f896b305a243cbcc90625717518af7ee97774a472578be7326a675dd15231dc4`.
Full valid-history saturation here covers the native journal's sixteen import
entries; it does not establish unrelated Store quota saturation or arbitrary
interleavings. Mutation/receipt recovery and native first submission remain
successors. No fresh app bundle, installed signed custody/accessibility, target
disk power-loss or physical qualification was tested.
