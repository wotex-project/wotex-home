# WOH.16 — Release, update and recovery contracts

Version: 0.1.88. Status: accepted target.

## Release identity

[Final power commit guards](power-commit-v1.md) discard tentative claim/handoff
history on refusal while preserving necessary sticky suspension, original
provenance and prior causal spend. SQL failure rolls back the entire enclosing
transaction. Existing durable handoffs retain their uncertainty and recovery
semantics; this change adds no schema, archive shape or current clock confidence.

[Prepared schedule calculations](schedule-poll-v1.md) use a bounded in-memory,
caller-bound Store snapshot. It is absent after restart, transfer or restoration
and grants no durable clock confidence. Commit shares the existing atomic
occurrence/cursor/request publication and original receipts; failure or a lost
reply cannot rewind the cursor or reuse the one-use preparation.

Schema 27 archives retain [scheduled intent provenance](schedule-effects-v1.md)
with exact consideration, original request journal, distinct causal root and
effect-operation correspondence. Migration conserves old root columns and spends,
and gives calculation-only occurrences no request authority. Transfer retains
nonempty provenance while superseding archived author/epoch authority. Historical
handed work becomes outcome unknown after restart without refund; copied clock
records and restored history grant no current temporal confidence or activation.
[Store-owned advancement](schedule-advance-v1.md) terminalizes old-boot unsent
occurrences without renewing them, preserves spent roots on queued/claimed
expiry and leaves handed uncertainty intact. Savepoints undo tentative admission
on policy refusal; actual SQL failure rolls back every change in the bounded
batch. Immutable original occurrence and effect provenance remain unchanged.

Schema 26 archives retain [occurrence consumption and cursors](schedule-occurrences-v1.md)
with exact original calculation, activation, generation and journal correspondence.
Guarded transfer preserves nonempty history and watermarks while superseding
old authority; older supported sources normalize empty occurrence tables. A
same-owner software restart requires fresh qualified clock custody and cannot
replay a consumed UTC coordinate. Restored history remains quarantined and
contains no current clock source or effect authority.

Schema 25 archives retain [schedule lifecycle history](schedule-lifecycle-v1.md)
with complete original, ownership, clock-calculation, generation-barrier and
request-invalidation correspondence. Transfer keeps nonempty activation rows
while superseding their original generation and author. Older supported transfer
sources normalize an empty lifecycle table. Same-owner software restart requires
fresh boot-bound clock custody; copied historical clock records grant no source
confidence or receiving-owner activation. Restoration remains quarantined.

Schema 24 archives retain the exact [temporal review/admission history](schedule-ledger-v1.md)
and validate its source/artifact/journal correspondence. Supported older source
schemas normalize empty temporal history during guarded owner-transfer installation.
A software transfer case retains a nonempty admission while revoking its original
author and grants; restore and acceptance create no active schedule, qualified
clock or timer. Physical clock, power-loss and installed-host evidence remain
separate qualification obligations.

Encrypted database-only and inclusive-profile archives now verify exact schemas
4–26. Historical schemas 20, 21, 22, 23, 24 and 25 remain supported with their own table sets; migration
adds fresh local ownership without granting permissions or changing receipts,
epoch or revision. Schema 21 retired-source origin/head/history is validated
before archive use. Restore stays quarantined and ordinary retired-source startup
is refused. Foreground source retirement verifies the exact original receipt in
its inclusive archive before owning-supervisor shutdown, with private bounded
stdin credential/key input. Interrupted delivery has a locked, no-migration
offline retired-source reader with no normal Host, socket or device worker.
Verification returns the hash/size of the exact authenticated encrypted bytes.
No archive or signed isolation codec alone activates a destination.

Schema 23 archives retain the exact original native access ledger, inputs,
receipts and journal correspondence. Active schema 22 migration preserves
original custody and revisions, adding an empty ledger; unexplained native
grants roll back migration. Retired schema 21/22 sources are never migrated by
normal startup or read-only export. Guarded quarantine acceptance installs the
new empty table inside its transaction while retaining old table correspondence.
Actual software transfer tests carry native access history across a second
ownership handoff, remove the old grant and leave fresh receiving custody with
zero targets. Full source commitments include the actual schema and every
retained native row. Temporary missing profile bytes do not rewrite custody or
access history; live runtime use still requires the actual artifact.

The release now includes `bin/wotex_home_recovery`, sharing the exact bounded
stdin/lifecycle implementation with the checkout recovery command. Foreground
export/retirement and explicit transfer bootstrap start only an opted-in private
Host; offline verify/stage/retired-source export start no normal Host. The helper
is inventoried and attributed as Home source in the component/SPDX closure.
Release smoke verifies its packaged entry point; packaged Store checks exercise
retirement, immutable archive correspondence and reopened source export. Fresh
artifact execution remains required before reporting a particular release pass.

