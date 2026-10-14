# Native review editor evidence

Recorded: 2026-10-14. Runtime source:
95ee83b9785e1f49a382916f192eb8ac60176c6e on main.
Owner: [native review editor](../specs/native-review-editor-v1.md), WOH.08 native
decisions and WOH.18 inert source/fixture review.

The native review entry now offers typed citation/unresolved rows, source or
complete mode and explicit owned-envelope fields. File entry remains available.
Both use one selected-local preparation boundary and the unchanged canonical
review original, current basis fencing and private v6 publication. Typed rows
preserve insertion order in the editor and sort by exact UTF-8 bytes for the
original. No locator is fetched and no source is added to its candidate.

## Executed checks

Elixir 1.19.6 / OTP 28.5.0.6; Apple Swift 6.4, Swift 6 mode, arm64 macOS 15
target. Mix commands used WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test.

`mix test test/wotex_home/native_authoring_review_preparation_test.exs` passed
the expanded actual-store test in 75.6 seconds, including fresh full native
fixture compilation. It exercises both temperature/research families:

- File and editor source/complete reviews derive the same actual candidate
  reference and current CAS. Editor citations are deliberately reversed; an
  independent canonical decoder compares retained fields against the supplied
  sorted fixture evidence. Actual Store receipts retain input SHA and distinct
  attribution/consumption/fixture/proposal outcomes.
- Exact framed proxies inspect the full v6 original before review upload,
  probe and final request. Both file and editor lost committed replies retain
  their original; separate Swift lookup resolves without another revision.
- Five missing/incompatible/future/basis/watermark scenarios run through
  both file and editor entries without publication or revision change. Existing
  malformed private-file, duplicate-key, controlled-locator, duplicate-root and
  size refusals remain green.
- Real principal revocation after candidate read refuses before publication.
  A real Store revision change at submission fences the prepared CAS before
  publication. An imported actor-owned source absent from the candidate refuses
  at Store review after publication, resolves the known refusal from pending
  custody and commits no review revision. No source-set bypass is inferred.
- Pure typed-content checks cover exact 256 citations, 64 unresolved roots and
  256-byte locators; excessive counts, duplicates, bad roots, empty/oversize/
  Cc/Cf locators, invalid envelope handles and wrong mode/envelope pairs refuse.
  Composed/decomposed Unicode locators remain two byte-distinct sorted entries.
  A selected driver with a capture closure that throws and a socket closure
  that traps refuses malformed editor content before either is reached.
- Fifteen delayed editor events (path/source/locator/Unicode bytes, citation
  add/remove, unresolved edit/add/remove, mode/envelope, entry, session, wake,
  cancel) retire the decision and confirmation. Session/wake/cancel preserve
  editable rows. Busy row actions and repeated prepare start no extra call.
  An added blank row disables prepare; explicit removal permits fresh prepare.
  Existing file retirement checks still run separately.
- File/editor prepared views render at logical widths 480, 600, 720, 980 and
  1320 points. Inspected the narrow complete-editor form: persistent candidate
  and citation labels, byte/count limits and explicit remove controls fit;
  citation rows remain in operator order. Existing scroll container exposes the
  remaining rows, envelope and confirmation below the viewport. Digests in edit
  fields use normal horizontal field scrolling. Images are
  _build/native/authoring-review-{source,complete,editor-source,editor-complete,lost,editor-lost}-*.png.

Seven existing review/export regressions pass. The 181 complete-original native
cases pass with typed editor reconstruction of valid review vectors and empty
reflection for content and individual citations. Typed content/handles were
moved into the pure original codec file after the live pass; the final narrow
SDK compile/reconstruction and full application typecheck verify that source
closure and reflection-only adjustment without rerunning unrelated Store work.
Formatting, warnings-as-errors Home compilation, catalogue and Git whitespace
checks passed. Full-suite, installed-host or physical gates are not claimed.

Early fixture failures were an optional async closure inference error and a
fixture reading malformed file content outside the driver. An explicit callback
type and editor-only fixture content loading corrected them before the passes.

Live fixture source SHA256:
d273ac530f930465e6593dec3d349267fd3e67b6664f9682581281bf565ce661.
Logs: /tmp/home-native-review-editor-live.log,
/tmp/home-native-review-editor-codec.log,
/tmp/home-native-review-editor-regressions.log,
/tmp/home-native-review-editor-typecheck.log.

This establishes local software and foreground rendering. Installed signing/
accessibility, paired mutations, mapping editing, provider authorization,
source authenticity and physical qualification remain separate. No dependency
or sibling API change, remote push or visibility action was needed. Broader
catalogue implementation/evidence axes remain partial/missing.
