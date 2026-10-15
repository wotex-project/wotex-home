# Native generation first-decision evidence

Recorded: 2026-10-15. Owning contract:
[native generation first decisions](../specs/native-generation-ui-v1.md).
Runtime: 8754413613a21119a699454bf4c13038e2c2c7d4 on local main.
The accepted first-decision requirements preceded code in 78d1985; explicit
interrupted-publication restoration and archive uncertainty preceded their
implementation in 7b93f59. No schema, dependency or sibling API changed.

## Implemented boundary

The selected local driver checks association generation, metadata fences, exact
manual/native Operator custody, current identity, contract and policy before
freezing an original. Policy, permitted selections, remote consent and all three
budget fields require explicit choices. Workspace publication precedes complete
pending publication, which precedes the unchanged SDK mutation. No model starts
with preparation, opening, editing or workspace loading.

An explicit restore action checks original custody and existing-only status,
then publishes the retained root or last attempt into pending recovery. It does
not generate another identity or send a generation mutation. Ordinary lookup
and retry retain their existing separate meanings. Repair requires the actual
invalid owned predecessor and explicit feedback consent. Cancellation publishes
local intent first; only matching cancelled status clears it.

The Things generation panel composes these decisions and explicit status reads.
Generated draft bytes/import identity are checked against the result, then used
for a fresh ordinary manual candidate under the current contract/basis/CAS.
The actual manual receipt enters the existing authoring review workflow; no
source attribution, fixture success, approval or control follows automatically.
Editing, policy changes and session invalidation retire decisions/confirmation;
late responses cannot restore retired private content.

## Executed checks

`mise exec -- mix woh.native.generation.flow.smoke` passed for both frozen
quantity families against actual private SQLite Store and framed local sockets.
The fixture supplies a scripted invalid first draft and a frozen repair draft.
It checked:

- Explicit policy, selections, budget and remote consent, with missing consent
  refusing before publication.
- A symlinked pending file after root workspace publication and an unsafe-mode
  pending file after attempt append. Both refused before generation mutation.
  Fresh coordinator instances reloaded durable workspace and restored identical
  original ID, revision, SHA and bytes into pending recovery.
- Committed preparation/start replies deliberately dropped. Explicit original
  recovery used status rather than repeating each recorded mutation. The proxy
  checked complete workspace and pending originals before every mutation.
- Invalid-candidate repair refused without feedback consent and retained exact
  prior raw draft/report when consent was supplied. Two provider calls occurred
  per family: the initial attempt and the explicit repair.
- An actual fresh manual candidate receipt with source review `not_assessed`.
  A constructed panel/model made no implicit generation action; policy changes
  cleared selections/export consent/confirmation.
- Deterministically held capture responses delivered after invalidation, and a
  held manual-assessment preparation delivered after its instruction changed.
  Neither restored the retired decision or confirmation.
- Cancellation intent present before cancellation, a committed cancellation
  reply dropped, intent retained and further attempt preparation refused, then
  existing-only cancellation lookup cleared intent. Exact workspace archival
  retained the versioned empty file and controller history.

The strengthened proxy makes missing workspace publication fail, rather than
treating an absent workspace as an optional check. Fixture publication failures
are filesystem refusals; fresh coordinators model loss of volatile state. The
separate workspace and SDK evidence owns independent-process/Store restart.

`mise exec -- mix woh.native.generation.sdk.smoke` also passed all 3942 wire/
original-delivery cases and its default both-family Store/socket/queued-result/
restart cohorts after the shared fixture provider changes. Formatting,
warnings-as-errors compilation, catalogue checking (22 contracts), full HTML
ExDoc with warnings-as-errors and Git whitespace checks passed. The affected
app inventory/SPDX/native-dependency tests passed: 5 tests, 0 failures.

Toolchain: mise Elixir1.19.6 / OTP28.5.0.6; Apple Swift6.4 on arm64 macOS27,
compiling Swift6 language mode for arm64 macOS15. Logs:
/tmp/home-native-generation-flow-store.log,
/tmp/home-native-generation-flow-sdk-regression.log,
/tmp/home-native-generation-flow-packaging.log and
/tmp/home-native-generation-flow-docs.log.

## Remaining obligations

NGU-T3–T5 have focused software evidence, not complete acceptance. Ordinary
pending lookup still retains an absent original. Separately confirmed absence
acknowledgement is required before every first-refusal workspace can be archived;
restoration alone does not finish that reconciliation requirement. Current guard
withdrawal/expired/unknown paths retain the owning SDK/Store checks and need the
remaining selected-panel acceptance cases.

The app source list and macOS CI include this flow. No installed app, signed
artifact, release, firmware, external model/account, Keychain qualification,
installed visual/accessibility evidence or new hosted green run was produced.
Nothing was pushed. Source/fixture review, signed paired generation, confinement,
storage power-loss and physical qualification keep their separate gates.
Unrelated drafts and client settings were preserved.