Trusted `new-owner OWNER_FILE` now provisions a private immutable destination
identity, returning only its public ID and custody digest. It consumes no key,
starts no Home service and grants no authority. Exact source retirement chooses
that ID explicitly; destination activation remains a separate guarded stage.
Trusted inclusive retired-source review now binds exact authenticated source
SQLite bytes and complete retained rows/schema as well as encrypted bytes.
Quarantine comparison allows only the staged integer marker; matching data
creates no current credential, observation, rule or activation authority.
Its trusted private domain set includes every retained device target/history;
incomplete transport or counter dependencies block accepted isolation scope.
Canonical acceptance/policy data and past-signature audit are now executable
pure checks. An unexpired current decision still requires separate live trusted
keys/time; historical audit cannot install a key or activate quarantine.
Signed domain v2 also binds actual original principal, qualification, observation,
grant and lease counts. Receipt correspondence checks these counts without
filtering by the receiving principal or creating recovery authority.
Schema 22 adds bounded acceptance records and the transfer maintenance action.
Active schema 21 migration preserves rows and authority, while retired schema 21
normal startup refuses before migration. Guarded quarantine schema installation
rolls back with the outer destination transaction; no activation route is yet
delivered by this schema/validation slice. The guarded stateless writer now
preserves source history while atomically withdrawing source authority and
installing the fresh recovery principal/barrier. Its private one-use review owner
and guarded recovery-mode Store are now implemented, with original deadline,
file, trust and time checks repeated through the transaction. Accepted delivery
remains read-only. Foreground supervision and timed receiving commands are now
implemented, including exact operation publication before commit and key-free
private receipt recovery after an interrupted reply. Original signed clock and
isolation inputs come from separately installed private current policies; no
archive, default key or OS wall-clock assertion installs trust. Two real child
CLI exchanges exercise stdin/output framing and original receipt recovery.
Ordinary Stores reject recovery-only operations without terminating or logging
custody. Subsequent separate transfer bootstrap and exact retained compiled
re-review preserve original histories across two accepted owner transitions.
The full 895-test development suite passes with four optional native-backend
skips. These source checks do not make the older assembled release current:
a fresh artifact build/smoke, installed key/clock custody and actual physical
isolation remain required before claiming a qualified receiving controller.

**H16-01.** A release manifest pins application, native runtime, protocol dependencies, schemas, rule compiler, capability catalogue and optional inference/verifier artifacts. Dependency licenses and SBOM cover the shipped binary closure, not just Mix dependencies. Signing identifies an artifact/issuer; it does not establish correctness. Distribution and first-run setup must disclose external downloads before offline readiness.

The current local `WOTEX_HOME_GIT_DEPS=1 MIX_ENV=prod mix release --overwrite` assembles an OTP release. Its `rel/env.sh.eex` sets `RELEASE_DISTRIBUTION=none` for the installed local host. `mix woh.release.smoke _build/prod/rel/wotex_home/bin/wotex_home` checks that no Erlang node is alive, the bundled Maude binary is inside that release, a bounded verifier call completes, the foreground host starts with a private Store/socket, file modes are private and the socket disappears on shutdown. The ex_maude source dependency is pinned to an [exact Git commit](../provenance/ex-maude-source.md). This is a repeatable local smoke gate, not a signed/notarized artifact, a clean-machine/offline install, an SBOM or native dependency closure.

The smoke waits up to 60 seconds for the socket and database to reach their final private modes and for an unauthorized health request to receive a complete framed rejection before checking readiness. This bound accommodates concurrent native/release startup observed on the development host; timeout diagnostics report endpoint file modes and captured host output. Merely observing a socket path during creation is not a ready host; the test still fails if the private endpoint never becomes ready within its bounded startup window.

The release overlay includes executable `bin/wotex_home_cli`. It invokes the same packaged BEAM implementation with arguments passed separately, and the release file inventory and SPDX document cover its script bytes. Its authenticated mutation commands can only stage held work or manage operator overrides through existing socket routes; the diagnostic credential remains read-only, and no command gains a device transport.

