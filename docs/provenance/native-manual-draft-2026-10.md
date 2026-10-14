# Native manual draft decisions evidence

Recorded: 2026-10-14. Owner: [manual draft successor](../specs/native-manual-draft-v1.md),
WOH.08 native decisions and WOH.18 inert manual authoring.
Runtime source: 387001d887767572d329724d66a2cd3aff76621e.
All work remains on main; no remote ref was pushed.

The native authoring surface can prepare/import a private draft without an
operator-authored operation file. After its verified receipt it separately
prepares manual candidate assessment from the actual owned handle and current
exported grammar/limits. Both confirmations use existing full v6 publication
and original recovery. A stored manual basis is checked again immediately
before publication. File/source/session changes do not retarget a prepared or
published original; a lost import cannot trigger assessment. Mapping editing,
source/fixture review editing, generation and signed paired mutation remain
separate successors.

## Executed checks and independent oracles

Toolchain: Elixir 1.19.6 / OTP 28.5.0.6 and Apple Swift 6.4, Swift 6 mode,
arm64 macOS 15 target. Mix checks used WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test.

- mix test test/wotex_home/native_manual_draft_test.exs: one substantial test
  covering both independent temperature/research families passed in 52.2
  seconds, including fresh full client/driver/model Swift compilation. Each
  family imports, assesses, reimports identical bytes and reassesses, preserving
  the actual historical first_revision. Actual Store revisions are 1 through 5;
  a discarded final import reply commits revision 6 once and retains the exact
  original. A separate Swift process queries/resolves it without a new revision.
- The exact-framed proxy checks full canonical v6 originals and original payload
  before initial import probes/final calls and before each candidate call.
  Independent Elixir AuthoringObject/Import/Candidate APIs check the native
  frame/digest/input, and actual Store status checks its returned receipts.
  The source never regenerates expected drafts from the native builder.
- The proxy changes only the second exported Home basis assertion while grammar
  and limits remain the same. Native confirmation refuses before any import/
  candidate request, pending publication or revision change. This exercises
  the complete reviewed basis separately from grammar identity.
- mix woh.native.authoring.panel.smoke passed existing original-file preparation/
  confirmation cases and new manual UI checks. No I/O occurs on construction;
  repeated clicks during delayed preparation produce one call. File, entry,
  session, wake and cancellation retire late prepared values. Unknown import
  leaves no owned handoff and prevents assessment. Reflection omits payloads.
- Foreground renders cover prepared import and actual owned-draft views at
  logical widths 480, 600, 720, 980 and 1320 points. PNG backing scale is 2x on
  this host. Inspected prepared/owned 480-point images: long digests and operation
  IDs wrap without horizontal clipping. The prepared form is vertically scrollable.
  Artifacts live under _build/native/manual-draft-{prepared,owned}-*.png.
- mix woh.native.authoring.files.smoke passed private descriptor, ancestor/leaf
  link, mode, binary byte and size checks. mix woh.native.authoring.original.smoke
  passed 181 complete-original cases. The existing 272 read and 22 selected-session
  cases passed after the shared tagged-frame builder and backend preparation
  changes. Nine export/Host/candidate regressions passed.
- Complete native application sources typechecked with warnings rejected.
  Formatting, warnings-as-errors Home compilation, 22-contract catalogue and
  git diff --check passed.

The live fixture source raw SHA-256 is
84b2a412252a9562543719108fb39c9671b821976dd03ad448c145368405f8a7.
Initial assessment preparation found that the
native codec accepts Foundation/Int scalars rather than unbridged Swift Int64;
the builder now converts its typed signed-64 limits/handle to exact arm64 Int
before codec use. No shared wire integer guard was relaxed.

Logs: /tmp/home-native-manual-draft-live.log, /tmp/home-manual-draft-panel.log,
/tmp/home-manual-draft-files.log, /tmp/home-manual-draft-originals.log and
/tmp/home-manual-draft-app-typecheck.log. These checks establish software and
foreground rendering only. They do not establish installed accessibility,
signing, fresh-account delivery, paired mutation, physical correspondence or
device qualification. Existing dispatch defaults remain disabled; catalogue
contracts retain their broader partial/missing axes.
