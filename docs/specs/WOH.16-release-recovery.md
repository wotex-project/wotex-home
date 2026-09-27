# WOH.16 — Release, update and recovery contracts

Version: 0.1.14. Status: accepted target.

## Release identity

**H16-01.** A release manifest pins application, native runtime, protocol dependencies, schemas, rule compiler, capability catalogue and optional inference/verifier artifacts. Dependency licenses and SBOM cover the shipped binary closure, not just Mix dependencies. Signing identifies an artifact/issuer; it does not establish correctness. Distribution and first-run setup must disclose external downloads before offline readiness.

The current local `MIX_ENV=prod mix release --overwrite` assembles an OTP release. `python3 bin/smoke_release.py _build/prod/rel/wotex_home/bin/wotex_home` checks that the bundled Maude binary is inside that release, completes a bounded verifier call, starts the foreground host with a private Store/socket, verifies file modes and observes socket removal on shutdown. The ex_maude source dependency is pinned to a [committed snapshot](../provenance/ex-maude-vendor.md) within this repository. This is a repeatable local smoke gate, not a signed/notarized artifact, a clean-machine/offline install, an SBOM or native dependency closure.

`python3 bin/smoke_isolated_checkout.py` archives only committed Home source into a temporary checkout, sets `HEX_OFFLINE=1`, assembles a production release and runs the same smoke check. It confirms that no neighboring ex_maude checkout or ignored local artifact is needed for the core release on a host with cached Hex dependencies. It does not test an empty dependency cache, another CPU/OS or a packaged LIFX registry.

From a clean committed tree, `python3 bin/release_inventory.py create _build/prod/rel/wotex_home` writes a deterministic manifest of every regular assembled file's relative path, byte count, permission mode and SHA-256, tied to the Home source commit. `verify` rejects missing, extra or changed files and symlinks. It covers the bundled Maude and BEAM runtime bytes, but the unsigned manifest is only an integrity input. It does not establish artifact authenticity, license clearance, a dependency SBOM or reproducibility on another toolchain.

## Separate update domains

**H16-02.** App, data schema, device profile, model, rule set, NCP firmware and device firmware update independently. Each has staging, compatibility checks, affected admission invalidation, activation and recovery. No automatic 'update everything' transaction. Smoke firmware/hush settings and Zigbee network reset are excluded from unattended maintenance.

Before host update, stop accepting new ordinary mutations, finish or mark in-flight work under a deadline, and snapshot the durable state consistently. Rollback must understand new data or use an explicit compatible migration. Restoring an old DB may restore unsafe radio counters or obsolete permissions; it is not a universal rollback strategy.

## Backup and ownership recovery

**H16-03.** An encrypted, operator-exportable backup identifies its database revision, Home authority, device/profile bindings and credential/network-state dependencies. Recovery tests include a blank host and lost/replaced coordinator. Unsupported cross-chip restore is blocked. Never run a restored controller alongside its source with the same writer or radio identity. A reset destroys or revokes the appropriate credentials without silently transferring a household to a new owner.

The first internal export takes a consistent `VACUUM INTO` SQLite snapshot while the single Store process serializes writes. It places the temporary plaintext in a private 0700 directory, encrypts at most 32 MiB with AES-256-GCM using a caller-supplied 32-byte key, writes a new 0600 archive and removes the temporary snapshot. The archive identifies store revision and authority epoch; verification checks the authentication tag, SQLite integrity and those fields without installing the database. The key must come from a trusted local custody path and never be logged or persisted beside the archive. This is an internal backup primitive, not a shipped key broker, complete backup manifest, cross-host ownership transfer or power-loss guarantee. A physical restore remains gated on old-writer isolation and radio/network-counter continuity.