For the pinned Elixir toolchain in a socket-restricted development environment,
`elixir bin/build.exs --dependency-env prod` reuses explicitly selected prebuilt
dependency artifacts, checks the exact Git source pins and clean Home revision,
then invokes the real Mix compilers and release assembler in a new private
build directory. `--dependency-env test` explicitly selects that cache instead;
neither mode claims a dependency rebuild or cache-free installation. The runner
preloads those dependency paths before using Mix's existing dependency-compile
entry path, and disables only Mix's OS concurrency lock for its own exclusive
private build. It does not fake a PubSub process or relax Home's writer lock.
It checks packaged legal inputs, CLI startup, bounded bundled Maude execution,
socket-free packaged Store startup/restart, then creates and verifies component,
SPDX and file inventories. The result is a fresh unsigned development release,
not the full host/socket smoke, signed installation or hardware qualification.
The normal release smoke and CI socket tests remain mandatory separate gates.

`mix woh.isolated.smoke` archives only committed Home source into a temporary checkout, stages the two Git dependencies only when their cached checkouts match the pinned commits, sets `HEX_OFFLINE=1`, assembles a production release and runs the same smoke check. Run `WOTEX_HOME_GIT_DEPS=1 mix deps.get --check-locked` first to cache those sources. The gate does not use neighboring development checkouts or ignored local artifacts. It does not test an empty dependency cache, another CPU/OS or a packaged LIFX registry.

The GitHub Actions workflow forces both exact Git sources, checks the lockfiles and dependency/release-tooling format, compiles with warnings as errors, checks the spec catalogue, and runs the core and Nerves host tests on Ubuntu. The macOS job runs app packaging and native dependency fixtures that require Apple's `plutil`, independent Swift health/rule socket fixtures and live Swift/CLI request and rule-suspension parity. Its `macos-15` label currently selects an arm64 runner in [GitHub's hosted-runner table](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), matching the compiled fixture target. These checks passed locally; the updated remote workflow has not run. This is a source and host-test gate; it does not build or qualify Raspberry Pi firmware or exercise physical devices.

From a clean committed tree, `mix woh.release.inventory create _build/prod/rel/wotex_home` writes a deterministic manifest of every regular assembled file's relative path, byte count, permission mode and SHA-256, tied to the Home source commit. `verify` rejects missing, extra or changed files and symlinks. It covers the bundled Maude and BEAM runtime bytes, but the unsigned manifest is only an integrity input. It does not establish artifact authenticity, license clearance, a dependency SBOM or reproducibility on another toolchain.

A separate `mix woh.release.components create _build/prod/rel/wotex_home` maps every regular payload file except the generated reports to its packaged application, ERTS, release wrapper or bundled Maude component. The Home-authored CLI overlay is attributed to its own Home component rather than the generated release wrapper. It fingerprints each component's file set and the local license or notice inputs it can find, with explicit `missing`, `notice_only` and `present` states; the report always says `license_review: unresolved`. `verify` detects payload or local license-input drift. Exact versioned [Erlang/OTP, Elixir and Maude license inputs plus canonical Apache 2.0 text](../provenance/license-inputs/README.md) are pinned and checked for the current release, including both runtime inputs for generated wrapper files. The Maude component also records its pinned third-party notice; its license text changes the input status to `present` without establishing a corresponding-source offer. The two locked Hex packages without a standalone license file contribute pinned README copyright/license notices, package metadata and the canonical Apache text; their status is `present` only when all match. A notice alone is not a complete license input or clearance. Native, bundled Maude and Home project licensing work remains unresolved.

The macOS development release copies the canonical Apache 2.0 text to each of those two packaged dependency directories. The smoke check requires exact bytes at both paths, and the component map attributes each copy to its package. Their tagged upstream sources declare Apache-2.0 but do not contain a standalone license file; the canonical text supplies that missing release input without deciding file-level licensing or completing distribution review.
The pinned [WoTEx UDP Git dependency](../provenance/wotex-udp-source.md) has its own Apache-2.0 `LICENSE` and `NOTICE`. Both host release steps copy those exact files beside the packaged `wotex_udp` application. The macOS smoke and Nerves image checks require their pinned hashes; the component map attributes their source inputs to WoTEx UDP. This is provenance and legal-input coverage, not project-wide license clearance.
The Nerves cross-built release uses its own Mix release step to include those two Apache copies and the Maude license/notice beside the retained standard libraries. Its built-image checker verifies the exact texts and still rejects every Maude executable; the ARM profile has no verifier backend.
The Maude third-party notice has its own pinned source hash and the macOS smoke requires exact packaged bytes. The Nerves image checker also reads all four legal files from the built `.fw` root filesystem and compares their hashes, so checking only the intermediate release tree is insufficient for this gate.

The macOS development release copies the exact-tag Maude `COPYING` text and the pinned third-party notice next to its bundled Maude payload, and the smoke check requires the license bytes to match the pinned source. Both shipped files are attributed to `maude-bundled` in the component report and covered by the release inventory. This supplies local notice material; executable provenance, corresponding source and redistribution compliance still need review.

