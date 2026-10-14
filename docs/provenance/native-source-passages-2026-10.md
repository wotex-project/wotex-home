# Native source passage evidence

Recorded: 2026-10-14. Runtime source:
49a3aa8be2d36d6372ecfc7fcb0aee38d40b9709 on main.
Owner: [bounded native source passages](../specs/native-source-passages-v1.md),
WOH.08 native reads and WOH.18 inert source custody.

The SDK uses the existing authenticated source-passages route, validates bounded
sorted selectors before I/O and verifies every returned tuple, text byte length
and passage hash. Source payload hashes and historical first revisions remain
authenticated Store assertions; partial text cannot prove full source identity.
The selected driver brackets the immutable read with same-authority identities,
nonregressing revisions and current selection guards. Paired selection refuses
before local capture or paired transport. The history view exposes explicit
byte ranges and inert plain text, clearing retired or failed deliveries.

## Executed evidence

Elixir 1.19.6 / OTP 28.5.0.6; Apple Swift 6.4, Swift 6 mode, arm64 macOS 15
target. Mix commands used WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test.

`mix test test/wotex_home/native_source_passages_test.exs` passed one substantial
test in 45.6 seconds, including fresh complete native fixture compilation.

- Default actual Host/Store imports temperature/research sources, frozen Unicode
  source vectors and a source containing U+202E plus instruction-like text.
  Native SDK reads overlapping explicit ranges; the model reads one explicit
  range. Independently sliced bytes/raw hashes and frozen Unicode expectations
  match. No read advances the Store revision or creates a pending file.
- SDK preflights reject mismatched selectors, malformed digests, boolean/float
  metadata, length/hash changes, control text, missing/extra/reordered records,
  duplicate/unsorted/empty requests, excess count and invalid range bounds.
  Invalid requests use an absent socket and empty credential and must return
  invalidProfileRequest before I/O. An independent 32-range vector at 4096
  bytes each passes exactly 131072 bytes. A control-text vector with matching
  byte length and hash still refuses. Not-found has an exact closed envelope.
- Actual ownership/wrong-kind/split-UTF-8/out-of-range refusals run through both
  Store and the native driver/model, producing no text and no revision change.
- Framed peers change final owner/principal/epoch, regress the watermark, assert
  future historical revision, alter the passage hash or add an unknown response
  field; every native read refuses. Not-found returns no text. Real concurrent
  principal provisioning between projection and final identity succeeds with
  an advancing watermark; the only two revisions are those injected mutations.
- Temporary paired public metadata selects a remote controller. Its local
  capture throws if called and its local socket closure traps if reached.
  Source reads return unavailable before either or trusted paired-clock work.
- Seven delayed UI retirement events (source digest, offset, length, another
  history selector, session, wake, cancel) cannot restore source text. Busy repeat
  starts one read, construction starts none, shared work guard refuses, canonical
  decimal input refuses 00, and sequential success/not-found/failure clears old
  text. Reflection of the model and passage omits passage contents.
- Forms render at logical widths 480, 600, 720, 980 and 1320 points. Inspected
  the 480-point Unicode and format-control forms: metadata wraps, persistent
  offset/length labels remain visible and U+202E appears as [U+202E] in inert
  text. Original byte length/hash stay unchanged. Images are
  _build/native/source-passages-{temperature,research,unicode,format,peer-advance}-*.png.

Five existing source-projection tests and 272 native history peer / 22 selected
session cases passed. Complete application typecheck and fresh complete fixture
compile reject warnings. Formatting, warnings-as-errors Home compilation,
22-contract catalogue and Git whitespace checks passed. An early fixture
expected {:error, :not_found}; Store actually returns :not_found. The expectation
was corrected and native refusal coverage added before the final passing run.

Fixture source SHA256:
8626b1c0aee6966831ef4ed09142815a1fc571b6ba52a297fe260cc980243b1d.
Logs: /tmp/home-native-passages-live.log, /tmp/home-native-passages-read.log,
/tmp/home-native-passages-regressions.log, /tmp/home-native-passages-typecheck.log.

This is local software and foreground render evidence. It does not establish
source authenticity, installed signing/accessibility, paired source export,
provider authorization or physical qualification. No sibling/dependency change,
remote push or repository visibility action was required. Broader parent
contracts retain partial implementation and missing complete acceptance evidence.