Read-only verification now also requires a supported schema version and its required Home tables, a full `integrity_check(1)` result of `ok`, an empty `foreign_key_check`, and the same Store consistency check used on startup before comparing the authenticated revision and epoch. This catches valid SQLite files with orphan held receipts or impossible Home revisions. SQLite [documents](https://www.sqlite.org/pragma.html#pragma_integrity_check) that integrity checking alone does not detect foreign-key errors. The archive is still not authorized for installation or controller takeover.

New exports contain schema version 5 and its execution ledger. Read-only verification also accepts a consistent version 4 archive with its older table set; a migration fixture preserves a held operation's receipt and exact retry when opened by version 5 Store code. A version 4 archive may be staged only into restore quarantine, never activated by verification alone. Version 5 startup journals any unsettled recorded handoff as unknown after integrity checks. These fixture and restart checks do not prove crash consistency or power-loss survival on target storage.

Schema version 6 added the reviewed enrollment binding table. Verification accepts consistent version 4 and 5 archives with their own required table sets. Opening a version 5 Store migrates without changing request receipts or the global revision. A reviewed binding retains its stable-ID tombstone across backup and restart; neither verification nor restore staging turns it into a qualified profile.

Schema version 7 added versioned review history. Verification accepts consistent version 4, 5 and 6 snapshots using each version's table set. Version 6 review digests migrate as legacy evidence; only a fresh authenticated review can create a version 2 identity record. No backup verification or migration grants physical command authority.

Current exports now use schema version 8 and include the profile qualification slot. Verification also accepts consistent version 7 archives. A version 7 migration creates an empty qualification table without adding any command authorization; synthetic qualified rows remain test evidence only. Queued work in a backup still cannot dispatch from a staged restore.

A trusted offline staging call now decrypts and validates one archive in memory, inserts a `restore_quarantine` marker there, then writes a new 0600 SQLite file into an existing private 0700 directory. It never overwrites an existing path, and a wrong key creates no file. Store checks this marker before normal startup and refuses the staged copy with `restore_requires_transfer`; the original archive and active source remain untouched. A test verifies the staged data, marker and startup refusal. This enables offline inspection and a future fenced transfer workflow, not controller activation or radio-counter recovery. Do not remove the marker as a substitute for the missing transfer procedure.

## Operational visibility

**H16-04.** Expose bounded read-only health for authority, store, queue budgets, device freshness, driver loss, inference/verifier availability and active artifact identity. Metrics/logs are separate from durable audit. Per-device private labels and raw utterances are not metric dimensions. Each restart creates an epoch; graph gaps remain gaps. External metrics storage is optional and cannot block command processing.

The initial recovery view reports store revision, authority epoch, writable state, held/queued/claimed/unknown counts, retained receipt count and ceiling, and active enrollment/principal counts, with dispatch explicitly disabled. It carries no Thing IDs, labels, credentials or raw activity. It is available to an authorized local-socket caller but is only a storage diagnostic subset, not the complete host health contract or a remotely exposed endpoint.

Provide a redacted support bundle with consent, finite size/retention and a preview of fields. It excludes keys, stable personal identifiers, prompts and raw household activity by default. Audit exports are permission-scoped and do not grant mutation access.

The first internal support export authenticates a current `read` or ordinary-control principal, previews a closed schema containing only Store revision, authority epoch, held count, active Thing/principal counts and writable/dispatch flags, then writes at most 4 KiB to a new operator-chosen absolute local file. It never reads Thing IDs, profile documents, observations, raw activity or credentials. A privacy canary test checks the saved bytes and mode 0600. This is an explicit diagnostic primitive, not a packaged consent UI, retention manager or full support bundle.

## Acceptance

H16-T1: clean offline installation after declared artifact provisioning. H16-T2: interrupted update before/after activation and incompatible-schema rollback. H16-T3: backup restore with network-counter and authority checks. H16-T4: disk growth/retention and observability outage do not erase the only authoritative receipt. H16-T5: artifact/credential revocation changes future admission without rewriting history. H16-T6: support exports pass secret/identity canary tests.