The [tagged Maude 3.5.1 macOS arm64 asset](https://github.com/maude-lang/Maude/releases/tag/Maude3.5.1) advertises SHA-256 `95851274f57b3853aab833674e2b770ed800f38fb1f3d03c97dcac56346c13dc`. A downloaded copy matched that digest, and each of its 14 executable/standard-library members matched the dependency's arm64 payload byte for byte. `mix woh.maude.payload.check` pins those member hashes and checks the dependency's private directory, optionally rechecks the downloaded archive, and is called by the release smoke for the stripped arm64 payload. No archive or generated comparison report is committed. These checks strengthen byte provenance for the selected binary; they do not establish source correspondence, license compliance or safety of the program.

`mix woh.release.spdx create _build/prod/rel/wotex_home` then emits a file-level [SPDX 2.3](https://spdx.github.io/spdx-spec/v2.3/) JSON document from that verified component map. It lists each mapped payload file with a SHA-256, package membership and document relationships. A generated development document passed the [official SPDX 2.3 JSON schema](https://raw.githubusercontent.com/spdx/spdx-spec/v2.3/schemas/spdx-schema.json). Every license conclusion and declaration is `NOASSERTION`; the document does not certify license clearance, source-code offer completeness or native transitive provenance. Create the component report, SPDX document and release inventory in that order from a clean committed tree. The final inventory covers both generated reports. Both report verifiers detect payload drift; the inventory also detects report mutation.

`mix woh.macos.app.assemble [RELEASE_PATH]` accepts an explicit inventoried release path as well as the default production path. This lets the fresh-source build cache feed assembly directly; the embedded inventory must still match the clean current Home commit before the staged app replaces the previous build.

The unsigned macOS assembly now writes `Contents/Resources/app-inventory.json` after verifying the embedded OTP release inventory. It hashes every regular outer bundle file except itself, including the Swift window, helper, LaunchAgent, embedded OTP payload and its reports, and binds the app and embedded release to the same committed Home revision. `mix woh.macos.app.inventory verify _build/macos/WotexHome.app` rejects missing, changed, nonregular or symlinked payload and a changed embedded manifest. This is an unsigned integrity input; it does not provide notarization, artifact authenticity or license clearance for the native closure.

Every scripted Swift build uses an explicit private module-cache path inside
its temporary build scope. App assembly removes that cache before handoff;
compiler intermediates are not shipped or inventoried as product artifacts.
This avoids a build dependency on a writable global Clang cache without
changing the selected SDK, deployment target or runtime permissions.

The assembly first emits `Contents/Resources/app.spdx.json`, a file-level SPDX 2.3 document covering the outer Swift/helper/agent files, every embedded OTP payload file and the embedded release reports. It checks the embedded release SPDX file checksums and package coverage before adding native package groups; every license conclusion remains `NOASSERTION`. The outer app inventory then covers this document. `mix woh.macos.app.spdx verify _build/macos/WotexHome.app` checks its mapping against the current bundle. A development document passed the official SPDX 2.3 JSON schema; neither document establishes native transitive license clearance or signing provenance.

Before emitting reports, the assembly now runs `mix woh.macos.native.deps.check` over every Mach-O file in the bundle. It requires every native file to contain only arm64, bounds native file/tool output counts and rejects any direct dynamic load outside `/usr/lib` or `/System/Library`. It also requires every bundled native slice's `LC_BUILD_VERSION` or older `LC_VERSION_MIN_MACOSX` minimum to be no higher than the app's declared macOS 15.0 minimum. A bundled exqlite NIF has a build-machine path as its own `LC_ID_DYLIB`; that metadata is reported separately because no bundled binary loads it through that path. The arm64 release now removes the unused C-Node bridge and x64/Linux Maude executables after assembly; only the arm64 Maude Port backend is packaged. This is a direct-load and declared-version check only: it does not verify system library availability on macOS 15, transitive Apple dependencies, `dlopen` paths, signing or license rights.

## Separate update domains

**H16-02.** App, data schema, device profile, model, rule set, NCP firmware and device firmware update independently. Each has staging, compatibility checks, affected admission invalidation, activation and recovery. No automatic 'update everything' transaction. Smoke firmware/hush settings and Zigbee network reset are excluded from unattended maintenance.

Before host update, stop accepting new ordinary mutations, finish or mark in-flight work under a deadline, and snapshot the durable state consistently. Rollback must understand new data or use an explicit compatible migration. Restoring an old DB may restore unsafe radio counters or obsolete permissions; it is not a universal rollback strategy.

## Backup and ownership recovery

Schema version 12 exports retain immutable candidate-review history and require its canonical content, digests, revision ordering and original journal links during verification. Version 11 archives remain supported and migrate with an empty candidate table and unchanged global revision. Verification and staging report a bounded candidate-record count and explicitly state that this history does not reactivate rules. Checker receipt fingerprints are not proof packages; backup and migration cannot turn a pending or rejected record into an admitted artifact.

Schema version 13 exports also retain Store-owned handoff clock pairs and
validate their shape, original handoff journal identity and same-epoch time
ordering. Verification remains compatible with version 4-through-12 archives;
opening a version 12 database adds nullable timing fields without changing its
revision, receipts or generations. Legacy handoffs remain untimed. Retained
timing history never reactivates a command or a monotonic timer in a new boot.

**H16-03.** An encrypted, operator-exportable backup identifies its database revision, Home authority, device/profile bindings and credential/network-state dependencies. Recovery tests include a blank host and lost/replaced coordinator. Unsupported cross-chip restore is blocked. Never run a restored controller alongside its source with the same writer or radio identity. A reset destroys or revokes the appropriate credentials without silently transferring a household to a new owner.

The first internal export takes a consistent `VACUUM INTO` SQLite snapshot while the single Store process serializes writes. It places the temporary plaintext in a private 0700 directory, encrypts at most 32 MiB with AES-256-GCM using a caller-supplied 32-byte key, writes a new 0600 archive and removes the temporary snapshot. The archive identifies store revision and authority epoch; verification checks the authentication tag, SQLite integrity and those fields without installing the database. The key must come from a trusted local custody path and never be logged or persisted beside the archive. This is an internal backup primitive, not a shipped key broker, complete backup manifest, cross-host ownership transfer or power-loss guarantee. A physical restore remains gated on old-writer isolation and radio/network-counter continuity.

Read-only verification now also requires a supported schema version and its required Home tables, a full `integrity_check(1)` result of `ok`, an empty `foreign_key_check`, and the same Store consistency check used on startup before comparing the authenticated revision and epoch. This catches valid SQLite files with orphan held receipts or impossible Home revisions. SQLite [documents](https://www.sqlite.org/pragma.html#pragma_integrity_check) that integrity checking alone does not detect foreign-key errors. The archive is still not authorized for installation or controller takeover.

New exports contain schema version 5 and its execution ledger. Read-only verification also accepts a consistent version 4 archive with its older table set; a migration fixture preserves a held operation's receipt and exact retry when opened by version 5 Store code. A version 4 archive may be staged only into restore quarantine, never activated by verification alone. Version 5 startup journals any unsettled recorded handoff as unknown after integrity checks. These fixture and restart checks do not prove crash consistency or power-loss survival on target storage.

Schema version 6 added the reviewed enrollment binding table. Verification accepts consistent version 4 and 5 archives with their own required table sets. Opening a version 5 Store migrates without changing request receipts or the global revision. A reviewed binding retains its stable-ID tombstone across backup and restart; neither verification nor restore staging turns it into a qualified profile.

Schema version 7 added versioned review history. Verification accepts consistent version 4, 5 and 6 snapshots using each version's table set. Version 6 review digests migrate as legacy evidence; only a fresh authenticated review can create a version 2 identity record. No backup verification or migration grants physical command authority.

Schema version 8 exports include the profile qualification slot. Verification also accepts consistent version 7 archives. A version 7 migration creates an empty qualification table without adding any command authorization; the new signed-decision writer does not install reviewer keys, sanitized signed claim packages or raw physical evidence into database backups. After restore, a qualification row without its private content-addressed claim package and pinned reviewer keys fails at queue and claim admission. Synthetic signed fixtures exercise this guard; they are not physical evidence. Queued work in a backup still cannot dispatch from a staged restore.

Read-only backup verification and offline restore staging now return a bounded external-dependency summary from the authenticated SQLite snapshot: the count of qualified profile rows, deduplicated claim-shaped package references, count of rows without such references, whether reviewer keys are needed, and explicit absence of raw qualification artifacts and device credentials/counters from the archive. This identifies custody work but does not copy or authenticate the packages, trust the signer, activate the quarantined database or validate radio-counter continuity. Old schema versions report no qualification rows. At most 4,096 active qualification references are returned; a larger snapshot fails this inspection rather than truncating transfer requirements.

Current exports now use schema version 9 with an empty-policy rule-generation counter. Verification still accepts consistent version 8 archives, and opening one migrates to generation zero without changing existing receipts or the global revision. A fenced generation advance survives restart; old handed-off effects remain unknown, not replayed. Staging any archive remains quarantined.

Current exports now use schema version 10 with the operator override lease table. Verification continues to accept consistent version 9 snapshots and requires the new table plus its issuing journal links for version 10. A version 9 Store migrates with an empty lease table and unchanged revision. The archive retains lease rows for audit and recovery inspection, but a newly started Store has a fresh boot epoch and treats every restored interval as inactive. Verification and staging report the retained override-row count and explicitly state that leases do not reactivate after restore. Older schemas report zero rows. Offline staging remains quarantined; backup verification never reactivates a lease. Schema version 11 adds immutable override-operation receipts. Verification accepts version 10 archives with no such table and reports zero operations; opening one migrates with an empty receipt table and unchanged revision. Version 11 verification checks receipt and lease journals, reports the bounded retained operation count, and preserves exact issue/revoke retry evidence in encrypted archives. An archived receipt is historical: its issue result cannot become a live lease after restore.

A trusted offline staging call now decrypts and validates one archive in memory, inserts a `restore_quarantine` marker there, then writes a new 0600 SQLite file into an existing private 0700 directory. It never overwrites an existing path, and a wrong key creates no file. Store checks this marker before normal startup and refuses the staged copy with `restore_requires_transfer`; the original archive and active source remain untouched. A test verifies the staged data, marker and startup refusal. This enables offline inspection and a future fenced transfer workflow, not controller activation or radio-counter recovery. Do not remove the marker as a substitute for the missing transfer procedure.

## Operational visibility

Schema version 14 archives additionally retain the explicit-request causal
roots and their creation/reservation event links. Verification still accepts
consistent versions 4–13 with their historical table sets. Opening an old
Store migrates conservatively without changing receipts, journal bytes,
global revision or generation: old queue/execution history stays spent even
after cancellation, and missing or ambiguous queue provenance remains unknown.
Verification rejects missing roots, invalid/refunded budgets and wrong event
identities; encrypted offline staging preserves those reservations but cannot
activate the controller. New boot clocks and archived roots do not grant a
fresh effect budget. These checks are not target-storage power-loss evidence.

**H16-04.** Expose bounded read-only health for authority, store, queue budgets, device freshness, driver loss, inference/verifier availability and active artifact identity. Metrics/logs are separate from durable audit. Per-device private labels and raw utterances are not metric dimensions. Each restart creates an epoch; graph gaps remain gaps. External metrics storage is optional and cannot block command processing.

The initial recovery view reports store revision, authority epoch, writable state, held/queued/claimed/unknown counts, retained receipt count and ceiling, and active enrollment/principal counts, with dispatch explicitly disabled. It carries no Thing IDs, labels, credentials or raw activity. It is available to an authorized local-socket caller but is only a storage diagnostic subset, not the complete host health contract or a remotely exposed endpoint.

Provide a redacted support bundle with consent, finite size/retention and a preview of fields. It excludes keys, stable personal identifiers, prompts and raw household activity by default. Audit exports are permission-scoped and do not grant mutation access.

The internal support export authenticates a current `read` or ordinary-control principal, previews a closed version 2 schema containing Store revision, authority epoch, rule generation, held/queued/claimed/unknown counts, retained receipt count and ceiling, active Thing/principal counts and writable/dispatch flags, then writes at most 4 KiB to a new operator-chosen absolute local file. The same closed preview is now available through the authenticated `support_preview` socket operation. The CLI can display it before export or write it to a new private local file after validating the exact schema; a client cannot ask the host to write an arbitrary path. It never reads Thing IDs, profile documents, observations, raw activity or credentials. Privacy canary tests check the saved bytes and mode 0600. This is an explicit diagnostic primitive, not a retention manager or full support bundle.

Schema 16 archives retain immutable reported-constraint operation history and validate complete source/artifact digests, exact declaration pins, predecessor revisions and both directions of authority-journal links. Version 15 migration creates empty history without changing the watermark or manufacturing a restriction. Verification reports `invariant_policy_operation_rows` and explicitly says restored reports do not reactivate invariants. Old reports remain unknown under the next Store boot. Quarantine and external qualification dependencies still apply.

## Acceptance

H16-T1: clean offline installation after declared artifact provisioning. H16-T2: interrupted update before/after activation and incompatible-schema rollback. H16-T3: backup restore with network-counter and authority checks. H16-T4: disk growth/retention and observability outage do not erase the only authoritative receipt. H16-T5: artifact/credential revocation changes future admission without rewriting history. H16-T6: support exports pass secret/identity canary tests.

## Schema 17 archive compatibility

Encrypted exports now retain and validate admission artifacts, ordered generation activations and exact request-rule origins/root markers. Verification reports bounded admission/activation counts and explicitly reports `rule_history_reactivates_on_restore: false`. Historical schema 4–16 archives retain their version-specific checks. Restore staging remains quarantined and cannot start an old active policy or transport. Fresh unsigned release checks bind the new rule code in the runtime inventory; a structural code change invalidates current admission and physical profile bindings rather than silently upgrading them. Signed distribution and fenced cross-host restore still require their own evidence.

## Implemented host update barrier

Schema 18 implements an explicit authenticated preparation barrier. Begin suspends the active generation, rejects unsent work and records handed-off work as unknown in one transaction; it blocks new ordinary staging, rule admission/activation/invocation, queue, claim and handoff. A failed transaction rolls the entire barrier back. Exact operation retry and principal-private status resolve a lost response. Observations, health, original request status and consistent encrypted exports remain available. Restart never clears the barrier. End compares current epoch/revision and the original begin revision, permits new requests and leaves rules suspended; it does not install or qualify an update.

Archive verification accepts schemas 4–18 with exact historical table sets. Version 17 migration adds empty maintenance history and a normal marker without changing existing receipts, revision or generation. New verification reports retained maintenance-operation count and whether the barrier was active. Quarantined restore keeps the marker and never grants authority. Startup/backup/live guards reject damaged marker, journal, predecessor, generation and historical outcome counts. Tests inject a write failure before receipt insertion, retain exact history across restart and check held/queued/claimed/handed-off cases.

The existing export uses [SQLite's transactional `VACUUM INTO` snapshot](https://www.sqlite.org/lang_vacuum.html); SQLite documents interrupted snapshot creation as a separate corruption risk. Backup verification is still required before recovery. [Nerves explicitly distinguishes firmware validation and unknown status](https://nerves-runtime.hexdocs.pm/Nerves.Runtime.html); Home's shared maintenance barrier neither validates firmware nor proves slot recovery. Signed artifact staging, compatible rollback, a blank-host transfer, network counters and physical power-cut evidence remain separate update/recovery gates.

The development macOS panel exposes this preparation barrier using the same authenticated routes as the CLI. It reads current status separately, retains original identities after an uncertain reply and supports exact retry; it cannot supply an artifact, installation command, backup key or restore path. Independent native peer fixtures and live Swift/CLI parity exercise the barrier. This supplies a native preparation control, not a signed update installer or qualified rollback workflow.

## Component release and recovery closure

Shipping the [component runtime](WOH.17-component-extensions.md) requires its exact binary, WIT, Cargo closure, configuration, native loads and legal/provenance inputs in host inventories. External installed artifacts need bounded custody/retention and backup dependency summaries before qualified use. Missing bytes fail dependent admission; restore remains quarantined and does not activate an old component or refresh observations. The development runner is built separately and is not added to existing releases or firmware.

## Portable data custody and recovery

[WOH.18](WOH.18-portable-profile-admission.md) requires exact raw data/dependency,
trust-approval and qualification custody even on hosts with no Wasm engine.
Artifact leases and Store/history/backup references fence garbage collection;
disk pressure rejects new admission before deleting required evidence. Updates
use a barrier and new selection generations; rollback cannot restore old grants,
facts, rules or spent roots. Publish durable bytes before Store references and
include failure between these domains in host tests. Historical-schema archive
sets, missing dependency transfer and quarantine must accompany activation;
update-metadata expiry never becomes an offline verification bypass.

Schema-19 encrypted archives now validate retained local digest approval history
and list exact raw, semantic projection and registry digests plus operation and
selection counts. Raw bytes remain external and retained history explicitly
does not reactivate on restore. Historical schema-4–18 archives retain their
exact table sets and report empty portable dependencies. Migration adds empty
profile tables and policy generation without changing prior revisions or grants.
Staged restore remains quarantined. Schema 20 adds complete selection/pin
validation while schema 19 preserves its original empty-table requirement.
Actual byte transfer and fenced activation remain open; no backup verification
grants controller authority.

The Store now serializes explicit inert profile collection with admission and
backup work. It takes references from every retained artifact row, including
revoked approvals, and never deletes that history. Custody accepts the bounded
snapshot only from its configured Store owner, adds monitored leases and verifies
the complete bounded namespace before deleting unreferenced files/stages. It
checks file/root identities and synchronizes the directory before reporting
success. Missing retained bytes stay missing dependencies; no alternative version
is selected. Current management permission and active maintenance are required;
collection neither increments authority revision nor activates a restore. This
is software retention behavior, not physical power-loss evidence.

Schema-20 archives retain all qualification snapshots and list every referenced
signed claim package, including revoked and replaced qualifications. The
manifest distinguishes currently qualified heads from retained snapshot count.
Missing external packages remain recovery requirements; snapshots never
reactivate qualification in quarantine. Schema 19 retains its original exact
table set and validation; upgrading its existing slots records unavailable
declaration/actor/epoch/review provenance as null, without rewriting authority.

Schema-20 selection archives validate every historical parent operation, original
review, generation, current pointer and owning-domain pin without requiring
current byte presence. Dependency counts include retained selections and revoked
history. Missing raw bytes block current use and new selection, while historical
receipt lookup and revocation remain possible. Reselection never transfers old
observation freshness, rule authority or qualification. Corrupt/missing original
pins reject encrypted verification and disable the live writer. These are SQLite
fixture/restart results; installed-host transfer and physical storage gates remain
open.

Initial portable-profile enrollment and changed-firmware replacement retain v2
review documents in the existing schema-20 shape. Their history separates absent
prior identity/declaration from the fresh captured tuple, links initial enrollment
versus later rereview events, and checks the original predecessor binding. Old v1
reviews remain supported. A newer firmware qualification can replace the revoked
head without editing the older snapshot. Incompatible older binaries fail their
review decoder rather than treating a new shape as old authority; no archive or
restart synthesizes grants, current freshness or physical evidence.

The shared `Host` now starts private portable-profile custody and transient
selection-review custody immediately after Store has acquired its directory lock.
`profiles/` is created as 0700 only under that owned data directory; an existing
nonprivate or symlink root is rejected without repair. Host resolves OS directory
aliases to one canonical physical path before choosing the Store/custody namespace.
Store receives trusted named process references; custody/review owners receive
no SQLite handle or bearer credential. Custody restart keeps Store history but
stops downstream workers and discards pending reviews. Review-owner restart
releases its monitored leases and stops consumers without replacing Store or
custody. Store restart stops both owners and downstream power workers first.
Compiled operation remains independently guarded; these restarts never activate
profiles, restore qualification or send work. Development fixtures exercise
creation ordering, malformed roots, exact immutable bytes and restart ownership;
installed storage/custody and physical qualification remain separate gates.

The authored [portable recovery mechanism](portable-profile-recovery-v1.md)
defines a bounded encrypted archive carrying exact retained profile bytes and
quarantined directory staging. Implementation now follows this encoding; it neither
clears restore quarantine nor establishes old-writer isolation.

The retained-profile recovery slice now implements the authored
[archive mechanism](portable-profile-recovery-v1.md): Store-serialized encrypted
export includes every retained exact raw object, including revoked history, with
raw/projection/registry correspondence. Store-only custody export checks private
descriptor/path identity and historical data independently of current registry
availability. Missing/corrupt objects fail the complete export; unreferenced
objects and transient leases/reviews are not transferred. Database-only archives
retain their historical format and table-set checks. Verification checks the
authenticated exact object set before reporting inclusion or writing files.
New private directory staging synchronizes immutable bytes and a fully marked
quarantined database, preserves source history and refuses overwrite/startup.
Foreground recovery reads its key only through bounded canonical stdin custody.
Fenced activation, installed key brokerage, external qualification packages and
actual old-writer/radio-counter isolation remain separate requirements.

On 2026-10-07 the full Mix suite passed 688 tests with zero failures after
retained byte recovery. Four opt-in component-native cases were skipped because
`WOTEX_HOME_COMPONENT_NATIVE_TESTS` was unset; real socket and foreground host
script cases ran. Eleven focused archive cases cover approved/revoked/selected
history, authenticated damaged records and links, historical dependency
correspondence, 64 maximum-size objects, descriptor/path refusal, all five
file/directory synchronization failures, excluded leased orphans, wrong keys,
unchanged source history and quarantined startup refusal. Foreground commands
exported through the actual private Host and verified/staged without starting
Home, with a stdin-key output canary. The existing support-file load-filter
warning remains; no compiler or assertion failure resulted. Format,
warnings-as-errors compilation, contract metadata and Git whitespace checks
passed. These checks do not establish target-storage power-loss or physical
fencing, firmware boot or installed credential custody.

The authored [controller transfer mechanism](controller-transfer-v1.md) defines
permanent source retirement, one-use destination review, separately trusted
isolation evidence and Store-owned acceptance with new epoch/barrier and revoked
archived authority. Its consumer and canonical ledger encodings remain next work.
No restore marker can be cleared by the existing archive or public API.
