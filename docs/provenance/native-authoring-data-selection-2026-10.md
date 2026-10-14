# Native data import and selection evidence

Recorded: 2026-10-14. Runtime source:
c43324f9f258cfcf46b225a9c1e93047dce7597c on main.
Owner: [native data import and selection](../specs/native-authoring-data-selection-v1.md),
WOH.08 native decisions and WOH.18 inert authoring custody.

The local native driver prepares all eight existing inert kinds without an
installed authoring producer. It constructs current epoch/CAS originals from
private exact bytes and returns handles only from matched import receipts.
Manual assessment reads each explicitly selected owned source/fixture inside
one before/contract/after revision bracket, then retains exact sorted handles
in its complete original. Existing Store checks remain authoritative.

## Executed checks

Elixir 1.19.6 / OTP 28.5.0.6; Apple Swift 6.4, Swift 6 mode, arm64 macOS 15
target. Mix commands used WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test.

`mix test test/wotex_home/native_authoring_data_selection_test.exs` passed one
substantial test in 63.0 seconds, including fresh complete native compilation.

- Default Host without installed authoring producer: all eight kinds preserve
  arbitrary binary bytes, independent raw and full WOHA hashes, matched receipt
  identity and owned Store payload. An exact 262144-byte source uses the bounded
  upload path. Reimport preserves historical first revision under a new operation.
- Exact framed proxies inspect complete v6 import payload/original, candidate
  and review originals before the first upload/probe/final request. A final
  committed import reply is discarded: no native handle appears, the original
  remains pending, and a separate Swift process resolves by lookup without an
  additional Store revision.
- Both independent temperature/research families run native draft/source/two
  fixture/envelope imports, selected assessment and complete review. Independent
  canonical decoding compares exact selected handles and input SHA with retained
  Store results. Review records attributed source and complete inert proposal.
- Each family rejects 18 selection/file variants: missing source, wrong kind,
  wrong revision, duplicate/unsorted handles, unknown root/handle fields,
  boolean/float/overflow/zero/negative revisions, excessive count, missing root
  field, another principal's object, duplicate JSON key, oversize and invalid
  UTF-8. Only the explicitly requested draft import commits; no candidate does.
- Malformed object hashes refuse. Real concurrent principal provisioning during
  selected reads advances the revision; the final bracket fences the candidate.
  The real Store itself refuses retained frames above 4 MiB. A separate hostile
  peer supplies independently valid maximum-size frames to check the native
  aggregate guard: it stops at frame 16, before candidate publication.
- Empty, oversize and nonprivate data files refuse with no publication/revision.
  Shared work guards prevent preparation. Six delayed data-preparation events
  (file, kind, entry, session, wake, cancel) retire delivery; repeat busy clicks
  produce one call. Selection edits retain the owned draft and clear prepared
  assessment. Construction issues no preparation call.
- Prepared data, matched receipt and selected assessment forms render at logical
  widths 480, 600, 720, 980 and 1320 points. Inspected 480-point receipt and
  selected-assessment images: long identities wrap; explicit copy handle and
  selected counts are visible. Images are _build/native/authoring-data-*.png
  with a 2x backing scale. Vertical content uses the existing scroll container.

Ten existing candidate/review/export regressions and 181 complete-original
native cases passed. Complete application typecheck, fresh all-source fixture
compile, formatting, warnings-as-errors Home compilation, 22-contract catalogue
and Git whitespace checks passed. The minimal codec smoke caught a new private
file dependency in the read client; moving the selection helper into the
controller driver restored its existing source closure before the final passes.

Fixture source SHA256:
fbd24b495e932fa9cce805f3e0c3cf6c73acfce474f2eb77005b5a1fcfffa6f7.
Logs: /tmp/home-native-data-selection.log, /tmp/home-native-data-regressions.log,
/tmp/home-native-data-original.log. Early fixture failures included wrong API
names, wrong owned-read payload field and a lost-reply proxy that discarded the
upload-required probe rather than the committed result; corrected before passing.

This establishes local software behavior. Installed signing/accessibility,
paired authoring, mapping/review editors, remote generation authorization,
source authenticity and physical qualification remain separate obligations.
No sibling API change, dependency update, remote push or visibility action was
needed. Catalogue parents retain their broader partial/missing evidence axes.
