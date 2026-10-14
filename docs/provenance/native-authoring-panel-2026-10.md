# Native authoring first-decision evidence

Recorded: 2026-10-14. Owner: [first-decision panel](../specs/native-authoring-panel-v1.md).
Level: private-file/native peers, visible rendering and actual Store/archive.

The contract preceded implementation in `9cabe22`; runtime is local main commit
`9a7fba0`. Actual owner refusal names
were reconciled in `66c5e75` and stable preparation watermarks in `776e9f1`.
The Things panel explicitly prepares existing private original/payload files,
shows exact identity/CAS/hash metadata and requires a separate confirmation.
The selected local driver verifies current permission at one unchanged watermark,
same credential/reference and selection generation, publishes complete v6 custody
through the shared coordinator, then submits the unchanged original. No original
field or CAS is rewritten. Paired preparation refuses before local file/custody
or API work.

Elixir 1.19.6 / OTP 28.5.0.6, Apple Swift 6.4
(swiftlang-6.4.0.34.1, clang-2100.3.34.1), Swift 6 language mode and
arm64-apple-macos15.0 target executed:

- `mise exec -- mix woh.native.authoring.files.smoke`: private descriptor/name/
  identity, regular type, mode, links/ancestor links, NUL/nonfile URL, empty/over
  bound and full 256-KiB binary cases passed without API or credential acquisition.
  The first reader incorrectly required Foundation's filesystem-dependent
  standardized URL spelling to equal its literal private path. That rejected a
  legitimate file. It now checks absolute/NUL/dot-component bounds and actual
  ancestor/name/descriptor identity without weakening link/mode/owner checks.
- `mise exec -- mix woh.native.authoring.panel.smoke`: six framed peer cases
  passed, including owner/principal/epoch/watermark substitution and permission
  refusal. Preparation/confirmation, repeated-click exclusion, delayed input/
  session/wake retirement and seven mounted prepared/error renders passed at
  480/599/600/839/840 points. The 480-point prepared PNG in
  `_build/native/authoring-prepared-480.png` was visually inspected: metadata wraps,
  approval/selection remain separate and no private source contents are shown.
  These model sender fixtures establish presentation only; Store publication
  and mutation correspondence are tested below.
- The explicit three-archive command in
  [operator evidence](authoring-operators-2026-10.md) passed 81 component cases and
  five actual Store workflows; the latter completed in 60.1 seconds including
  fresh Swift compilation. Temperature and research each now use the real
  selected-driver/model preparation and first submission for fresh candidates
  and complete reviews. A proxy observes full v6 publication before mutation,
  discards committed replies and verifies separate-process exact retry/lookup
  without another Store revision. Full binary import uses the same panel path.
  Failed publication and later revoked capture retain their prior guarantees.
  An independently checked stale owned-reference refusal clears only its new
  initial local record by file CAS, leaves no candidate original and creates no
  Store revision; unknown/later refusals retain their original.
- `mise exec -- mix woh.native.controller.session.smoke`: existing actual Store
  selection/recovery/CAS cases passed, with a paired authoring preparation that
  reads no file and captures no local credential. Full app warnings-as-errors
  Swift type checking passed. Three macOS inventory/SPDX cases passed in 0.4
  seconds; explicit assembly sources include the panel/file reader. Format,
  warnings-as-errors Elixir compilation, the 22-contract catalogue and Git
  whitespace passed. Application dependency sources remain unchanged.

Consumer lock SHA:
`6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
Store fixture SHA:
`27148383bc040ecc59794afa923971c05974e3b54b594400bbccc9baf9aa426f`.
Early failed file/fixture/compiler runs were corrected and are not counted as
passing evidence. The initial refusal fixture used an unowned placeholder and
did not produce the intended named refusal; it now checks the actual Authority
stale owned-reference result independently before native submission.

This is bounded software evidence. Arbitrary file mutation races, every scope/
publication/resolution interleaving, installed accessibility/signing and disk
power-loss remain unqualified. Paired authoring, ergonomic draft construction,
host meaning/source installation, application producer adoption, provider handoff
and physical qualification remain separate obligations. No producer contract,
authority, approval or target selection is manufactured by the panel.
