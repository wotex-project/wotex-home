# Selected paired authoring implementation evidence

Recorded:2026-10-15. Owner:[selected authoring decisions](../specs/native-paired-authoring-ui-v1.md),
PAU-01/02/03 and composition NPA-01/02/04.
Requirements preceded implementation in bf16046 and 0adb150.
Runtime: d9464081823ff69982cb489b041fe3fbbdf33443 on local main. No Store schema, dependency or sibling API changed.

## Implemented boundary

The selected driver now prepares data, manual draft, complete-original, mapping,
manual assessment and source/fixture review decisions against the paired controller.
Its fixed typed adapter checks actual current profile:manage before invoking private
input loaders. Paired decisions retain frozen original/payload and reviewed scope,
identity/basis/selection metadata, with no bearer, local capture or reusable session.
Actual signed factories remain the only production custody acquisition path.

Human confirmation obtains a fresh actual selected session and rechecks the exact
reviewed revision, unchanged grants, association and applicable contract basis.
The same confirmation lease covers pending publication, the fixed original-purpose
runner, an existing-only typed receipt read, removal/publication and UI delivery.
Only the actual sealed publication supplies the paired receipt; the old receipt-only
submission entry refuses paired decisions. Actor-hop expiry/selection failure
remembers uncertainty. Scope/custody/transport failure retires private panel context.

Authoring now has a separately confirmed absent acknowledgement, local or paired.
Lookup retains missing; acknowledgement only reads original status/identity and may
clear missing metadata after explicit accepted uncertainty. A present receipt resolves
its checked result. It does not submit, cancel, undo authoring or change model budget.
Paired first-send errors still retain their original for explicit recovery.

## Executed checks

Pinned Elixir1.19.6/OTP28.5.0.6 via `mise exec --`; Swift6.4 in Swift6 mode,
warnings-as-errors, arm64 macOS15 target on the development host.

- `mix woh.native.paired.recovery.smoke`: actual pairing, pinned TLS, private
  SQLite/custody across temperature/research and complete/running-restart cohorts.
  New fixed preparation paths cover data import, complete import, manual draft,
  actual owned draft to compatible assessment and incomplete source review.
  Fresh validation accepts unchanged review metadata and refuses the old revision
  after import. Dropped committed replies retain exact originals; status-first
  retry makes zero mutations for known results. Revocation refuses before the
  private input loader runs. Existing authoring restart/revocation and generation
  provider/cancellation/original recovery cohorts remain included.
- Confirmed absent acknowledgement resolves present authoring to its actual receipt;
  missing lookup retains and confirmed absence clears only v8 client metadata.
  Store revision does not change. Fixture-only re-retention preserves subsequent
  restart/revocation coverage. These raw cases exercise the shared runner through
  paired transport; there is no separate new local absent-ack integration case.
- `mix woh.native.controller.session.smoke`: shared selection, actual local reads,
  original recovery/CAS and remote no-fallback passed. All five paired preparation
  entry points with missing private files reach actual unsigned factory denial
  before local capture or supplied clock use; the capture/clock probe remains zero.
- `mix woh.native.pending.storage.smoke --paired-authoring`: independent v8 bytes,
  old-version refusals, private-file guards, CAS/restart and competing publication
  passed with the authoring absent action included. The byte corpus is unchanged.
- `mix woh.native.authoring.panel.smoke`: local confirmations, delayed retirement,
  private review and mounted layouts passed. The 480-point prepared draft render
  was visually inspected: details wrap and confirmation/submission remain readable.
- `mix woh.native.generation.flow.smoke`: the full native source closure compiled
  and the existing two-family local first-decision, repair, cancellation and fresh
  manual-assessment flows passed. Generation selected composition stays disabled.
- `mix test test/macos_app_inventory_test.exs`:2 tests passed; the assembly source
  inventory contains the new fixed preparation adapter and shared selection reader.

Focused formatting, compilation with warnings-as-errors, the22-parent specification
catalogue, HTML ExDoc with warnings-as-errors and Git whitespace checks passed.

The initial panel compile exceeded its old60-second fixture bound. The focused
helper now allows90 seconds only for the full driver closure, keeping smaller
fixtures at60 seconds. Expanded multi-action raw transport scenarios exceeded
an old20-second script envelope; manual stage/workspace scenarios now have45
seconds. Individual raw transport owners still have15 seconds and production
signed sessions retain their original five seconds. The passing reruns use those
explicit fixture bounds; none renew a production lease or model budget.

Independent v8 input SHA256:
`61a3e844903f3eb4ffb0c2181c298df20ae39ef8c844b787ff4ace015880da4d`.
Unchanged `mix.lock` SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.
Logs are under `/tmp/home-native-paired-authoring-*.log`, with the full-closure
flow log at `/tmp/home-native-paired-authoring-ui-compile.log`.
Only bounded public diagnostics are emitted; synthetic keys use stdin/private
fixture custody. No real model account, source locator or hardware is accessed.

## Remaining acceptance

Positive preparation/recovery uses a raw fixture adapter, not a successfully
signed native session or caller-created seal. Actual production factories are
checked for refusal only. Fresh signed confirmation, ordered publication and
post-hop lifetime are implemented but positive installed app/Keychain, expiry
and selection races through that successful path remain PAU-T3/T4 obligations.
Mounted local snapshots do not establish paired interaction/accessibility.
Complete candidate/review originals and nonempty selectors retain their owning
codec/Store checks; the new raw complete-original case covers import only.
Selected generation/workspace presentation, live source/configuration/provider
confinement, power-loss and hardware qualification remain separate work.
Physical dispatch remains disabled.
