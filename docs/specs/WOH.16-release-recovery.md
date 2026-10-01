# WOH.16 — Release, update and recovery contracts

Version: 0.1.54. Status: accepted target.

## Release identity

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

The GitHub Actions workflow forces both exact Git sources, checks the lockfiles and dependency/release-tooling format, compiles with warnings as errors, checks the spec catalogue, and runs the core and Nerves host tests on Ubuntu. A macOS job runs the app packaging and native dependency fixtures that require Apple's `plutil`. It is a source and host-test gate; it does not build or qualify Raspberry Pi firmware or exercise physical devices.

From a clean committed tree, `mix woh.release.inventory create _build/prod/rel/wotex_home` writes a deterministic manifest of every regular assembled file's relative path, byte count, permission mode and SHA-256, tied to the Home source commit. `verify` rejects missing, extra or changed files and symlinks. It covers the bundled Maude and BEAM runtime bytes, but the unsigned manifest is only an integrity input. It does not establish artifact authenticity, license clearance, a dependency SBOM or reproducibility on another toolchain.

A separate `mix woh.release.components create _build/prod/rel/wotex_home` maps every regular payload file except the generated reports to its packaged application, ERTS, release wrapper or bundled Maude component. The Home-authored CLI overlay is attributed to its own Home component rather than the generated release wrapper. It fingerprints each component's file set and the local license or notice inputs it can find, with explicit `missing`, `notice_only` and `present` states; the report always says `license_review: unresolved`. `verify` detects payload or local license-input drift. Exact versioned [Erlang/OTP, Elixir and Maude license inputs plus canonical Apache 2.0 text](../provenance/license-inputs/README.md) are pinned and checked for the current release, including both runtime inputs for generated wrapper files. The Maude component also records its pinned third-party notice; its license text changes the input status to `present` without establishing a corresponding-source offer. The two locked Hex packages without a standalone license file contribute pinned README copyright/license notices, package metadata and the canonical Apache text; their status is `present` only when all match. A notice alone is not a complete license input or clearance. Native, bundled Maude and Home project licensing work remains unresolved.

The macOS development release copies the canonical Apache 2.0 text to each of those two packaged dependency directories. The smoke check requires exact bytes at both paths, and the component map attributes each copy to its package. Their tagged upstream sources declare Apache-2.0 but do not contain a standalone license file; the canonical text supplies that missing release input without deciding file-level licensing or completing distribution review.
The pinned [WoTEx UDP Git dependency](../provenance/wotex-udp-source.md) has its own Apache-2.0 `LICENSE` and `NOTICE`. Both host release steps copy those exact files beside the packaged `wotex_udp` application. The macOS smoke and Nerves image checks require their pinned hashes; the component map attributes their source inputs to WoTEx UDP. This is provenance and legal-input coverage, not project-wide license clearance.
The Nerves cross-built release uses its own Mix release step to include those two Apache copies and the Maude license/notice beside the retained standard libraries. Its built-image checker verifies the exact texts and still rejects every Maude executable; the ARM profile has no verifier backend.
The Maude third-party notice has its own pinned source hash and the macOS smoke requires exact packaged bytes. The Nerves image checker also reads all four legal files from the built `.fw` root filesystem and compares their hashes, so checking only the intermediate release tree is insufficient for this gate.

The macOS development release copies the exact-tag Maude `COPYING` text and the pinned third-party notice next to its bundled Maude payload, and the smoke check requires the license bytes to match the pinned source. Both shipped files are attributed to `maude-bundled` in the component report and covered by the release inventory. This supplies local notice material; executable provenance, corresponding source and redistribution compliance still need review.

The [tagged Maude 3.5.1 macOS arm64 asset](https://github.com/maude-lang/Maude/releases/tag/Maude3.5.1) advertises SHA-256 `95851274f57b3853aab833674e2b770ed800f38fb1f3d03c97dcac56346c13dc`. A downloaded copy matched that digest, and each of its 14 executable/standard-library members matched the dependency's arm64 payload byte for byte. `mix woh.maude.payload.check` pins those member hashes and checks the dependency's private directory, optionally rechecks the downloaded archive, and is called by the release smoke for the stripped arm64 payload. No archive or generated comparison report is committed. These checks strengthen byte provenance for the selected binary; they do not establish source correspondence, license compliance or safety of the program.

`mix woh.release.spdx create _build/prod/rel/wotex_home` then emits a file-level [SPDX 2.3](https://spdx.github.io/spdx-spec/v2.3/) JSON document from that verified component map. It lists each mapped payload file with a SHA-256, package membership and document relationships. A generated development document passed the [official SPDX 2.3 JSON schema](https://raw.githubusercontent.com/spdx/spdx-spec/v2.3/schemas/spdx-schema.json). Every license conclusion and declaration is `NOASSERTION`; the document does not certify license clearance, source-code offer completeness or native transitive provenance. Create the component report, SPDX document and release inventory in that order from a clean committed tree. The final inventory covers both generated reports. Both report verifiers detect payload drift; the inventory also detects report mutation.

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
